#!/usr/bin/env node
// Owner: QA. Golden checks of an exported edit (docs/editor-architecture.md §8 qa.4), with ffmpeg:
//   node web/test/export-check.mjs <export.mp4> --source web/fixtures/demo.mp4 --segments '<json>' [--duration 68.638]
//   node web/test/export-check.mjs --from <dir with export.mp4 + export.json>   (written by contract.mjs)
// Checks: duration = Σ kept / rate ± 1 frame; 30.00 fps constant, frame count; H.264 + AAC 48 kHz;
// a full decode prints no error; moov before mdat (plays while downloading); video frames come from
// the right source times (frame-exact on the fixture's ms clock); audio lines up with the source in
// every 1× piece (envelope cross-correlation, |lag| ≤ 1 frame). Exit 1 on any FAIL.
import { spawnSync } from 'node:child_process'
import { readFileSync, openSync, readSync, closeSync } from 'node:fs'
import { join } from 'node:path'

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d }
let file, source, segments, duration
if (arg('--from')) {
  const dir = arg('--from')
  const meta = JSON.parse(readFileSync(join(dir, 'export.json'), 'utf8'))
  file = join(dir, 'export.mp4'); segments = meta.segments; duration = meta.sourceDuration
  source = arg('--source', new URL('../fixtures/demo.mp4', import.meta.url).pathname)
} else {
  file = process.argv[2]
  source = arg('--source', new URL('../fixtures/demo.mp4', import.meta.url).pathname)
  segments = JSON.parse(arg('--segments', '[]'))
  duration = Number(arg('--duration', '68.638'))
}
const FPS = 30, FRAME = 1 / FPS

let fails = 0
const check = (name, ok, detail = '') => { if (!ok) fails++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  · ' + detail : ''}`) }
const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { maxBuffer: 1 << 30, ...opts })
const probe = (f, args) => JSON.parse(run('ffprobe', ['-v', 'error', '-of', 'json', ...args, f]).stdout.toString() || '{}')

// Kept pieces in source time, and where each starts in the output.
const pieces = []
{
  let t = 0, out = 0
  const push = (a, b, rate) => { if (b - a > 1e-9) { pieces.push({ start: a, end: b, rate, outStart: out }); out += (b - a) / rate } }
  for (const s of segments) { push(t, s.start, 1); if (s.rate) push(s.start, s.end, s.rate); t = s.end }
  push(t, duration, 1)
}
const expected = pieces.reduce((d, p) => d + (p.end - p.start) / p.rate, 0)
const sourceTime = (o) => { for (const p of pieces) { const len = (p.end - p.start) / p.rate; if (o < p.outStart + len) return p.start + (o - p.outStart) * p.rate } return duration }

// 1. Container, codecs, duration, frame rate.
const info = probe(file, ['-show_format', '-show_streams', '-count_frames'])
const v = info.streams?.find((s) => s.codec_type === 'video'), a = info.streams?.find((s) => s.codec_type === 'audio')
const dur = Number(info.format?.duration)
check(`duration ${dur.toFixed(3)} s = Σ kept / rate ${expected.toFixed(3)} s ± 1 frame`, Math.abs(dur - expected) <= FRAME + 1e-3)
check('video is H.264', v?.codec_name === 'h264', v?.codec_name)
check('audio is AAC 48 kHz', a?.codec_name === 'aac' && Number(a?.sample_rate) === 48000, `${a?.codec_name} ${a?.sample_rate}`)
check('30.00 fps (r_frame_rate and avg_frame_rate)', v?.r_frame_rate === '30/1' && Math.abs(eval(v?.avg_frame_rate || '0') - 30) < 0.01, `${v?.r_frame_rate} avg ${v?.avg_frame_rate}`)
const frames = Number(v?.nb_read_frames)
check(`frame count ${frames} = duration × 30 (±1)`, Math.abs(frames - Math.round(expected * FPS)) <= 1, `want ${Math.round(expected * FPS)}`)
check('audio as long as video (±2 frames)', Math.abs(Number(a?.duration) - Number(v?.duration)) <= 2 * FRAME, `audio ${a?.duration} video ${v?.duration}`)
check('same size as the source', (() => { const s = probe(source, ['-show_streams']).streams.find((x) => x.codec_type === 'video'); return s.width === v?.width && s.height === v?.height })(), `${v?.width}×${v?.height}`)

// 2. Clean decode.
const dec = run('ffmpeg', ['-v', 'error', '-i', file, '-f', 'null', '-'])
const errs = dec.stderr.toString().trim()
check('ffmpeg -v error decode prints nothing', dec.status === 0 && errs === '', errs.slice(0, 300))
const pts = run('ffprobe', ['-v', 'error', '-select_streams', 'v', '-show_entries', 'packet=dts', '-of', 'csv=p=0', file]).stdout.toString().trim().split('\n').map(Number)
check('video timestamps strictly increase', pts.every((x, i) => i === 0 || x > pts[i - 1]))

// 3. moov before mdat (faststart).
{
  const fd = openSync(file, 'r'); const head = Buffer.alloc(64 * 1024); readSync(fd, head, 0, head.length, 0); closeSync(fd)
  let off = 0, order = []
  while (off + 8 <= head.length && order.length < 6) { const size = head.readUInt32BE(off); const type = head.toString('ascii', off + 4, off + 8); order.push(type); if (size < 8) break; off += size }
  check('moov before mdat (plays while downloading)', order.indexOf('moov') >= 0 && (order.indexOf('mdat') < 0 || order.indexOf('moov') < order.indexOf('mdat')), order.join(' '))
}

// 4. Video: frames come from the right source time (the fixture shows its own ms clock).
const W = 320, H = 180
const grab = (f, t) => run('ffmpeg', ['-v', 'error', '-ss', t.toFixed(4), '-i', f, '-frames:v', '1', '-vf', `scale=${W}:${H}`, '-f', 'rawvideo', '-pix_fmt', 'gray', '-']).stdout
const mse = (x, y) => { let s = 0; const n = Math.min(x.length, y.length); for (let i = 0; i < n; i++) { const d = x[i] - y[i]; s += d * d } return n ? s / n : Infinity }
let videoOK = 0, videoN = 0, worst = ''
for (const p of pieces) {
  const len = (p.end - p.start) / p.rate
  if (len < 0.5) continue
  for (const f of [0.25, 0.5, 0.75]) {
    const o = Math.floor((p.outStart + len * f) * FPS) / FPS + FRAME / 2   // middle of an output frame
    const s = sourceTime(o)
    const out = grab(file, o)
    // The source frame shown at s, and its neighbours: the right one must be the closest.
    const sf = Math.floor(s * FPS)
    const scores = [-1, 0, 1].map((k) => mse(out, grab(source, (sf + k) / FPS + FRAME / 2)))
    videoN++
    const best = scores.indexOf(Math.min(...scores))
    // At 1× the frame must be the exact one; sped up, the nearest of the three is fine (resampling).
    if (best === 1 || (p.rate !== 1 && scores[1] < 60)) videoOK++
    else worst = `out ${o.toFixed(3)} s ↔ source ${s.toFixed(3)} s: mse ${scores.map((x) => x.toFixed(0)).join('/')} (rate ${p.rate})`
  }
}
check(`video frames match the source times (${videoOK}/${videoN} samples)`, videoN > 0 && videoOK === videoN, worst)

// 5. Audio: every 1× piece lines up with the source (100 Hz loudness envelope, best lag).
const pcm = (f) => { const b = run('ffmpeg', ['-v', 'error', '-i', f, '-ac', '1', '-ar', '8000', '-f', 's16le', '-']).stdout; return new Int16Array(b.buffer, b.byteOffset, b.length >> 1) }
const env = (x) => { const n = Math.floor(x.length / 80), e = new Float64Array(n); for (let i = 0; i < n; i++) { let s = 0; for (let j = 0; j < 80; j++) s += Math.abs(x[i * 80 + j]); e[i] = s / 80 } return e }
const eo = env(pcm(file)), es = env(pcm(source))
let audioOK = 0, audioN = 0, lagInfo = []
for (const p of pieces) {
  if (p.rate !== 1 || p.end - p.start < 2) continue
  const n = Math.floor((p.end - p.start) * 100) - 40
  const o0 = Math.round(p.outStart * 100) + 20, s0 = Math.round(p.start * 100) + 20
  let best = -Infinity, bestLag = 0
  for (let lag = -20; lag <= 20; lag++) {
    let num = 0, da = 0, db = 0
    for (let i = 0; i < n; i++) { const x = eo[o0 + i + lag] ?? 0, y = es[s0 + i] ?? 0; num += x * y; da += x * x; db += y * y }
    const c = num / Math.sqrt(da * db || 1)
    if (c > best) { best = c; bestLag = lag }
  }
  audioN++
  lagInfo.push(`${p.start.toFixed(2)}s: lag ${bestLag * 10} ms, r ${best.toFixed(3)}`)
  if (Math.abs(bestLag) <= 3 && best > 0.9) audioOK++     // 10 ms steps: ≤ 30 ms ≈ 1 frame
}
check(`audio in sync in every 1× piece (${audioOK}/${audioN})`, audioN > 0 && audioOK === audioN, lagInfo.join('; '))

console.log(fails ? `${fails} FAILED` : 'ALL PASS')
process.exit(fails ? 1 : 0)
