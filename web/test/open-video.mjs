#!/usr/bin/env node
// Owner: QA. Contract test of "open any video" (docs/editor-api.md §8, docs/editor-open-video.md),
// against the mock (web/mock-server.mjs) AND Bubble's real server: same script, same expectations.
//
//   node web/test/open-video.mjs --base http://127.0.0.1:47621 [--token dev] --mock
//   node web/test/open-video.mjs --base ... --token <t> --media <dir> --steer <dir>
//
// Bubble's open panel and its Spotlight lookup are faked in both modes:
// - --mock: POST /mock/steer?panel=…&pick=<name> and ?dropped=… (see the mock's header);
// - real (BubbleEditorTests/OpenVideoContractTests): the server runs with a fake panel and a fake
//   lookup that read files in --steer: `pick` (a path, "cancel" or "hold"; a held panel answers
//   when `pick` changes) and `found` (the paths the lookup returns, one per line). --media holds
//   copies of web/fixtures/open-video/* that this script may rename and delete (never the fixtures).
// Prints PASS/FAIL/INFO per check, writes <out>/statuses.json; exit 1 on a FAIL.
import http from 'node:http'
import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync, statSync, existsSync, renameSync, unlinkSync, openSync, readSync, closeSync } from 'node:fs'
import { join, basename } from 'node:path'

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d }
const BASE = new URL(arg('--base', 'http://127.0.0.1:47621'))
const TOKEN = arg('--token', 'dev')
const MOCK = process.argv.includes('--mock')
const MEDIA = arg('--media', new URL('../fixtures/open-video', import.meta.url).pathname)
const STEER = arg('--steer')
const OUT = arg('--out', `build/check/editor/open-video-${MOCK ? 'mock' : 'real'}`)
const HOST = `${BASE.hostname}:${BASE.port}`
if (!MOCK && !STEER) { console.error('open-video.mjs: the real server needs --steer <dir> (or pass --mock)'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

// ---------- tiny HTTP client ----------
function req(method, path, { body, cookie = true, raw = false } = {}) {
  return new Promise((resolve, reject) => {
    const h = { Host: HOST }
    if (cookie) h.Cookie = `bubble=${TOKEN}`
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
  return ok
}
const info = (name) => console.log(`INFO  ${name}`)
function status(step, res, want) {
  statuses[step] = res.status
  const ok = Array.isArray(want) ? want.includes(res.status) : res.status === want
  return check(`${step}: ${Array.isArray(want) ? want.join('|') : want}`, ok, `got ${res.status} ${res.buf.toString('utf8').slice(0, 200)}`)
}
const isNum = (x) => typeof x === 'number' && Number.isFinite(x)
const isStr = (x) => typeof x === 'string'
const oneOf = (...xs) => (x) => xs.includes(x)
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
const SOURCE = { name: isStr, folder: isStr, path: isStr, state: oneOf('ok', 'missing', 'offline'), 'volume?': isStr }
const SUMMARY = { id: isStr, title: isStr, duration: isNum, editedDuration: isNum, posterUrl: (x) => x === null || isStr(x),
  updatedAt: (x) => isStr(x) && !isNaN(Date.parse(x)), file: SOURCE }
const OPENSTATE = { state: oneOf('pending', 'opened', 'canceled', 'failed'), 'projectId?': isStr, 'sameBytes?': (x) => typeof x === 'boolean',
  'error?': oneOf('unsupported_format', 'no_video', 'different_video'), 'message?': isStr }
const errorShape = (j) => shape(j, { error: isStr, message: isStr })

// ---------- the fake panel and lookup ----------
const media = (name) => join(MEDIA, name)
async function steerPanel(what) {          // what: a fixture file name, 'cancel' or 'hold'
  if (MOCK) {
    const q = what === 'cancel' || what === 'hold' ? `panel=${what}` : `panel=pick&pick=${encodeURIComponent(what)}`
    return req('POST', `/mock/steer?${q}&panelDelay=100`)
  }
  writeFileSync(join(STEER, 'pick'), what === 'cancel' || what === 'hold' ? what : media(what))
}
async function answerHeld(what) {
  if (MOCK) return req('POST', `/mock/panel?answer=${what === 'cancel' ? 'cancel' : 'pick'}&pick=${encodeURIComponent(what)}`)
    .then(() => {})
  writeFileSync(join(STEER, 'pick'), what === 'cancel' ? 'cancel' : media(what))
}
async function steerLookup(names) {        // the files Spotlight "finds"
  if (MOCK) return req('POST', `/mock/steer?dropped=${names.length ? 'found' : 'not_found'}&droppedDelay=50`)
  writeFileSync(join(STEER, 'found'), names.map(media).join('\n'))
}
/** POST /api/open (or locate), then poll until it ends. */
async function openAndWait(path = '/api/open', step = 'open') {
  const r = await req('POST', path)
  if (!status(`${step}: 202 { openId }`, r, 202)) return null
  const id = r.json?.openId
  for (let i = 0; i < 100; i++) {
    const s = await req('GET', `/api/open/${id}`)
    if (s.status !== 200) { status(`${step}: poll`, s, 200); return null }
    if (s.json?.state !== 'pending') {
      const p = shape(s.json, OPENSTATE)
      check(`${step}: OpenState shape`, p.length === 0, p.join(', '))
      return s.json
    }
    await sleep(100)
  }
  check(`${step}: ends within 10 s`, false)
  return null
}
const sha = (buf) => createHash('sha256').update(buf).digest('hex')
const shaFile = (path) => sha(readFileSync(path))
/** The drop body the page sends (docs/editor-api.md §8): hashes of the first and last 1 MiB. */
function dropBody(path) {
  const st = statSync(path), MiB = 1 << 20
  let head, tail
  if (st.size < 2 * MiB) head = tail = shaFile(path)
  else {
    const fd = openSync(path, 'r'), b = Buffer.alloc(MiB)
    readSync(fd, b, 0, MiB, 0); head = sha(b)
    readSync(fd, b, 0, MiB, st.size - MiB); tail = sha(b)
    closeSync(fd)
  }
  return { name: basename(path), size: st.size, lastModified: Math.round(st.mtimeMs), head, tail }
}

// ---------- the script ----------
if (MOCK) await req('POST', '/mock/reset?transcript=ready&edits=empty')
const hashes = Object.fromEntries(['h264.mp4', 'h264.mov', 'no-sound.mp4', 'prores.mov'].map((n) => [n, shaFile(media(n))]))
let r

// Home page and the list
r = await req('GET', `/?t=${TOKEN}`, { cookie: false })
status('GET /?t=token', r, 302)
check('/?t= sets the cookie and redirects to /', r.headers.location === '/' && /bubble=/.test(r.headers['set-cookie']?.[0] || ''), JSON.stringify(r.headers))
r = await req('GET', '/')
status('GET / (home)', r, 200)
check('home is the page (text/html)', /text\/html/.test(r.headers['content-type'] || ''), r.headers['content-type'])
r = await req('GET', '/api/projects', { cookie: false })
status('GET /api/projects without the cookie', r, 401)
r = await req('GET', '/api/projects')
status('GET /api/projects', r, 200)
const list0 = r.json?.projects
check('{ projects: ProjectSummary[] }', Array.isArray(list0) && list0.every((s) => shape(s, SUMMARY).length === 0),
  JSON.stringify(list0?.map((s) => shape(s, SUMMARY)).flat()))

// A. Open Video…: pick, same file again, cancel, busy, refusals
await steerPanel('h264.mov')
const opened = await openAndWait('/api/open', 'open h264.mov')
check('picked → opened with a projectId', opened?.state === 'opened' && isStr(opened?.projectId), JSON.stringify(opened))
const movId = opened?.projectId
r = await req('GET', `/api/projects/${movId}`)
status('GET the opened project', r, 200)
const mov = r.json
check('Project.source: SourceFile', shape(mov?.source, SOURCE).length === 0, JSON.stringify(mov?.source))
check('source.name is the file name, state ok', mov?.source?.name === 'h264.mov' && mov?.source?.state === 'ok', JSON.stringify(mov?.source))
check('title defaults to the name without extension', mov?.title === 'h264', mov?.title)
r = await req('GET', mov?.video?.url ?? `/media/${movId}/source`, { raw: true })
status('GET its source', r, 200)
check('.mov is served as video/quicktime', /^video\/quicktime/.test(r.headers['content-type'] || ''), r.headers['content-type'])
if (!MOCK) check('served bytes = the file', sha(r.buf) === hashes['h264.mov'])
r = await req('GET', '/api/projects')
const ids = r.json?.projects?.map((p) => p.id) ?? []
check('the opened video is in the list', ids.includes(movId), JSON.stringify(ids))
const times = r.json?.projects?.map((p) => Date.parse(p.updatedAt)) ?? []
check('the list is last edited first', times.every((t, i) => i === 0 || times[i - 1] >= t), JSON.stringify(r.json?.projects?.map((p) => p.updatedAt)))

await steerPanel('h264.mov')
const again = await openAndWait('/api/open', 'open h264.mov again')
check('same file → same project (rule 4)', again?.state === 'opened' && again?.projectId === movId, JSON.stringify(again))

await steerPanel('cancel')
const canceled = await openAndWait('/api/open', 'cancel the panel')
check('cancel → canceled, no project', canceled?.state === 'canceled' && canceled?.projectId === undefined, JSON.stringify(canceled))

await steerPanel('hold')
r = await req('POST', '/api/open')
status('open with the panel held', r, 202)
const heldId = r.json?.openId
r = await req('GET', `/api/open/${heldId}`)
check('held panel → pending', r.json?.state === 'pending', JSON.stringify(r.json))
r = await req('POST', '/api/open')
status('a second open while the panel is up: 409', r, 409)
check('409 { error: "busy", message }', r.json?.error === 'busy' && errorShape(r.json).length === 0, JSON.stringify(r.json))
if (MOCK) { const s = await req('GET', '/mock/state'); check('busy → Bubble re-fronts the panel', s.json?.fronts >= 1, JSON.stringify(s.json)) }
await answerHeld('h264.mp4')
let held
for (let i = 0; i < 50; i++) { held = (await req('GET', `/api/open/${heldId}`)).json; if (held?.state !== 'pending') break; await sleep(100) }
check('the held panel answers → opened', held?.state === 'opened' && isStr(held?.projectId) && held?.projectId !== movId, JSON.stringify(held))
const mp4Id = held?.projectId

for (const [file, error, words] of [
  ['h264.mkv', 'unsupported_format', ".mkv files. It edits MP4, MOV and M4V videos"],
  ['clip.webm', 'unsupported_format', ".webm files"],
  ['vp9.mp4', 'unsupported_format', "Bubble can't read this video's format"],
  ['audio-only.m4a', 'no_video', 'This file has no video.'],
  ['audio-only.mp4', 'no_video', 'This file has no video.'],
  ['not-a-video.mp4', 'unsupported_format', "Bubble can't"],
]) {
  if (MOCK && file === 'not-a-video.mp4') continue   // the mock checks names, not bytes
  await steerPanel(file)
  const o = await openAndWait('/api/open', `open ${file}`)
  check(`${file} → failed ${error}`, o?.state === 'failed' && o?.error === error, JSON.stringify(o))
  check(`${file}: the sentence says why ("${words}")`, (o?.message || '').includes(words), o?.message)
}
r = await req('GET', '/api/open/no-such-open')
status('GET /api/open/<unknown>', r, 404)
r = await req('GET', '/api/open')
status('GET /api/open (wrong method)', r, [404, 405])

// No sound, ProRes
await steerPanel('no-sound.mp4')
const ns = await openAndWait('/api/open', 'open no-sound.mp4')
r = await req('GET', `/api/projects/${ns?.projectId}`)
status('GET the no-sound project', r, 200)
for (let i = 0; i < 100 && ['queued', 'running', 'none'].includes(r.json?.transcript?.status); i++) {
  await sleep(100); r = await req('GET', `/api/projects/${ns?.projectId}`)
}
check('no sound → transcript failed, errorCode no_sound', r.json?.transcript?.status === 'failed' && r.json?.transcript?.errorCode === 'no_sound', JSON.stringify({ ...r.json?.transcript, words: undefined }))
check('no sound: the sentence', r.json?.transcript?.error === "This video has no sound, so there's no transcript.", r.json?.transcript?.error)
await steerPanel('prores.mov')
const pr = await openAndWait('/api/open', 'open prores.mov')
check('ProRes opens (the browser may not play it, Bubble can)', pr?.state === 'opened', JSON.stringify(pr))

// B. Drop on the page
r = await req('POST', '/api/open/dropped', { body: { name: 'x.mp4', size: 1 } })
status('drop without hashes', r, 422)
r = await req('POST', '/api/open/dropped', { body: { ...dropBody(media('h264.mp4')), head: 'ABC' } })
status('drop with a bad hash', r, 422)
await steerLookup(['h264.mp4'])
r = await req('POST', '/api/open/dropped', { body: dropBody(media('h264.mp4')) })
status('drop h264.mp4 (found)', r, 200)
check('drop → the project already opened from the panel (same file)', r.json?.projectId === mp4Id, `${r.json?.projectId} vs ${mp4Id}`)
await steerLookup([])
r = await req('POST', '/api/open/dropped', { body: { ...dropBody(media('h264.mp4')), name: 'From Photos.mp4' } })
status('drop a file Bubble cannot find', r, 404)
check('404 { error: "not_found", message }', r.json?.error === 'not_found' && errorShape(r.json).length === 0, JSON.stringify(r.json))
if (!MOCK) {
  await steerLookup(['h264.mp4'])
  r = await req('POST', '/api/open/dropped', { body: { ...dropBody(media('h264.mp4')), tail: '0'.repeat(64) } })
  status('drop: same name and size, other bytes → not found', r, 404)
  r = await req('POST', '/api/open/dropped', { body: { ...dropBody(media('h264.mp4')), size: 1 } })
  status('drop: other size → not found', r, 404)
}
await steerLookup(['clip.webm'])
r = await req('POST', '/api/open/dropped', { body: dropBody(media('clip.webm')) })
status('drop a .webm', r, 422)
check('422 unsupported_format with the sentence', r.json?.error === 'unsupported_format' && /\.webm/.test(r.json?.message || ''), JSON.stringify(r.json))

// Delete: the project goes, never the video
const mp4Hash = shaFile(media('h264.mp4'))
r = await req('DELETE', `/api/projects/${mp4Id}`)
status('DELETE the project', r, 204)
r = await req('GET', `/api/projects/${mp4Id}`)
status('deleted project → 404', r, 404)
r = await req('GET', '/api/projects')
check('deleted project left the list', !r.json?.projects?.some((p) => p.id === mp4Id))
check('the video file is still there, unchanged', existsSync(media('h264.mp4')) && shaFile(media('h264.mp4')) === mp4Hash)

// Reveal, rename, missing, locate
r = await req('POST', `/api/projects/${movId}/reveal`)
status('reveal (Show in Finder)', r, 204)
if (!MOCK) {
  renameSync(media('h264.mov'), media('h264 renamed.mov'))
  r = await req('GET', `/api/projects/${movId}`)
  check('renamed on the same drive → found by its bookmark', r.json?.source?.state === 'ok' && r.json?.source?.name === 'h264 renamed.mov', JSON.stringify(r.json?.source))
  r = await req('GET', `/media/${movId}/source`, { raw: true })
  check('renamed: source still served', r.status === 200 && sha(r.buf) === hashes['h264.mov'], `${r.status}`)
  unlinkSync(media('h264 renamed.mov'))     // deleted (a bookmark follows a move, not a delete)
} else {
  await req('POST', '/mock/reset?transcript=ready&edits=empty&source=missing')
}
const goneId = MOCK ? 'demo' : movId
r = await req('GET', `/api/projects/${goneId}`)
status('a missing video still opens its project', r, 200)
check('source.state missing', r.json?.source?.state === 'missing', JSON.stringify(r.json?.source))
r = await req('GET', `/media/${goneId}/source`)
check('missing: source → 404 source_missing', r.status === 404 && r.json?.error === 'source_missing', `${r.status} ${r.buf}`)
r = await req('POST', `/api/projects/${goneId}/reveal`)
check('missing: reveal → 404 source_missing', r.status === 404 && r.json?.error === 'source_missing', `${r.status} ${r.buf}`)
r = await req('GET', '/api/projects')
const goneRow = r.json?.projects?.find((p) => p.id === goneId)
check('home row says missing, no poster', goneRow?.file?.state === 'missing' && goneRow?.posterUrl === null, JSON.stringify(goneRow))

if (MOCK) await req('POST', '/mock/steer?locate=different_video&panelDelay=100')
else await steerPanel('one-second.mp4')                            // 1 s, the lost file was 2 s
let loc = await openAndWait(`/api/projects/${goneId}/locate`, 'locate a different video')
check('locate a file of another length → failed different_video', loc?.state === 'failed' && loc?.error === 'different_video', JSON.stringify(loc))
check('different_video: the sentence', (loc?.message || '').includes("different length"), loc?.message)
if (MOCK) await req('POST', '/mock/steer?locate=other_bytes')
else await steerPanel('hevc.mp4')                                  // same 2 s length, other bytes
loc = await openAndWait(`/api/projects/${goneId}/locate`, 'locate same length, other bytes')
check('same length, other bytes → opened, sameBytes false', loc?.state === 'opened' && loc?.projectId === goneId && loc?.sameBytes === false, JSON.stringify(loc))
r = await req('GET', `/api/projects/${goneId}`)
check('relinked: source ok again', r.json?.source?.state === 'ok', JSON.stringify(r.json?.source))

if (MOCK) {
  await req('POST', '/mock/reset?transcript=ready&edits=empty&source=offline')
  r = await req('GET', '/api/projects/demo')
  check('offline: state offline with the volume', r.json?.source?.state === 'offline' && r.json?.source?.volume === 'T7', JSON.stringify(r.json?.source))
  r = await req('GET', '/media/demo/source')
  check('offline: source → 404 source_offline', r.status === 404 && r.json?.error === 'source_offline', `${r.status} ${r.buf}`)
} else info('offline volume: covered by the Swift identity tests (a disk image), not here')

// Rule 2: the videos are never written.
if (!MOCK) for (const n of ['no-sound.mp4', 'prores.mov']) check(`${n} unchanged (sha256)`, shaFile(media(n)) === hashes[n])

writeFileSync(join(OUT, 'statuses.json'), JSON.stringify(statuses, null, 2))
console.log(fails ? `${fails} FAILED` : 'ALL PASS')
process.exit(fails ? 1 : 0)
