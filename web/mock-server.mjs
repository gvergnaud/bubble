#!/usr/bin/env node
// Mock of Bubble's editor server: the API of docs/editor-api.md over the fixture in web/fixtures/.
// Owner: architect. No dependencies: `node web/mock-server.mjs [--port 47621]`, then open
// http://127.0.0.1:47621/edit/demo?t=dev . State is in memory (restart = back to the fixture).
//
// Extras for building the page (not in the real server):
//   POST /mock/reset?transcript=ready|none|running|failed&edits=fixture|empty
//     (transcript=none: the next GET /api/projects/demo starts the default engine, like Bubble)
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
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.json': 'application/json', '.woff2': 'font/woff2', '.mp4': 'video/mp4' }

const fixture = JSON.parse(readFileSync(join(FIX, 'demo.project.json'), 'utf8'))
const waveform = readFileSync(join(FIX, 'demo.waveform.json'), 'utf8')
let project
const exports = new Map()
let mistralKey = 'none'   // 'keychain' | 'environment' | 'none' (mock: set by PUT /api/settings/mistral-key)
function engines() {
  const hasKey = mistralKey !== 'none'
  return [
    { id: 'voxtral-mini-transcribe-3', name: 'Voxtral 3 (Mistral API)', local: false, available: hasKey,
      ...(hasKey ? {} : { why: 'Add your Mistral API key.' }), default: hasKey },
    { id: 'apple-local', name: 'On this Mac', local: true, available: true, default: !hasKey },
  ]
}
function reset({ transcript = 'ready', edits = 'fixture' } = {}) {
  project = structuredClone(fixture)
  if (edits === 'empty') project.edits = { revision: 0, segments: [] }
  const t = project.transcript
  if (transcript !== 'ready') {
    t.status = transcript; t.progress = transcript === 'running' ? 0.35 : 0; t.words = transcript === 'running' ? t.words.slice(0, 40) : []
    if (transcript === 'none') { t.engine = null; t.language = null; t.speakers = [] }
    if (transcript === 'failed') t.error = 'The transcription engine could not be reached.'
  }
  if (transcript === 'running') runTranscription()
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
function runTranscription(engine = 'fixture') {
  const t = project.transcript
  const local = engine !== 'voxtral-mini-transcribe-3'
  const words = fixture.transcript.words.map((w, i) => {
    const out = { ...w }
    if (local) out.speaker = 'S1'
    else if (i % 7 === 3) out.approximate = true
    return out
  })
  const speakers = local ? [{ id: 'S1', name: 'Speaker 1' }] : structuredClone(fixture.transcript.speakers)
  t.status = 'queued'; t.progress = 0; t.engine = engine; t.words = []; delete t.error
  let p = 0
  const timer = setInterval(() => {
    if (project.transcript !== t) return clearInterval(timer)
    p = Math.min(1, p + 0.1)
    t.status = p >= 1 ? 'ready' : 'running'; t.progress = p
    t.words = words.slice(0, Math.round(words.length * p))   // words appear as it goes
    if (p >= 1) { t.language = 'en'; t.speakers = speakers; clearInterval(timer) }
  }, 600)
}

let jobSeq = 0
function startExport() {
  const kept = keptDuration(project.edits.segments, project.video.duration)
  const job = { id: `exp${++jobSeq}`, status: 'queued', progress: 0, revision: project.edits.revision, duration: kept }
  exports.set(job.id, job)
  project.export = job
  const timer = setInterval(() => {
    if (job.status === 'canceled') return clearInterval(timer)
    job.status = 'running'; job.progress = Math.min(1, job.progress + 0.125)
    if (job.progress >= 1) {
      job.status = 'done'; job.url = `/api/exports/${job.id}/file`; job.bytes = statSync(join(FIX, 'demo.mp4')).size
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
  if (!existsSync(p)) spawnSync('ffmpeg', ['-v', 'error', '-y', '-ss', '1', '-i', join(FIX, 'demo.mp4'), '-frames:v', '1', p])
  return p
}

createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`)
  const path = url.pathname
  const host = (req.headers.host || '').toLowerCase()
  if (host !== `127.0.0.1:${PORT}` && host !== `localhost:${PORT}`) return fail(res, 403, 'bad_host', 'Wrong Host header.')
  if (url.searchParams.get('slow')) await new Promise(r => setTimeout(r, 400))

  // Page and its assets: public. /edit/:id?t=token sets the cookie and redirects.
  let m
  if ((m = /^\/edit\/([\w-]+)$/.exec(path))) {
    if (url.searchParams.get('t') === TOKEN) {
      return res.writeHead(302, { Location: `/edit/${m[1]}`, 'Set-Cookie': `bubble=${TOKEN}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000` }).end()
    }
    const page = join(ROOT, 'editor', 'index.html')
    if (existsSync(page)) return sendFile(req, res, page)
    res.writeHead(200, { 'Content-Type': 'text/html' })
    return res.end('<p>web/editor/index.html is not there yet. API: <a href="/api/projects/demo">/api/projects/demo</a></p>')
  }
  if (path.startsWith('/editor/')) {
    const file = normalize(join(ROOT, path))
    if (!file.startsWith(join(ROOT, 'editor'))) return fail(res, 404, 'not_found', 'No such file.')
    return sendFile(req, res, file)
  }

  // Everything else needs the cookie.
  if (cookieToken(req) !== TOKEN) return fail(res, 401, 'unauthorized', 'Open this page from Bubble.')

  if (req.method === 'POST' && path === '/mock/reset') {
    reset({ transcript: url.searchParams.get('transcript') || 'ready', edits: url.searchParams.get('edits') || 'fixture' })
    return send(res, 200, project)
  }
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
  if (path === '/media/demo/source') return sendFile(req, res, join(FIX, 'demo.mp4'))
  if (path === '/media/demo/poster.jpg') return sendFile(req, res, poster())

  if ((m = /^\/api\/exports\/(\w+)(\/file)?$/.exec(path))) {
    const job = exports.get(m[1])
    if (!job) return fail(res, 404, 'not_found', 'No such export.')
    if (m[2]) {
      if (job.status !== 'done') return fail(res, 409, 'not_ready', 'The export is not finished.')
      return sendFile(req, res, join(FIX, 'demo.mp4'), { 'Content-Disposition': `attachment; filename="${project.title} (edited).mp4"` })
    }
    if (req.method === 'DELETE') { if (job.status === 'queued' || job.status === 'running') job.status = 'canceled'; return send(res, 200, job) }
    return send(res, 200, job)
  }

  if (!(m = /^\/api\/projects\/([\w-]+)(\/[\w]+)?$/.exec(path))) return fail(res, 404, 'not_found', 'No such route.')
  if (m[1] !== project.id) return fail(res, 404, 'not_found', 'No such project.')
  const sub = m[2] || ''

  if (sub === '' && req.method === 'GET') {
    // Like the real server: opening a project with no transcript starts one with the default engine.
    if (project.transcript.status === 'none') {
      const def = engines().find(e => e.default)
      if (def?.available) runTranscription(def.id)
      else Object.assign(project.transcript, { status: 'failed', progress: 0, error: def?.why || 'No transcription engine is available.' })
    }
    return send(res, 200, project)
  }
  if (sub === '' && req.method === 'PATCH') {
    const body = await readBody(req)
    if (!body) return fail(res, 422, 'invalid', 'Body is not JSON.')
    if (typeof body.title === 'string') project.title = body.title.trim() || project.title
    if (Array.isArray(body.speakers)) for (const s of body.speakers) {
      const sp = project.transcript.speakers.find(x => x.id === s.id); if (sp && typeof s.name === 'string') sp.name = s.name
    }
    project.updatedAt = new Date().toISOString()
    return send(res, 200, project)
  }
  if (sub === '/edits' && req.method === 'PUT') {
    const body = await readBody(req)
    if (!body || typeof body.revision !== 'number') return fail(res, 422, 'invalid', 'Needs { revision, segments }.')
    if (body.revision !== project.edits.revision) return send(res, 409, { error: 'stale', edits: project.edits })
    const why = validate(body.segments, project.video.duration)
    if (why) return fail(res, 422, 'invalid', why)
    project.edits = { revision: project.edits.revision + 1, segments: body.segments }
    project.updatedAt = new Date().toISOString()
    return send(res, 200, { revision: project.edits.revision })
  }
  if (sub === '/waveform' && req.method === 'GET') return res.writeHead(200, { 'Content-Type': 'application/json' }).end(waveform)
  if (sub === '/transcription' && req.method === 'POST') {
    const body = await readBody(req)
    const list = engines()
    const engine = list.find(e => e.id === (body?.engine ?? list.find(x => x.default).id))
    if (!engine) return fail(res, 422, 'invalid', `Unknown engine ${body?.engine}.`)
    if (!engine.available) return fail(res, 422, 'engine_unavailable', engine.why || 'This engine is not available.')
    runTranscription(engine.id)
    return send(res, 202, { transcript: project.transcript })
  }
  if (sub === '/export' && req.method === 'POST') return send(res, 202, startExport())
  return fail(res, 404, 'not_found', 'No such route.')
}).listen(PORT, '127.0.0.1', () => console.log(`mock editor server: http://127.0.0.1:${PORT}/edit/demo?t=dev`))
