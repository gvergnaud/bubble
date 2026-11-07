// Headless Chrome (no window) driven over CDP: checks the editor interactions on the mock server.
// Run: node web/mock-server.mjs &  then  node web/editor/test/e2e.mjs <out-dir>  (screenshots + e2e.txt in out-dir)
import { spawn } from 'node:child_process'
import { writeFileSync } from 'node:fs'
const OUT = process.argv[2]
const CH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const port = 9333
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
  await fetch(BASE + '/mock/reset?transcript=ready&edits=empty', { method: 'POST', headers: { cookie: 'bubble=dev' } })
  await send('Page.navigate', { url: BASE + '/edit/demo?t=dev' })
  await sleep(2500)
  check('page loads with words', (await ev(`document.querySelectorAll('.w').length`)) > 100)

  // 1. drag across words selects them, and the timeline shows it
  const a = await wordRect(20), b = await wordRect(30)
  await drag(a.x, a.y, b.x, b.y)
  const nsel = await ev(`document.querySelectorAll('.w.sel').length`)
  check('drag on words selects 11 words', nsel === 11, `got ${nsel}`)
  check('selection shows in the timeline bar', /selected/.test(await ev(`document.getElementById('selinfo').textContent`)))
  check('floating bar shows', await ev(`!!document.querySelector('.float')`))
  await shot('e2e-1-text-selection')

  // 2. Delete key removes them; saved to the server
  await key('Backspace', 'Backspace', 0, 8)
  const nrem = await ev(`[...document.querySelectorAll('.w')].slice(20, 31).every(w => w.classList.contains('removed'))`)
  check('Backspace strikes the 11 words', nrem)
  await sleep(1200)
  const proj = await (await fetch(BASE + '/api/projects/demo', { headers: { cookie: 'bubble=dev' } })).json()
  check('autosave reached the server', proj.edits.segments.some((s) => s.rate === 0), JSON.stringify(proj.edits))
  check('status says Edits saved', /Edits saved/.test(await ev(`document.getElementById('status').textContent`)))
  await shot('e2e-2-deleted')

  // 3. undo / redo
  await key('z', 'KeyZ', 4, 90)
  check('Cmd-Z restores the words', await ev(`![...document.querySelectorAll('.w')].slice(20, 31).some(w => w.classList.contains('removed'))`))
  await key('z', 'KeyZ', 4 | 8, 90)
  check('Shift-Cmd-Z removes them again', await ev(`[...document.querySelectorAll('.w')].slice(20, 31).every(w => w.classList.contains('removed'))`))

  // 4. drag on the timeline selects words
  await key('Escape', 'Escape', 0, 27)
  const c = await ev(`(() => { const r = document.getElementById('track').getBoundingClientRect(); return { l: r.left, w: r.width, y: r.top + r.height * 0.7 } })()`)
  const dur = 68.638
  await drag(c.l + c.w * 30 / dur, c.y, c.l + c.w * 36 / dur, c.y)
  const tsel = await ev(`[...document.querySelectorAll('.w.sel')].map(w => w.textContent).join(' ')`)
  check('drag on the timeline selects the words under it', tsel.split(' ').length >= 8, tsel.slice(0, 80))
  await shot('e2e-3-timeline-selection')

  // 5. Speed 1.5x from the floating bar menu
  const sp = await ev(`(() => { const b = [...document.querySelectorAll('.float .btn')].find(x => x.textContent.startsWith('Speed')); const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
  await click(sp.x, sp.y)
  const it = await ev(`(() => { const b = [...document.querySelectorAll('.menu button')].find(x => x.textContent.startsWith('1.5×')); const r = b.getBoundingClientRect(); return { x: r.left + 20, y: r.top + r.height / 2 } })()`)
  await click(it.x, it.y)
  check('Speed 1.5× marks the words sped', (await ev(`document.querySelectorAll('.w.sped').length`)) >= 8)
  check('a 1.5× chip appears in the text', await ev(`[...document.querySelectorAll('.chip')].some(c => c.textContent === '1.5×')`))
  check('clock shows the shorter duration', /before edits/.test(await ev(`document.getElementById('time').textContent`)))
  await shot('e2e-4-sped')

  // 6. Restore on the same selection
  await key('Backspace', 'Backspace', 8, 8)
  check('Shift-Backspace restores normal speed', (await ev(`document.querySelectorAll('.w.sped').length`)) === 0)

  // 7. click a word seeks there
  const w50 = await wordRect(50)
  await click(w50.x, w50.y)
  const t50 = await ev(`document.getElementById('video').currentTime`)
  const s50 = await ev(`fetch('/api/projects/demo').then(r => r.json()).then(p => p.transcript.words[50].start)`)
  check('click on a word seeks to it', Math.abs(t50 - s50) < 0.05, `${t50} vs ${s50}`)

  // 8. playback skips removed parts: seek just before the cut of words 20-30 and play
  const cut = await ev(`fetch('/api/projects/demo').then(r => r.json()).then(p => p.edits.segments.find(s => s.rate === 0))`)
  await ev(`(() => { const v = document.getElementById('video'); v.currentTime = ${cut.start - 0.6}; return v.play().then(() => 1) })()`)
  await sleep(1500)
  const tPlay = await ev(`document.getElementById('video').currentTime`)
  check('playback jumps over the cut', tPlay > cut.end, `t=${tPlay.toFixed(2)} cut ${cut.start.toFixed(2)}-${cut.end.toFixed(2)}`)
  check('the jump is ducked (audio fade out, then in)', Number(await ev(`document.getElementById('video').dataset.ducks || 0`)) >= 1)
  await ev(`document.getElementById('video').pause()`)
  await shot('e2e-5-after-play')

  // 9. reload keeps the edits
  await send('Page.reload'); await sleep(2500)
  check('reload keeps the cut', await ev(`[...document.querySelectorAll('.w')].slice(20, 31).every(w => w.classList.contains('removed'))`))

  // 10. Download: export job runs, then the browser gets the file
  await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: OUT + '/dl', eventsEnabled: true })
  const dl = await ev(`(() => { const r = document.getElementById('download').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
  await click(dl.x, dl.y)
  let saw = ''
  for (let i = 0; i < 40; i++) { const t = await ev(`document.getElementById('download').textContent.trim()`); if (/Exporting/.test(t)) saw = t; if (saw && t === 'Download') break; await sleep(250) }
  check('Download shows export progress then comes back', !!saw, saw)
  await sleep(1000)
  const { readdirSync } = await import('node:fs')
  let files = []; try { files = readdirSync(OUT + '/dl') } catch {}
  check('the edited file is downloaded', files.some((f) => f.endsWith('.mp4')), files.join(', '))
} catch (e) { results.push('ERROR ' + e.message) }
writeFileSync(`${OUT}/e2e.txt`, results.join('\n') + '\n')
console.log(results.join('\n'))
ws?.close(); chrome.kill()
process.exit(0)
