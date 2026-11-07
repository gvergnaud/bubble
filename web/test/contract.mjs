#!/usr/bin/env node
// Owner: QA. Contract test of the editor server (docs/editor-api.md), run against the mock
// (web/mock-server.mjs) AND Bubble's real server: same request script, same expectations.
//
//   node web/test/contract.mjs --base http://127.0.0.1:47621 --token dev --id demo [--mock]
//        [--source web/fixtures/demo.mp4] [--out build/check/editor/contract-mock] [--engine fixture]
//
// --mock: the server is web/mock-server.mjs (reset first with /mock/reset; its export file is the
// unedited fixture, so the export media checks are left to export-check.mjs on the real server).
// Writes <out>/statuses.json (step → status code, for diffing mock vs real) and, when an export
// finishes, <out>/export.mp4 + <out>/export.json. Prints PASS/FAIL per check; exit 1 on a FAIL.
import http from 'node:http'
import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d }
const BASE = new URL(arg('--base', 'http://127.0.0.1:47621'))
const TOKEN = arg('--token', 'dev')
const ID = arg('--id', 'demo')
const MOCK = process.argv.includes('--mock')
const SOURCE = arg('--source', new URL('../fixtures/demo.mp4', import.meta.url).pathname)
const OUT = arg('--out', `build/check/editor/contract-${MOCK ? 'mock' : 'real'}`)
// The engine to transcribe with: --engine, else the server's default (the mock: apple-local;
// ContractTests: the FixtureTranscriber, its only engine).
let ENGINE = arg('--engine')
const HOST = `${BASE.hostname}:${BASE.port}`
const cases = JSON.parse(readFileSync(new URL('../fixtures/edits-cases.json', import.meta.url), 'utf8'))
mkdirSync(OUT, { recursive: true })

// ---------- tiny HTTP client (node:http lets us set Host and raw paths; fetch does not) ----------
function req(method, path, { body, headers = {}, cookie = true, host = HOST, raw = false } = {}) {
  return new Promise((resolve, reject) => {
    const h = { Host: host, ...headers }
    if (cookie === true) h.Cookie = `bubble=${TOKEN}`
    else if (typeof cookie === 'string') h.Cookie = cookie
    let data
    if (body !== undefined) { data = typeof body === 'string' ? body : JSON.stringify(body); h['Content-Type'] = 'application/json'; h['Content-Length'] = Buffer.byteLength(data) }
    const r = http.request({ hostname: BASE.hostname, port: BASE.port, method, path, headers: h }, (res) => {
      const chunks = []
      res.on('data', (c) => chunks.push(c))
      res.on('end', () => {
        const buf = Buffer.concat(chunks)
        let json
        if (!raw && /json/.test(res.headers['content-type'] || '')) { try { json = JSON.parse(buf.toString('utf8')) } catch {} }
        resolve({ status: res.statusCode, headers: res.headers, buf, json })
      })
    })
    r.on('error', reject)
    r.setTimeout(30_000, () => r.destroy(new Error(`timeout ${method} ${path}`)))
    if (data) r.write(data)
    r.end()
  })
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ---------- checks ----------
let fails = 0
const statuses = {}
function check(name, ok, detail = '') {
  if (!ok) fails++
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${!ok && detail ? '  · ' + detail : ''}`)
}
function status(step, res, want) {
  statuses[step] = res.status
  const ok = Array.isArray(want) ? want.includes(res.status) : res.status === want
  check(`${step}: ${Array.isArray(want) ? want.join('|') : want}`, ok, `got ${res.status} ${res.buf.toString('utf8').slice(0, 200)}`)
  return ok
}
const isNum = (x) => typeof x === 'number' && Number.isFinite(x)
const isStr = (x) => typeof x === 'string'
/** Shape check: returns a list of problems ([] = ok). */
function shape(v, spec, path = '$') {
  const p = []
  for (const [k, t] of Object.entries(spec)) {
    const opt = k.endsWith('?'); const key = opt ? k.slice(0, -1) : k
    const x = v?.[key]
    if (x === undefined) { if (!opt) p.push(`${path}.${key} missing`); continue }
    if (typeof t === 'function') { if (!t(x)) p.push(`${path}.${key} = ${JSON.stringify(x)?.slice(0, 60)}`) }
    else if (typeof t === 'object') p.push(...shape(x, t, `${path}.${key}`))
  }
  return p
}
const errorShape = (j) => shape(j, { error: isStr, message: isStr })
const oneOf = (...xs) => (x) => xs.includes(x)
const SEG = (s) => isNum(s.start) && isNum(s.end) && isNum(s.rate)
const EDITS = { revision: isNum, segments: (x) => Array.isArray(x) && x.every(SEG) }
const TRANSCRIPT = {
  status: oneOf('none', 'queued', 'running', 'ready', 'failed'), progress: isNum,
  engine: (x) => x === null || isStr(x), language: (x) => x === null || isStr(x), 'error?': isStr,
  speakers: (x) => Array.isArray(x) && x.every((s) => isStr(s.id) && isStr(s.name)),
  words: (x) => Array.isArray(x) && x.every((w) => isNum(w.start) && isNum(w.end) && isStr(w.text) && isStr(w.speaker) && (w.filler === undefined || w.filler === true) && (w.approximate === undefined || w.approximate === true)),
}
const EXPORTJOB = { id: isStr, status: oneOf('queued', 'running', 'done', 'failed', 'canceled'), progress: isNum, revision: isNum, duration: isNum, 'url?': isStr, 'bytes?': isNum, 'error?': isStr }
const PROJECT = {
  id: isStr, title: isStr, createdAt: (x) => isStr(x) && !isNaN(Date.parse(x)), updatedAt: (x) => isStr(x) && !isNaN(Date.parse(x)),
  video: { url: isStr, duration: isNum, width: isNum, height: isNum, fps: isNum, posterUrl: isStr },
  waveform: { url: isStr }, transcript: TRANSCRIPT, edits: EDITS,
  export: (x) => x === null || shape(x, EXPORTJOB).length === 0,
}
const sha = (path) => createHash('sha256').update(readFileSync(path)).digest('hex')
const editedDuration = (segs, d) => segs.reduce((t, s) => t - (s.end - s.start) + (s.rate ? (s.end - s.start) / s.rate : 0), d)

// ---------- the script ----------
const sourceHash = sha(SOURCE)
const sourceSize = statSync(SOURCE).size

if (MOCK) await req('POST', '/mock/reset?transcript=none&edits=empty')

// Auth and host
let r = await req('GET', `/edit/${ID}?t=${TOKEN}`, { cookie: false })
status('page with token redirects', r, 302)
check('redirect goes to the clean URL', r.headers.location === `/edit/${ID}`, r.headers.location)
const sc = [].concat(r.headers['set-cookie'] || []).join('; ')
check('cookie bubble=<token>; HttpOnly; SameSite=Strict; Path=/', new RegExp(`bubble=${TOKEN}`).test(sc) && /HttpOnly/i.test(sc) && /SameSite=Strict/i.test(sc) && /Path=\//i.test(sc), sc)
r = await req('GET', `/edit/${ID}`, { cookie: false })
status('page without cookie (public)', r, 200)
check('the page is HTML', /text\/html/.test(r.headers['content-type'] || ''), r.headers['content-type'])
r = await req('GET', `/api/projects/${ID}`, { cookie: false })
status('api without cookie', r, 401)
check('401 has { error, message }', errorShape(r.json).length === 0, JSON.stringify(r.json))
r = await req('GET', `/api/projects/${ID}`, { cookie: 'bubble=wrong' })
status('api with a wrong cookie', r, 401)
r = await req('GET', `/media/${ID}/source`, { cookie: false, headers: { Range: 'bytes=0-9' } })
status('media without cookie', r, 401)
r = await req('GET', `/api/projects/${ID}`, { host: `evil.example:${BASE.port}` })
status('foreign Host header (DNS rebinding)', r, 403)
r = await req('GET', `/api/projects/${ID}`, { host: `127.0.0.1:1` })
status('Host with another port', r, 403)
r = await req('GET', `/editor/../mock-server.mjs`)
status('path traversal under /editor', r, [400, 403, 404])
check('path traversal serves nothing', !/createServer|import /.test(r.buf.toString('utf8')))
r = await req('GET', `/api/projects/${ID}`, { headers: { Origin: 'https://evil.example' } })
check('no CORS header for another origin', !r.headers['access-control-allow-origin'], r.headers['access-control-allow-origin'])

// Project
r = await req('GET', `/api/projects/${ID}`)
status('get project', r, 200)
let project = r.json
const pp = shape(project, PROJECT)
check('Project shape', pp.length === 0, pp.join(', '))
check('video: duration 68.638 s, 1280×720, 30 fps', Math.abs(project?.video?.duration - 68.638) < 0.05 && project.video.width === 1280 && project.video.height === 720 && project.video.fps === 30, JSON.stringify(project?.video))
check('id is the one asked', project?.id === ID)
// Auto-transcription (editor-api.md §5): a project with no transcript starts one when it is opened;
// that first answer already says queued (or running/ready for a fast engine), with its engine.
check('opening starts the transcription (no Transcribe button)', ['queued', 'running', 'ready'].includes(project?.transcript?.status) && isStr(project.transcript.engine), `${project?.transcript?.status} ${project?.transcript?.engine} ${project?.transcript?.error ?? ''}`)
r = await req('GET', `/api/projects/does-not-exist`)
status('unknown project', r, 404)
check('404 has { error, message }', errorShape(r.json).length === 0, JSON.stringify(r.json))

// Media: Range
const src = project.video.url
r = await req('GET', src, { raw: true })
status('source without Range', r, 200)
check('source: full length, Accept-Ranges: bytes', Number(r.headers['content-length']) === sourceSize && r.headers['accept-ranges'] === 'bytes', `${r.headers['content-length']} vs ${sourceSize}`)
check('source bytes are the recording', createHash('sha256').update(r.buf).digest('hex') === sourceHash)
r = await req('GET', src, { headers: { Range: 'bytes=0-99' }, raw: true })
status('Range bytes=0-99', r, 206)
check('Content-Range bytes 0-99/<size>, 100 bytes', r.headers['content-range'] === `bytes 0-99/${sourceSize}` && r.buf.length === 100, `${r.headers['content-range']} len ${r.buf.length}`)
r = await req('GET', src, { headers: { Range: 'bytes=1000-' }, raw: true })
status('Range bytes=1000-', r, 206)
check('open range runs to the end', r.buf.length === sourceSize - 1000 && r.headers['content-range'] === `bytes 1000-${sourceSize - 1}/${sourceSize}`, r.headers['content-range'])
r = await req('GET', src, { headers: { Range: 'bytes=-500' }, raw: true })
status('Range bytes=-500', r, 206)
check('suffix range: the last 500 bytes', r.buf.length === 500 && r.headers['content-range'] === `bytes ${sourceSize - 500}-${sourceSize - 1}/${sourceSize}`, r.headers['content-range'])
r = await req('GET', src, { headers: { Range: `bytes=${sourceSize}-` }, raw: true })
status('Range past the end', r, 416)
check('416 says the size', r.headers['content-range'] === `bytes */${sourceSize}`, r.headers['content-range'])
r = await req('GET', project.video.posterUrl, { raw: true })
status('poster', r, 200)
check('poster is a JPEG', /image\/jpeg/.test(r.headers['content-type'] || '') && r.buf[0] === 0xff && r.buf[1] === 0xd8, r.headers['content-type'])

// Waveform (202 while computing)
let wf
for (let i = 0; i < 30; i++) {
  r = await req('GET', project.waveform.url)
  if (r.status !== 202) break
  check('waveform 202 is { status: "pending" }', r.json?.status === 'pending', JSON.stringify(r.json))
  await sleep(1000)
}
status('waveform', r, 200)
wf = r.json
check('waveform: 50 peaks/s, uint8-base64', wf?.peaksPerSecond === 50 && wf?.encoding === 'uint8-base64' && isStr(wf?.peaks))
const peaks = Buffer.from(wf?.peaks || '', 'base64')
check('waveform: one peak per 1/50 s (±2)', Math.abs(peaks.length - project.video.duration * 50) <= 2, `${peaks.length} peaks`)
check('waveform: not silent', peaks.some((b) => b > 20), `max ${Math.max(...peaks)}`)

// Edits: save, stale, validation
let rev = project.edits.revision
const fixtureEdits = cases.validate.find((c) => c.name === "the fixture's edits").segments
r = await req('PUT', `/api/projects/${ID}/edits`, { body: { revision: rev, segments: fixtureEdits } })
status('save edits', r, 200)
check('revision bumped by one', r.json?.revision === rev + 1, JSON.stringify(r.json))
rev = r.json?.revision ?? rev + 1
r = await req('GET', `/api/projects/${ID}`)
const sameSegs = (a, b) => Array.isArray(a) && a.length === b.length && a.every((s, i) => Math.abs(s.start - b[i].start) < 1e-6 && Math.abs(s.end - b[i].end) < 1e-6 && s.rate === b[i].rate)
check('saved edits read back', sameSegs(r.json?.edits?.segments, fixtureEdits) && r.json?.edits?.revision === rev, JSON.stringify(r.json?.edits))
r = await req('PUT', `/api/projects/${ID}/edits`, { body: { revision: rev - 1, segments: [] } })
status('save from an old revision', r, 409)
check('409 is { error: "stale", edits }', r.json?.error === 'stale' && shape(r.json?.edits, EDITS).length === 0 && r.json.edits.revision === rev, JSON.stringify(r.json)?.slice(0, 200))
// The cases are written for the fixture's 68.638 s; a server may measure the video a few ms
// shorter (video track vs container). A segment "to the end" uses the duration the server reports,
// as the page does. "past the end" stays past it.
const D = project.video.duration
const toServer = (segs) => Array.isArray(segs) ? segs.map((s) => (s?.end === cases.duration ? { ...s, end: D } : s)) : segs
for (const c of cases.validate) {
  r = await req('PUT', `/api/projects/${ID}/edits`, { body: { revision: rev, segments: toServer(c.segments) } })
  status(`edits case "${c.name}"`, r, c.valid ? 200 : 422)
  if (r.status === 200) rev = r.json.revision
  else if (r.status === 422) check(`  422 is { error: "invalid", message }`, r.json?.error === 'invalid' && isStr(r.json?.message), JSON.stringify(r.json))
}
r = await req('PUT', `/api/projects/${ID}/edits`, { body: 'not json' })
status('edits: body is not JSON', r, 422)
r = await req('PUT', `/api/projects/${ID}/edits`, { body: { segments: [] } })
status('edits: no revision', r, 422)
r = await req('PUT', `/api/projects/${ID}/edits`, { body: { revision: rev, segments: fixtureEdits } })
status('save the fixture edits again', r, 200)
rev = r.json?.revision ?? rev

// Title and speakers
const oldTitle = project.title
r = await req('PATCH', `/api/projects/${ID}`, { body: { title: 'Contract test title' } })
status('rename', r, 200)
check('PATCH returns the Project with the new title', r.json?.title === 'Contract test title' && shape(r.json, PROJECT).length === 0, r.json?.title)
r = await req('PATCH', `/api/projects/${ID}`, { body: { title: oldTitle } })
status('rename back', r, 200)

// Engines and transcription
r = await req('GET', '/api/engines')
status('engines', r, 200)
const engines = r.json?.engines
check('engines: [{ id, name, local, available, default, why? }]', Array.isArray(engines) && engines.length > 0 && engines.every((e) => isStr(e.id) && isStr(e.name) && typeof e.local === 'boolean' && typeof e.available === 'boolean' && typeof e.default === 'boolean' && (e.why === undefined || isStr(e.why))), JSON.stringify(r.json))
check('exactly one default engine, and it is available', engines?.filter((e) => e.default).length === 1 && engines.find((e) => e.default).available, JSON.stringify(engines))
check('an unavailable engine says why', engines?.every((e) => e.available || isStr(e.why)), JSON.stringify(engines))
ENGINE = ENGINE ?? engines?.find((e) => e.default)?.id
check(`engine "${ENGINE}" is listed and available`, engines?.some((e) => e.id === ENGINE && e.available), JSON.stringify(engines?.map((e) => e.id)))
r = await req('POST', `/api/projects/${ID}/transcription`, { body: { engine: 'no-such-engine' } })
status('transcription with an unknown engine', r, 422)
const unavailable = engines?.find((e) => !e.available)
if (unavailable) {
  r = await req('POST', `/api/projects/${ID}/transcription`, { body: { engine: unavailable.id } })
  status(`transcription with an unavailable engine (${unavailable.id})`, r, 422)
}
// Settings: only on the mock. On the real server PUT would call Mistral (network) and DELETE would
// remove the user's real Keychain item: never in a test.
if (MOCK) {
  r = await req('GET', '/api/settings')
  status('settings', r, 200)
  check('settings: { mistralKey: keychain|environment|none }', ['keychain', 'environment', 'none'].includes(r.json?.mistralKey), JSON.stringify(r.json))
  r = await req('PUT', '/api/settings/mistral-key', { body: { key: 'bad' } })
  status('a rejected key', r, 422)
  check('422 is { error: "invalid_key" }', r.json?.error === 'invalid_key', JSON.stringify(r.json))
  r = await req('PUT', '/api/settings/mistral-key', { body: { key: 'offline' } })
  status('Mistral unreachable', r, 502)
  r = await req('PUT', '/api/settings/mistral-key', { body: { key: 'sk-test' } })
  status('a good key', r, 200)
  check('the key is never sent back', !JSON.stringify(r.json).includes('sk-test') && !(await req('GET', '/api/settings')).buf.toString().includes('sk-test'))
  check('with a key, Voxtral becomes the default', r.json?.engines?.find((e) => e.default)?.local === false, JSON.stringify(r.json?.engines))
  r = await req('DELETE', '/api/settings/mistral-key')
  status('remove the key', r, 200)
  check('without a key, the local engine is the default again', r.json?.engines?.find((e) => e.default)?.local === true, JSON.stringify(r.json?.engines))
}
r = await req('POST', `/api/projects/${ID}/transcription`, { body: { engine: ENGINE } })
status('start transcription', r, 202)
check('202 is { transcript } queued or running', shape(r.json?.transcript, TRANSCRIPT).length === 0 && ['queued', 'running'].includes(r.json.transcript.status), JSON.stringify(r.json)?.slice(0, 200))
let tr
for (let i = 0; i < 60; i++) {
  await sleep(1000)
  tr = (await req('GET', `/api/projects/${ID}`)).json?.transcript
  if (!['queued', 'running'].includes(tr?.status)) break
}
check('transcription ends ready', tr?.status === 'ready', `${tr?.status} ${tr?.error ?? ''}`)
check('words: some, in time order, inside the video', tr?.words?.length > 50 && tr.words.every((w, i) => w.start < w.end && w.end <= project.video.duration + 0.05 && (i === 0 || w.start >= tr.words[i - 1].start)), `${tr?.words?.length} words`)
check('every word has a known speaker', tr?.words?.every((w) => tr.speakers.some((s) => s.id === w.speaker)))
check('speakers have names', tr?.speakers?.length > 0 && tr.speakers.every((s) => s.name.trim().length > 0), JSON.stringify(tr?.speakers))
// A fresh project names them "Speaker N" (the mock keeps the fixture's renamed "Gabriel").
if (!MOCK) check('a fresh transcript names speakers "Speaker N"', tr?.speakers?.every((s) => /^Speaker \d+$/.test(s.name)), JSON.stringify(tr?.speakers))

// Export
r = await req('GET', '/api/exports/does-not-exist')
status('unknown export', r, 404)
r = await req('POST', `/api/projects/${ID}/export`, { body: {} })
status('start export', r, 202)
let job = r.json
check('202 is an ExportJob', shape(job, EXPORTJOB).length === 0, JSON.stringify(job))
check('the job renders the saved revision', job?.revision === rev, `${job?.revision} vs ${rev}`)
const wantDuration = editedDuration(fixtureEdits, project.video.duration)
check('job duration = Σ kept / rate', Math.abs(job?.duration - wantDuration) < 0.01, `${job?.duration} vs ${wantDuration.toFixed(3)}`)
r = await req('GET', `/api/exports/${job.id}/file`, { raw: true })
if (job.status !== 'done') status('export file before it is done', r, 409)
for (let i = 0; i < 120 && ['queued', 'running'].includes(job?.status); i++) {
  await sleep(1000)
  job = (await req('GET', `/api/exports/${job.id}`)).json
}
check('export ends done', job?.status === 'done', JSON.stringify(job))
check('done job has url and bytes', isStr(job?.url) && isNum(job?.bytes), JSON.stringify(job))
r = await req('GET', `/api/project/${ID}`)   // typo route: must be a 404, not a crash
status('unknown route', r, 404)
if (job?.url) {
  r = await req('GET', job.url, { raw: true })
  status('download the export', r, 200)
  const cd = r.headers['content-disposition'] || ''
  check('Content-Disposition: attachment; "<title> (edited).mp4"', /attachment/i.test(cd) && cd.includes(`${oldTitle} (edited).mp4`), cd)
  check('downloaded bytes = job.bytes', r.buf.length === job.bytes, `${r.buf.length} vs ${job.bytes}`)
  writeFileSync(join(OUT, 'export.mp4'), r.buf)
  writeFileSync(join(OUT, 'export.json'), JSON.stringify({ job, segments: fixtureEdits, sourceDuration: project.video.duration, expectedDuration: wantDuration }, null, 2))
}
// Cancel
r = await req('POST', `/api/projects/${ID}/export`, { body: {} })
status('start a second export', r, 202)
const second = r.json
r = await req('DELETE', `/api/exports/${second?.id}`)
status('cancel it', r, 200)
check('canceled (or already done)', ['canceled', 'done'].includes(r.json?.status), JSON.stringify(r.json))
await sleep(1500)
r = await req('GET', `/api/exports/${second?.id}`)
check('a canceled export stays canceled', ['canceled', 'done'].includes(r.json?.status), JSON.stringify(r.json))

// The source is never written.
check('the source file is unchanged (sha256)', sha(SOURCE) === sourceHash)

writeFileSync(join(OUT, 'statuses.json'), JSON.stringify(statuses, null, 2))
console.log(fails ? `${fails} FAILED` : 'ALL PASS')
process.exit(fails ? 1 : 0)
