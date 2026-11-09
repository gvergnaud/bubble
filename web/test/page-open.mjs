#!/usr/bin/env node
// Owner: QA. Headless checks (Chrome --headless=new over CDP: no window, muted) of "open any video"
// in the page (docs/editor-open-video.md §2-§4), on its OWN mock server (web/mock-server.mjs on a free
// port), so it can stop it for "Bubble not running". Complements designer's web/editor/test/e2e-open.mjs
// (home list, row menu, Open Video… waiting/picked/canceled, drop found/not found/two files/.mkv,
// missing + Locate…, offline drive, can't play, no sound) with what it leaves out:
// a row click opens its editor (a missing one too), the button's busy class, a pending open survives a
// reload, the VP9 and no-video refusals, "This isn't a video", a drop on an editor page opens the
// other video in the same tab, Bubble not running (buttons off, "Open Bubble to open a video"), no JS error.
//   node web/test/page-open.mjs [--out build/check/editor/page-open]
// Screenshots: <out>/open-*.png. Exit 1 on a FAIL.
import { spawn } from 'node:child_process'
import { writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { createServer } from 'node:net'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d }
const OUT = arg('--out', 'build/check/editor/page-open')
const CHROME = arg('--chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
const ROOT = new URL('../', import.meta.url).pathname
const MEDIA = join(ROOT, 'fixtures/open-video')
mkdirSync(OUT, { recursive: true })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const freePort = () => new Promise((r) => { const s = createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)) }) })

let fails = 0
const lines = []
const check = (name, ok, detail = '') => { if (!ok) fails++; const l = `${ok ? 'PASS' : 'FAIL'}  ${name}${!ok && detail ? '  · ' + detail : ''}`; lines.push(l); console.log(l); return ok }

// ---------- the mock server (ours) ----------
const mockPort = await freePort()
const BASE = `http://127.0.0.1:${mockPort}`
let mock
async function startMock() {
  mock = spawn(process.execPath, [join(ROOT, 'mock-server.mjs'), '--port', String(mockPort)], { stdio: 'ignore' })
  for (let i = 0; i < 50; i++) { try { await fetch(`${BASE}/editor/index.html`); return } catch { await sleep(100) } }
  throw new Error('mock server did not start')
}
const stopMock = async () => { mock?.kill('SIGKILL'); await sleep(200) }
const api = async (method, path) => {
  const res = await fetch(BASE + path, { method, headers: { cookie: 'bubble=dev' } })
  return res.headers.get('content-type')?.includes('json') ? res.json() : res.text()
}
const reset = (q) => api('POST', `/mock/reset?${q}`)
const steer = (q) => api('POST', `/mock/steer?${q}`)

// ---------- Chrome over CDP ----------
const debugPort = await freePort()
const profile = join(tmpdir(), `bubble-page-open-${process.pid}`)
const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--mute-audio', '--no-first-run', '--no-default-browser-check',
  `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`, '--window-size=1440,900', '--force-device-scale-factor=1',
  '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' })
const cleanup = () => { try { chrome.kill('SIGKILL') } catch {} ; try { mock?.kill('SIGKILL') } catch {} ; try { rmSync(profile, { recursive: true, force: true }) } catch {} }
process.on('exit', cleanup)

let ws, seq = 0
const pending = new Map()
async function connect() {
  for (let i = 0; i < 100; i++) {
    try { const list = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json(); const pg = list.find((t) => t.type === 'page'); if (pg) return pg.webSocketDebuggerUrl } catch {}
    await sleep(100)
  }
  throw new Error('Chrome did not start')
}
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++seq; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })) })
const ev = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || JSON.stringify(r.exceptionDetails)); return r.result.value }
const mouse = (type, x, y) => send('Input.dispatchMouseEvent', { type, x, y, button: type === 'mouseMoved' ? 'none' : 'left', buttons: type === 'mouseMoved' ? 0 : 1, clickCount: 1 })
async function click(x, y) { await mouse('mouseMoved', x, y); await mouse('mousePressed', x, y); await mouse('mouseReleased', x, y); await sleep(200) }
async function shot(name) { const r = await send('Page.captureScreenshot', { format: 'png' }); writeFileSync(join(OUT, `open-${name}.png`), Buffer.from(r.data, 'base64')) }
const text = (sel) => ev(`document.querySelector(${JSON.stringify(sel)})?.textContent?.trim() || ''`)
const path = () => ev('location.pathname')
async function go(p) { await send('Page.navigate', { url: `${BASE}${p}${p.includes('?') ? '&' : '?'}t=dev` }); await sleep(1500) }
async function waitFor(expr, ms = 6000) { for (let i = 0; i < ms / 100; i++) { if (await ev(expr).catch(() => false)) return true; await sleep(100) } return false }
async function press(sel, words = '') {
  const p = await ev(`(() => { const b = [...document.querySelectorAll(${JSON.stringify(sel)})].find(x => x.textContent.includes(${JSON.stringify(words)})); if (!b) return null; b.scrollIntoView({ block: 'center' }); const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
  if (!p) throw new Error(`nothing to press: ${sel} "${words}"`)
  await click(p.x, p.y)
}
async function dropFiles(files, type = 'drop') {
  const data = { items: [], files, dragOperationsMask: 1 }
  await send('Input.dispatchDragEvent', { type: 'dragEnter', x: 700, y: 450, data })
  await send('Input.dispatchDragEvent', { type: 'dragOver', x: 700, y: 450, data })
  await sleep(150)
  if (type === 'hover') return
  await send('Input.dispatchDragEvent', { type: 'drop', x: 700, y: 450, data })
  await sleep(300)
}
const cancelDrag = () => send('Input.dispatchDragEvent', { type: 'dragCancel', x: 700, y: 450, data: { items: [], dragOperationsMask: 1 } }).catch(() => {})

try {
  await startMock()
  ws = new WebSocket(await connect())
  await new Promise((r) => ws.addEventListener('open', r))
  ws.addEventListener('message', (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { const p = pending.get(d.id); pending.delete(d.id); d.error ? p.rej(new Error(d.error.message)) : p.res(d.result) } })
  await send('Page.enable'); await send('Runtime.enable'); await send('Log.enable')
  const errors = []
  let expectOffline = false   // console errors from refused connections while Bubble is "quit" are expected
  ws.addEventListener('message', (m) => {
    const d = JSON.parse(m.data)
    if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails?.exception?.description || 'exception')
    if (d.method === 'Log.entryAdded' && d.params.entry.level === 'error' && !/favicon/.test(d.params.entry.url || '')
        && !(expectOffline && /ERR_CONNECTION_REFUSED|Failed to fetch|net::/.test(d.params.entry.text))
        && !/\/media\/[\w-]+\/(source|poster\.jpg)/.test(d.params.entry.url || '')) errors.push(`${d.params.entry.text} ${d.params.entry.url || ''}`)
  })

  // ---- F. Home: a row opens its editor; a missing one opens in its missing state ----
  await reset('projects=fixture&edits=fixture')
  await go('/')
  check('home: the page is the home (body.home-page)', await waitFor(`document.body.classList.contains('home-page') && document.querySelectorAll('#rows > li.row').length >= 4`))
  const order = await ev(`[...document.querySelectorAll('#rows .row-title')].map(x => x.textContent.trim())`)
  check('home: last edited first', order.join('|') === 'Bubble demo|Interview raw|Keynote rehearsal|Old take', order.join('|'))
  check('home: each row has a length', await ev(`[...document.querySelectorAll('#rows .row-meta')].every(x => /\\d+:\\d\\d/.test(x.textContent))`))
  check('home: the demo row shows the edited length (cuts)', /1:02|1:03/.test(await text('#rows > li.row .row-meta')), await text('#rows > li.row .row-meta'))
  check('home: missing/offline rows have the warn thumb', (await ev(`document.querySelectorAll('#rows .thumb.warn').length`)) === 2)
  check('home: the folder has the full path as tooltip', /\/Desktop\/Interview raw\.mov$/.test(await ev(`[...document.querySelectorAll('#rows [title]')].map(x => x.title).join('|')`)) || /\/Desktop/.test(await ev(`[...document.querySelectorAll('#rows [title]')].map(x => x.title).join('|')`)), await ev(`[...document.querySelectorAll('#rows [title]')].map(x => x.title).join('|')`))
  await shot('01-home')
  await press('#rows .row-title', 'Interview raw')
  check('row click → its editor', await waitFor(`location.pathname === '/edit/interview'`), await path())
  await go('/')
  await press('#rows .row-title', 'Old take')
  check('missing row click → its editor in the missing state', await waitFor(`location.pathname === '/edit/old-take' && /missing/i.test(document.querySelector('.source-state')?.textContent || '')`, 8000), await text('.source-state'))
  check('missing editor: the transcript is still there', (await ev(`document.querySelectorAll('.w').length`)) > 100)
  await shot('02-missing-from-home')

  // ---- A. Open Video…: busy class, a pending open survives a reload, VP9 and no-video refusals ----
  await reset('projects=fixture&panel=hold')
  await go('/')
  await press('#openVideo')
  check('Open Video…: the button gets .busy while the panel is up', await waitFor(`document.getElementById('openVideo').classList.contains('busy')`))
  await send('Page.reload'); await sleep(1500)
  check('reload: the pending open is picked up again (button busy)', await waitFor(`document.getElementById('openVideo').classList.contains('busy') && /Choose a video in Bubble/.test(document.getElementById('openVideo').textContent)`))
  await shot('03-pending-after-reload')
  await api('POST', '/mock/panel?answer=pick&pick=Picked%20after%20reload.mp4')
  check('…and goes to the picked video when Bubble answers', await waitFor(`location.pathname === '/edit/picked-after-reload'`, 8000), await path())
  for (const [answer, words, name] of [['undecodable', "can't read this video's format (VP9)", 'vp9'], ['no_video', 'This file has no video.', 'no-video']]) {
    await steer(`panel=${answer}&panelDelay=200`)
    await go('/')
    await press('#openVideo')
    check(`Open Video… refused (${answer}): "${words}"`, await waitFor(`(document.querySelector('.notice')?.textContent || '').includes(${JSON.stringify(words)})`), await text('.notice'))
    check(`refused (${answer}): the button comes back`, await waitFor(`!document.getElementById('openVideo').classList.contains('busy')`))
    await shot(`04-refused-${name}`)
  }

  // ---- B. Drop: "This isn't a video", a drop on an editor page opens the other video in the same tab ----
  await reset('projects=fixture&droppedDelay=100')
  await go('/')
  const notVideo = join(OUT, 'notes.txt'); writeFileSync(notVideo, 'not a video\n')
  await dropFiles([notVideo], 'hover')
  check('drag a text file: "This isn\'t a video"', /This isn't a video/.test(await text('.drop-text')) && await ev(`document.querySelector('.drop-overlay').classList.contains('no')`), await text('.drop-text'))
  await shot('05-not-a-video-overlay')
  // The page answered dropEffect 'none': Chrome refuses the drop itself, nothing reaches the page.
  await send('Input.dispatchDragEvent', { type: 'drop', x: 700, y: 450, data: { items: [], files: [notVideo], dragOperationsMask: 1 } }); await sleep(400)
  check('drop it: nothing opens, nothing is looked up', (await path()) === '/' && (await api('GET', '/mock/state')).dropped.length === 0
    && !/Finding/.test(await text('.notice')), `${await path()} · notice "${await text('.notice')}"`)
  await go('/edit/demo')
  await ev(`document.querySelectorAll('.w').length`)
  const tabs0 = (await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json()).filter((t) => t.type === 'page').length
  await dropFiles([join(MEDIA, 'h264.mp4')])
  check('drop on an editor page → the other video, same tab', await waitFor(`location.pathname === '/edit/h264'`, 8000), await path())
  const tabs1 = (await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json()).filter((t) => t.type === 'page').length
  check('…no new tab', tabs1 === tabs0, `${tabs0} → ${tabs1}`)
  const dropped = (await api('GET', '/mock/state')).dropped.at(-1)
  check('the drop body carries no path', dropped?.name === 'h264.mp4' && !JSON.stringify(dropped).includes('/'), JSON.stringify(dropped))
  await shot('06-dropped-on-editor')

  // ---- Bubble not running: Open Video… and drop are off, the page says "Open Bubble…" ----
  await go('/')
  await waitFor(`document.querySelectorAll('#rows > li.row').length > 0`)
  expectOffline = true
  await stopMock()
  await press('#openVideo').catch(() => {})
  check('Bubble quit: Open Video… is disabled or says "Open Bubble to open a video"',
    await waitFor(`document.getElementById('openVideo').disabled || /Open Bubble to open a video/.test(document.body.textContent)`, 8000),
    await text('.notice') || await text('#offline'))
  await dropFiles([join(MEDIA, 'h264.mp4')], 'hover')
  check('Bubble quit: the drop overlay says "Open Bubble to open a video"', /Open Bubble to open a video/.test(await text('.drop-text')), await text('.drop-text'))
  await shot('07-bubble-not-running')
  await cancelDrag()
  await startMock()
  check('Bubble back: Open Video… works again', await waitFor(`!document.getElementById('openVideo').disabled && !/Open Bubble to open a video/.test(document.getElementById('openVideo').textContent)`, 10000))
  expectOffline = false

  check('no JavaScript error in the page', errors.length === 0, errors.slice(0, 3).join(' | '))
} catch (e) {
  check('page-open run finished', false, e.stack || String(e))
}
writeFileSync(join(OUT, 'page-open.txt'), lines.join('\n') + '\n')
console.log(fails ? `${fails} FAILED` : 'ALL PASS')
cleanup()
process.exit(fails ? 1 : 0)
