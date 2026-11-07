// Headless Chrome (no window) over CDP: the Transcribe panel (engine toggle, Mistral key) on the mock server.
// Run: node web/mock-server.mjs &  then  node web/editor/test/e2e.mjs <out-dir>  (screenshots + e2e.txt in out-dir)
import { spawn } from 'node:child_process'
import { writeFileSync } from 'node:fs'
const OUT = process.argv[2]
const CH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const port = 9334
// a private mock port: 47621-47630 may be the real Bubble's editor server
const BASE = process.env.BASE || 'http://127.0.0.1:47699'
const chrome = spawn(CH, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--mute-audio', `--remote-debugging-port=${port}`,
  `--user-data-dir=${OUT}/profile`, '--window-size=1440,900', '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let ws, id = 0
const pending = new Map()
async function connect() {
  for (let i = 0; i < 50; i++) {
    try { const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); const pg = list.find((t) => t.type === 'page'); if (pg) return pg.webSocketDebuggerUrl } catch {}
    await sleep(200)
  }
  throw new Error('no chrome')
}
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })) })
const ev = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails)); return r.result.value }
const mouse = (type, x, y, extra = {}) => send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1, ...extra })
async function drag(x1, y1, x2, y2) { await mouse('mouseMoved', x1, y1, { button: 'none' }); await mouse('mousePressed', x1, y1); for (let k = 1; k <= 8; k++) await mouse('mouseMoved', x1 + (x2 - x1) * k / 8, y1 + (y2 - y1) * k / 8); await mouse('mouseReleased', x2, y2); await sleep(150) }
async function click(x, y) { await mouse('mouseMoved', x, y, { button: 'none' }); await mouse('mousePressed', x, y); await mouse('mouseReleased', x, y); await sleep(150) }
async function key(k, code, mods = 0, keyCode) { await send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code, modifiers: mods, windowsVirtualKeyCode: keyCode }); await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, modifiers: mods, windowsVirtualKeyCode: keyCode }); await sleep(150) }
async function shot(name) { const r = await send('Page.captureScreenshot', { format: 'png' }); writeFileSync(`${OUT}/${name}.png`, Buffer.from(r.data, 'base64')) }
const wordRect = (i) => ev(`(() => { const r = document.querySelector('.w[data-i="${i}"]').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
const results = []
const check = (name, ok, detail = '') => { results.push(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  · ' + detail : ''}`) }

try {
  ws = new WebSocket(await connect())
  await new Promise((r) => ws.addEventListener('open', r))
  ws.addEventListener('message', (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { const p = pending.get(d.id); pending.delete(d.id); d.error ? p.rej(new Error(d.error.message)) : p.res(d.result) } })
  await send('Page.enable'); await send('Runtime.enable')
  const H = { cookie: 'bubble=dev' }
  const api = (path, method = 'GET') => fetch(BASE + path, { method, headers: H })
  const open = async () => { await send('Page.navigate', { url: BASE + '/edit/demo?t=dev' }); await sleep(1500) }
  const pos = (sel, text) => ev(`(() => { const b = [...document.querySelectorAll('${sel}')].find(x => x.textContent.includes(${JSON.stringify(text)})); if (!b) return null; const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
  const press = async (sel, text) => { const p = await pos(sel, text); if (!p) throw new Error(`no ${sel} "${text}"`); await click(p.x, p.y) }
  const waitWords = async () => { let n = 0; for (let i = 0; i < 40 && !n; i++) { await sleep(400); n = await ev(`document.querySelectorAll('.w').length`) } return n }
  const noTranscribeButton = () => ev(`![...document.querySelectorAll('button')].some(b => b.textContent.trim() === 'Transcribe')`)

  // 1. opening a recording with no transcript: the server starts it; progress, then words
  await api('/api/settings/mistral-key', 'DELETE')
  await api('/mock/reset?transcript=none&edits=empty', 'POST')
  await open()
  const h3 = await ev(`document.querySelector('.tstate h3')?.textContent || ''`)
  check('open: a progress state shows (no button to press)', /transcrib/i.test(h3), h3)
  check('open: no Transcribe button anywhere', await noTranscribeButton())
  check('open: it says where the audio goes', /Nothing leaves your Mac|sent to Mistral/.test(await ev(`document.querySelector('.tstate .sub')?.textContent || ''`)))
  await shot('t-1-progress')
  check('open: the words arrive by themselves', (await waitWords()) > 100)
  check('the panel head names the engine', (await ev(`document.getElementById('engineName').textContent`)) === 'On this Mac')

  // 2. a failed transcript: inline error + Retry
  await api('/mock/reset?transcript=failed&edits=empty', 'POST')
  await open()
  check('failed: the error shows inline', /didn't work/.test(await ev(`document.querySelector('.tstate h3')?.textContent || ''`)))
  await shot('t-2-failed')
  await press('.tstate .btn', 'Retry')
  check('Retry: the words arrive', (await waitWords()) > 100)

  // 3. Re-transcribe with… from the ⋯ menu, and the key popover
  const t = await ev(`(() => { const r = document.getElementById('tmenu').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
  await click(t.x, t.y)
  check('⋯ menu lists Re-transcribe with each engine', (await ev(`[...document.querySelectorAll('.menu button')].map(b => b.textContent).join('|')`)).match(/Re-transcribe with/g)?.length === 2)
  await shot('t-3-menu')
  await press('.menu button', 'Re-transcribe with Voxtral')
  check('Voxtral without a key opens the key popover', await ev(`!!document.querySelector('.menu.pop .keyform input')`))
  const typeKey = async (k) => { await ev(`(() => { const i = document.querySelector('.keyform input'); i.value = ${JSON.stringify(k)}; return 1 })()`); await press('.keyform button', 'Save'); await sleep(600) }
  await typeKey('bad')
  check('a bad key says so', (await ev(`document.querySelector('.keymsg').textContent`)) === "This key didn't work.")
  await shot('t-4-bad-key')
  await typeKey('sk-good')
  check('a good key starts the Voxtral transcript', /transcrib/i.test(await ev(`document.querySelector('.tstate h3')?.textContent || ''`)))
  check('Voxtral words arrive', (await waitWords()) > 100)
  const proj = await (await api('/api/projects/demo')).json()
  check('it used Voxtral', proj.transcript.engine === 'voxtral-mini-transcribe-3', proj.transcript.engine)
  await click(t.x, t.y)
  await press('.menu button', 'Mistral API key')
  await sleep(400)
  check('the key popover shows the saved key with Remove', /Keychain/.test(await ev(`document.querySelector('.menu.pop')?.textContent || ''`)))
  await shot('t-5-key-saved')
  await api('/api/settings/mistral-key', 'DELETE')
} catch (e) { results.push('ERROR ' + e.message) }
writeFileSync(`${OUT}/e2e-transcribe.txt`, results.join('\n') + '\n')
console.log(results.join('\n'))
ws?.close(); chrome.kill()
process.exit(0)
