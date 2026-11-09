#!/usr/bin/env node
// Mock of Bubble's editor server: the API of docs/editor-api.md over the fixture in web/fixtures/.
// Owner: architect (the §8 "open any video" routes and their /mock knobs: QA track). No dependencies:
// `node web/mock-server.mjs [--port 47621]`, then open http://127.0.0.1:47621/edit/demo?t=dev
// (or the home page: http://127.0.0.1:47621/?t=dev). State is in memory (restart = back to the fixture).
//
// Extras for building the page (not in the real server):
//   POST /mock/reset?transcript=ready|none|running|failed&edits=fixture|empty
//     (transcript=none: the next GET /api/projects/demo starts the default engine, like Bubble)
//   Δ open any video (docs/editor-open-video.md), same call, every knob optional:
//     projects=fixture|empty   the home list: demo + 3 others (one offline on "T7", one missing) | none
//     source=ok|missing|offline   where demo's file is (offline: on "T7")
//     sound=none               demo has no sound track: transcript failed, errorCode 'no_sound'
//     video=unplayable         demo's file is ProRes (.mov): Chrome can't play it
//     panel=pick|cancel|hold|busy|unsupported|undecodable|no_video   what Bubble's open panel does
//       (hold: stays up until POST /mock/panel?answer=pick|cancel|unsupported|undecodable|no_video;
//        busy: POST /api/open answers 409 at once)
//     pick=<file name>         the file the panel picks (default "Interview raw.mov" = project interview;
//                              a new name makes a new project; .mkv/.webm/... are refused)
//     panelDelay=<ms>          before the panel answers (default 800)
//     dropped=found|not_found|unsupported|no_video   what the Spotlight lookup of a drop gives
//     droppedDelay=<ms>        (default 300)
//     locate=same|other_bytes|different_video|cancel   what Locate… picks (default same)
//   POST /mock/steer?...        sets the same knobs (panel, pick, dropped, locate, delays) without a reset
//   The fake media check goes by the picked or dropped file name, like web/fixtures/open-video/:
//     other than .mp4/.mov/.m4v → unsupported_format; "vp9" in it → unsupported_format (VP9);
//     "audio-only" → no_video; "no-sound" → opens with errorCode 'no_sound'; "prores" → served as ProRes.
//   POST /mock/panel?answer=...   answers a held panel (or a held locate)
//   GET /mock/state            what Bubble was asked: { fronts, opens, revealed, deleted, dropped }
//   ?slow=1 on any API call adds 400 ms of latency.
import { createServer } from 'node:http'
import { readFileSync, statSync, createReadStream, existsSync } from 'node:fs'
import { join, dirname, extname, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'

const ROOT = dirname(fileURLToPath(import.meta.url))
const FIX = join(ROOT, 'fixtures')
const PORT = Number(process.argv[process.argv.indexOf('--port') + 1]) || 47621
const TOKEN = 'dev'
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.json': 'application/json', '.woff2': 'font/woff2',
  '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.mov': 'video/quicktime' }
const DEMO_FILE = join(FIX, 'demo.mp4')
const PRORES_FILE = join(FIX, 'open-video', 'prores.mov')

const fixture = JSON.parse(readFileSync(join(FIX, 'demo.project.json'), 'utf8'))
const waveform = readFileSync(join(FIX, 'demo.waveform.json'), 'utf8')
const flatWaveform = (() => {
  const w = JSON.parse(waveform)
  return JSON.stringify({ ...w, peaks: Buffer.alloc(Buffer.from(w.peaks, 'base64').length).toString('base64') })
})()
const projects = new Map()   // id -> { project, file (served for /media/:id/source) }
let project                  // demo's Project (the fixture), kept for the routes written for one project
const exports = new Map()
let knobs = {}
let mock = {}                // what Bubble was asked, for tests: GET /mock/state
const opens = new Map()      // openId -> { state, projectId?, error?, message?, sameBytes?, hold? }
let openSeq = 0
let mistralKey = 'none'   // 'keychain' | 'environment' | 'none' (mock: set by PUT /api/settings/mistral-key)
function engines() {
  const hasKey = mistralKey !== 'none'
  return [
    { id: 'voxtral-mini-transcribe-3', name: 'Voxtral 3 (Mistral API)', local: false, available: hasKey,
      ...(hasKey ? {} : { why: 'Add your Mistral API key.' }), default: hasKey },
    { id: 'apple-local', name: 'On this Mac', local: true, available: true, default: !hasKey },
  ]
}

// The fake home of the tests and previews, with its slash (the public export's scan allows /Users/me/).
const HOME = '/Users/me/'
const sourceFile = (name, folder, dir, extra = {}) => ({ name, folder, path: `${dir}/${name}`, state: 'ok', ...extra })
const NO_SOUND = "This video has no sound, so there's no transcript."

/// A project for another video: the fixture's media and transcript, its own id, title and file.
function makeProject(id, title, source, { updatedAt = new Date().toISOString(), edits = 'empty', file = DEMO_FILE } = {}) {
  const p = structuredClone(fixture)
  Object.assign(p, { id, title, updatedAt, source })
  p.video.url = `/media/${id}/source`; p.video.posterUrl = `/media/${id}/poster.jpg`
  p.waveform.url = `/api/projects/${id}/waveform`
  if (edits === 'empty') p.edits = { revision: 0, segments: [] }
  projects.set(id, { project: p, file })
  return p
}

function reset({ transcript = 'ready', edits = 'fixture', ...rest } = {}) {
  knobs = rest
  mock = { fronts: 0, opens: 0, revealed: [], deleted: [], dropped: [] }
  opens.clear(); projects.clear()
  project = structuredClone(fixture)
  project.source = sourceFile('Bubble demo.mp4', 'Movies/Bubble', `${HOME}Movies/Bubble`)
  if (edits === 'empty') project.edits = { revision: 0, segments: [] }
  const t = project.transcript
  if (transcript !== 'ready') {
    t.status = transcript; t.progress = transcript === 'running' ? 0.35 : 0; t.words = transcript === 'running' ? t.words.slice(0, 40) : []
    if (transcript === 'none') { t.engine = null; t.language = null; t.speakers = [] }
    if (transcript === 'failed') t.error = 'The transcription engine could not be reached.'
  }
  if (rest.sound === 'none') noSound(project)
  let file = DEMO_FILE
  if (rest.video === 'unplayable') {
    file = PRORES_FILE
    project.source.name = 'Bubble demo.mov'; project.source.path = `${HOME}Movies/Bubble/Bubble demo.mov`
  }
  if (rest.source === 'missing') project.source.state = 'missing'
  if (rest.source === 'offline') {
    Object.assign(project.source, { state: 'offline', volume: 'T7', folder: 'T7/Footage', path: '/Volumes/T7/Footage/Bubble demo.mp4' })
  }
  projects.set('demo', { project, file })
  if (rest.projects !== 'empty') {
    const ago = h => new Date(Date.now() - h * 3600_000).toISOString()
    project.updatedAt = ago(2)
    makeProject('interview', 'Interview raw', sourceFile('Interview raw.mov', 'Desktop', `${HOME}Desktop`), { updatedAt: ago(26) })
    makeProject('keynote', 'Keynote rehearsal',
      sourceFile('Keynote rehearsal.mp4', 'T7/Footage', '/Volumes/T7/Footage', { state: 'offline', volume: 'T7' }), { updatedAt: ago(24 * 5) })
    makeProject('old-take', 'Old take', sourceFile('Old take.mp4', 'Downloads', `${HOME}Downloads`, { state: 'missing' }), { updatedAt: ago(24 * 30) })
  } else {
    projects.delete('demo')
  }
  if (transcript === 'running') runTranscription(project)
}
function noSound(p) {
  Object.assign(p.transcript, { status: 'failed', progress: 0, engine: null, language: null, speakers: [], words: [],
    error: NO_SOUND, errorCode: 'no_sound' })
}
reset()

// ---- edits validation (same rules as docs/editor-api.md §3; the Swift server must match) ----
export function validate(segments, duration) {
  if (!Array.isArray(segments)) return 'segments must be an array'
  let prevEnd = 0
  for (const [i, s] of segments.entries()) {
    if (typeof s?.start !== 'number' || typeof s?.end !== 'number' || typeof s?.rate !== 'number') return `segment ${i}: start, end, rate must be numbers`
    if (!(s.start >= 0 && s.start < s.end && s.end <= duration + 1e-3)) return `segment ${i}: needs 0 <= start < end <= duration`
    if (s.start < prevEnd - 1e-6) return `segment ${i}: overlaps or is out of order`
    if (s.rate === 1) return `segment ${i}: rate 1 is not a segment`
    if (!(s.rate === 0 || (s.rate >= 0.25 && s.rate <= 4))) return `segment ${i}: rate must be 0 or 0.25..4`
    if (s.end - s.start < 1 / 30 - 1e-6) return `segment ${i}: shorter than one frame`
    prevEnd = s.end
  }
  return null
}

// ---- fake jobs ----
// Mock engines: 'apple-local' = one speaker; 'voxtral-mini-transcribe-3' = the fixture's two
// speakers, with every 7th word flagged approximate (estimated timing).
function runTranscription(p, engine = 'fixture') {
  const t = p.transcript
  const local = engine !== 'voxtral-mini-transcribe-3'
  const words = fixture.transcript.words.map((w, i) => {
    const out = { ...w }
    if (local) out.speaker = 'S1'
    else if (i % 7 === 3) out.approximate = true
    return out
  })
  const speakers = local ? [{ id: 'S1', name: 'Speaker 1' }] : structuredClone(fixture.transcript.speakers)
  t.status = 'queued'; t.progress = 0; t.engine = engine; t.words = []; delete t.error; delete t.errorCode
  let pr = 0
  const timer = setInterval(() => {
    if (projects.get(p.id)?.project !== p || p.transcript !== t) return clearInterval(timer)
    pr = Math.min(1, pr + 0.1)
    t.status = pr >= 1 ? 'ready' : 'running'; t.progress = pr
    t.words = words.slice(0, Math.round(words.length * pr))   // words appear as it goes
    if (pr >= 1) { t.language = 'en'; t.speakers = speakers; clearInterval(timer) }
  }, 600)
}

let jobSeq = 0
function startExport(p) {
  const kept = keptDuration(p.edits.segments, p.video.duration)
  const job = { id: `exp${++jobSeq}`, status: 'queued', progress: 0, revision: p.edits.revision, duration: kept, title: p.title }
  exports.set(job.id, job)
  p.export = job
  const timer = setInterval(() => {
    if (job.status === 'canceled') return clearInterval(timer)
    job.status = 'running'; job.progress = Math.min(1, job.progress + 0.125)
    if (job.progress >= 1) {
      job.status = 'done'; job.url = `/api/exports/${job.id}/file`; job.bytes = statSync(DEMO_FILE).size
      clearInterval(timer)
    }
  }, 500)
  return job
}
function keptDuration(segments, duration) {
  let d = duration
  for (const s of segments) d -= (s.end - s.start) - (s.rate === 0 ? 0 : (s.end - s.start) / s.rate)
  return Math.round(d * 1000) / 1000
}

// ---- open any video: Bubble's panel and Spotlight, faked (docs/editor-api.md §8) ----
const SUPPORTED = ['.mp4', '.mov', '.m4v']
const unsupported = name => {
  const ext = extname(name).toLowerCase()
  return { error: 'unsupported_format', message: `Bubble can't open ${ext || 'these'} files. It edits MP4, MOV and M4V videos. Convert it to MP4 first.` }
}
const REFUSALS = {
  unsupported: () => unsupported('Screen capture.mkv'),
  undecodable: () => ({ error: 'unsupported_format', message: "Bubble can't read this video's format (VP9). Convert it to H.264 or HEVC MP4 first." }),
  no_video: () => ({ error: 'no_video', message: 'This file has no video.' }),
}
const slug = name => name.replace(/\.[^.]*$/, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'video'
/// The fake MediaCheck: by file name (see the header). A refusal, or null when it opens.
function mediaCheck(name) {
  const n = name.toLowerCase()
  if (n.includes('audio-only')) return REFUSALS.no_video()
  if (!SUPPORTED.includes(extname(n))) return unsupported(name)
  if (n.includes('vp9')) return REFUSALS.undecodable()
  return null
}

/// Same file, same project: the project of that file name, else a new one.
function projectForFile(name, folder = 'Desktop') {
  for (const { project: p } of projects.values()) if (p.source.name === name) { p.source.state = 'ok'; delete p.source.volume; return p.id }
  let id = slug(name), n = 2
  while (projects.has(id)) id = `${slug(name)}-${n++}`
  const prores = name.toLowerCase().includes('prores')
  const p = makeProject(id, name.replace(/\.[^.]*$/, ''), sourceFile(name, folder, `${HOME}${folder}`), { file: prores ? PRORES_FILE : DEMO_FILE })
  if (name.toLowerCase().includes('no-sound')) noSound(p)
  return id
}

function finishOpen(o, answer) {
  if (o.state !== 'pending') return
  const name = knobs.pick || 'Interview raw.mov'
  delete o.hold
  if (o.locate) {
    const p = projects.get(o.locate)?.project
    if (answer === 'cancel' || !p) return Object.assign(o, { state: 'canceled' })
    if (answer === 'different_video') {
      return Object.assign(o, { state: 'failed', error: 'different_video', message: "This video is a different length, so your edits wouldn't line up." })
    }
    p.source.state = 'ok'; delete p.source.volume
    return Object.assign(o, { state: 'opened', projectId: p.id, sameBytes: answer !== 'other_bytes' })
  }
  if (answer === 'cancel') return Object.assign(o, { state: 'canceled' })
  const refusal = REFUSALS[answer]?.() ?? mediaCheck(name)
  if (refusal) return Object.assign(o, { state: 'failed', ...refusal })
  Object.assign(o, { state: 'opened', projectId: projectForFile(name) })
}

function startPanel(res, locateId) {
  const answer = locateId ? knobs.locate || 'same' : knobs.panel || 'pick'
  const pending = [...opens.values()].find(o => o.state === 'pending')
  if (answer === 'busy' || pending) {
    mock.fronts++
    return fail(res, 409, 'busy', 'The file panel is already open in Bubble.')
  }
  const openId = `open${++openSeq}`
  const o = { state: 'pending', ...(locateId ? { locate: locateId } : {}) }
  opens.set(openId, o)
  mock.opens++
  if (answer === 'hold') o.hold = true
  else setTimeout(() => finishOpen(o, answer), Number(knobs.panelDelay ?? 800))
  return send(res, 202, { openId })
}

const HEX64 = /^[0-9a-f]{64}$/
async function dropped(req, res) {
  const b = await readBody(req)
  if (!b || typeof b.name !== 'string' || !b.name || !Number.isFinite(b.size) || b.size < 0 || !Number.isFinite(b.lastModified)
      || !HEX64.test(b.head ?? '') || !HEX64.test(b.tail ?? '')) {
    return fail(res, 422, 'invalid', 'Needs { name, size, lastModified, head, tail } (lowercase hex SHA-256).')
  }
  mock.dropped.push(b)
  await new Promise(r => setTimeout(r, Number(knobs.droppedDelay ?? 300)))
  const answer = knobs.dropped || 'found'
  if (answer === 'not_found') return fail(res, 404, 'not_found', `Bubble couldn't find ${b.name} on your Mac.`)
  const refusal = answer === 'unsupported' ? REFUSALS.undecodable() : answer === 'no_video' ? REFUSALS.no_video() : mediaCheck(b.name)
  if (refusal) return send(res, 422, refusal)
  return send(res, 200, { projectId: projectForFile(b.name, 'Downloads') })
}

function summary(p) {
  const reachable = p.source.state === 'ok'
  return { id: p.id, title: p.title, duration: p.video.duration, editedDuration: keptDuration(p.edits.segments, p.video.duration),
    posterUrl: reachable ? p.video.posterUrl : null, updatedAt: p.updatedAt, file: p.source }
}
/// Sends 404 for media of a file that isn't there (docs/editor-api.md §7, §8) and says so.
function unreachable(res, p) {
  if (p.source.state === 'missing') { fail(res, 404, 'source_missing', 'The video file is missing.'); return true }
  if (p.source.state === 'offline') { fail(res, 404, 'source_offline', `This video is on "${p.source.volume}", which isn't connected.`); return true }
  return false
}

// ---- http ----
const send = (res, code, body, headers = {}) => {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers })
  res.end(body === undefined ? '' : JSON.stringify(body))
}
const fail = (res, code, error, message) => send(res, code, { error, message })
const readBody = req => new Promise(r => { let b = ''; req.on('data', c => (b += c)); req.on('end', () => { try { r(b ? JSON.parse(b) : {}) } catch { r(undefined) } }) })
const cookieToken = req => /(?:^|;\s*)bubble=([^;]+)/.exec(req.headers.cookie || '')?.[1]

function sendFile(req, res, path, extra = {}) {
  if (!existsSync(path)) return fail(res, 404, 'not_found', 'No such file.')
  const size = statSync(path).size
  const type = MIME[extname(path)] || 'application/octet-stream'
  const range = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '')
  if (range) {
    const start = range[1] ? Number(range[1]) : size - Number(range[2])
    const end = range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : size - 1
    if (start >= size || start > end) return res.writeHead(416, { 'Content-Range': `bytes */${size}` }).end()
    res.writeHead(206, { 'Content-Type': type, 'Content-Length': end - start + 1, 'Content-Range': `bytes ${start}-${end}/${size}`, 'Accept-Ranges': 'bytes', ...extra })
    return createReadStream(path, { start, end }).pipe(res)
  }
  res.writeHead(200, { 'Content-Type': type, 'Content-Length': size, 'Accept-Ranges': 'bytes', ...extra })
  createReadStream(path).pipe(res)
}

function poster() {
  const p = join(tmpdir(), 'bubble-mock-poster.jpg')
  if (!existsSync(p)) spawnSync('ffmpeg', ['-v', 'error', '-y', '-ss', '1', '-i', DEMO_FILE, '-frames:v', '1', p])
  return p
}

const page = (req, res) => {
  const file = join(ROOT, 'editor', 'index.html')
  if (existsSync(file)) return sendFile(req, res, file)
  res.writeHead(200, { 'Content-Type': 'text/html' })
  return res.end('<p>web/editor/index.html is not there yet. API: <a href="/api/projects/demo">/api/projects/demo</a></p>')
}
const cookie = `bubble=${TOKEN}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000`

createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`)
  const path = url.pathname
  const host = (req.headers.host || '').toLowerCase()
  if (host !== `127.0.0.1:${PORT}` && host !== `localhost:${PORT}`) return fail(res, 403, 'bad_host', 'Wrong Host header.')
  if (url.searchParams.get('slow')) await new Promise(r => setTimeout(r, 400))

  // Pages and their assets: public. /edit/:id?t=token and /?t=token set the cookie and redirect.
  let m
  if ((m = /^\/edit\/([\w-]+)$/.exec(path))) {
    if (url.searchParams.get('t') === TOKEN) return res.writeHead(302, { Location: `/edit/${m[1]}`, 'Set-Cookie': cookie }).end()
    return page(req, res)
  }
  if (path === '/') {
    if (url.searchParams.get('t') === TOKEN) return res.writeHead(302, { Location: '/', 'Set-Cookie': cookie }).end()
    return page(req, res)
  }
  if (path.startsWith('/editor/')) {
    const file = normalize(join(ROOT, path))
    if (!file.startsWith(join(ROOT, 'editor'))) return fail(res, 404, 'not_found', 'No such file.')
    return sendFile(req, res, file)
  }

  // Everything else needs the cookie.
  if (cookieToken(req) !== TOKEN) return fail(res, 401, 'unauthorized', 'Open this page from Bubble.')

  if (req.method === 'POST' && path === '/mock/reset') {
    reset(Object.fromEntries(url.searchParams))
    return send(res, 200, project)
  }
  if (req.method === 'POST' && path === '/mock/steer') {
    Object.assign(knobs, Object.fromEntries(url.searchParams))
    return send(res, 200, knobs)
  }
  if (req.method === 'POST' && path === '/mock/panel') {
    const held = [...opens.values()].find(o => o.state === 'pending' && o.hold)
    if (!held) return fail(res, 409, 'no_panel', 'No held panel.')
    if (url.searchParams.get('pick')) knobs.pick = url.searchParams.get('pick')
    finishOpen(held, url.searchParams.get('answer') || (held.locate ? 'same' : 'pick'))
    return send(res, 200, held)
  }
  if (path === '/mock/state') return send(res, 200, mock)
  if (path === '/api/engines') return send(res, 200, { engines: engines() })
  if (path === '/api/settings' && req.method === 'GET') return send(res, 200, { mistralKey })
  if (path === '/api/settings/mistral-key') {
    if (req.method === 'DELETE') { mistralKey = 'none'; return send(res, 200, { engines: engines() }) }
    if (req.method !== 'PUT') return fail(res, 405, 'method_not_allowed', 'PUT or DELETE.')
    const body = await readBody(req)
    const key = typeof body?.key === 'string' ? body.key.trim() : ''
    // Mock rules: 'bad' (or empty) -> invalid, 'offline' -> unreachable, anything else -> valid.
    if (!key || key === 'bad') return fail(res, 422, 'invalid_key', 'Mistral did not accept this key.')
    if (key === 'offline') return fail(res, 502, 'unreachable', "Bubble couldn't reach Mistral. Check your connection.")
    mistralKey = 'keychain'
    return send(res, 200, { engines: engines() })
  }

  // Δ open any video (docs/editor-api.md §8)
  if (path === '/api/projects') {
    if (req.method !== 'GET') return fail(res, 405, 'method_not_allowed', 'GET.')
    const list = [...projects.values()].map(x => summary(x.project)).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    return send(res, 200, { projects: list })
  }
  if (path === '/api/open') {
    if (req.method !== 'POST') return fail(res, 405, 'method_not_allowed', 'POST.')
    return startPanel(res)
  }
  if (path === '/api/open/dropped') {
    if (req.method !== 'POST') return fail(res, 405, 'method_not_allowed', 'POST.')
    return dropped(req, res)
  }
  if ((m = /^\/api\/open\/([\w-]+)$/.exec(path))) {
    const o = opens.get(m[1])
    if (!o) return fail(res, 404, 'not_found', 'No such open.')
    const { hold, locate, ...state } = o
    return send(res, 200, state)
  }

  if ((m = /^\/media\/([\w-]+)\/(source|poster\.jpg)$/.exec(path))) {
    const entry = projects.get(m[1])
    if (!entry) return fail(res, 404, 'not_found', 'No such project.')
    if (unreachable(res, entry.project)) return
    if (m[2] === 'poster.jpg') return sendFile(req, res, poster())
    // Content-Type by the source's own extension (§8), whatever fixture stands in for it.
    const type = MIME[extname(entry.project.source.name).toLowerCase()] || MIME[extname(entry.file)]
    return sendFile(req, res, entry.file, { 'Content-Type': type })
  }

  if ((m = /^\/api\/exports\/(\w+)(\/file)?$/.exec(path))) {
    const job = exports.get(m[1])
    if (!job) return fail(res, 404, 'not_found', 'No such export.')
    if (m[2]) {
      if (job.status !== 'done') return fail(res, 409, 'not_ready', 'The export is not finished.')
      return sendFile(req, res, DEMO_FILE, { 'Content-Disposition': `attachment; filename="${job.title} (edited).mp4"` })
    }
    if (req.method === 'DELETE') { if (job.status === 'queued' || job.status === 'running') job.status = 'canceled'; return send(res, 200, job) }
    return send(res, 200, job)
  }

  if (!(m = /^\/api\/projects\/([\w-]+)(\/[\w]+)?$/.exec(path))) return fail(res, 404, 'not_found', 'No such route.')
  const entry = projects.get(m[1])
  if (!entry) return fail(res, 404, 'not_found', 'No such project.')
  const p = entry.project
  const sub = m[2] || ''

  if (sub === '' && req.method === 'GET') {
    // Like the real server: opening a project with no transcript starts one with the default engine.
    if (p.transcript.status === 'none' && p.source.state === 'ok') {
      const def = engines().find(e => e.default)
      if (def?.available) runTranscription(p, def.id)
      else Object.assign(p.transcript, { status: 'failed', progress: 0, error: def?.why || 'No transcription engine is available.' })
    }
    return send(res, 200, p)
  }
  if (sub === '' && req.method === 'PATCH') {
    const body = await readBody(req)
    if (!body) return fail(res, 422, 'invalid', 'Body is not JSON.')
    if (typeof body.title === 'string') p.title = body.title.trim() || p.title
    if (Array.isArray(body.speakers)) for (const s of body.speakers) {
      const sp = p.transcript.speakers.find(x => x.id === s.id); if (sp && typeof s.name === 'string') sp.name = s.name
    }
    p.updatedAt = new Date().toISOString()
    return send(res, 200, p)
  }
  if (sub === '' && req.method === 'DELETE') {
    projects.delete(p.id); mock.deleted.push(p.id)
    return send(res, 204)
  }
  if (sub === '/locate' && req.method === 'POST') return startPanel(res, p.id)
  if (sub === '/reveal' && req.method === 'POST') {
    if (unreachable(res, p)) return
    mock.revealed.push(p.id)
    return send(res, 204)
  }
  if (sub === '/edits' && req.method === 'PUT') {
    const body = await readBody(req)
    if (!body || typeof body.revision !== 'number') return fail(res, 422, 'invalid', 'Needs { revision, segments }.')
    if (body.revision !== p.edits.revision) return send(res, 409, { error: 'stale', edits: p.edits })
    const why = validate(body.segments, p.video.duration)
    if (why) return fail(res, 422, 'invalid', why)
    p.edits = { revision: p.edits.revision + 1, segments: body.segments }
    p.updatedAt = new Date().toISOString()
    return send(res, 200, { revision: p.edits.revision })
  }
  if (sub === '/waveform' && req.method === 'GET') {
    // Cached in the mock: a missing or offline video still has its waveform. No sound track: flat.
    if (p.transcript.errorCode === 'no_sound') return res.writeHead(200, { 'Content-Type': 'application/json' }).end(flatWaveform)
    return res.writeHead(200, { 'Content-Type': 'application/json' }).end(waveform)
  }
  if (sub === '/transcription' && req.method === 'POST') {
    if (unreachable(res, p)) return
    if (p.transcript.errorCode === 'no_sound') return fail(res, 422, 'no_sound', NO_SOUND)
    const body = await readBody(req)
    const list = engines()
    const engine = list.find(e => e.id === (body?.engine ?? list.find(x => x.default).id))
    if (!engine) return fail(res, 422, 'invalid', `Unknown engine ${body?.engine}.`)
    if (!engine.available) return fail(res, 422, 'engine_unavailable', engine.why || 'This engine is not available.')
    runTranscription(p, engine.id)
    return send(res, 202, { transcript: p.transcript })
  }
  if (sub === '/export' && req.method === 'POST') {
    if (unreachable(res, p)) return
    return send(res, 202, startExport(p))
  }
  return fail(res, 404, 'not_found', 'No such route.')
}).listen(PORT, '127.0.0.1', () => console.log(`mock editor server: http://127.0.0.1:${PORT}/edit/demo?t=dev`))
