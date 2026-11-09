// Headless Chrome (no window) over CDP: 'open any video' (docs/editor-open-video.md): the home page,
// Open Video…, drop, missing/offline/Locate…, can't play, no sound. Screenshots of each state in <out-dir>.
// Run: node web/mock-server.mjs --port 47699 &  then  node web/editor/test/e2e-open.mjs <out-dir>
// Run: node web/mock-server.mjs &  then  node web/editor/test/e2e.mjs <out-dir>  (screenshots + e2e.txt in out-dir)
import { spawn } from 'node:child_process'
import { writeFileSync } from 'node:fs'
const OUT = process.argv[2]
const CH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const port = 9335
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
  const reset = (q) => fetch(`${BASE}/mock/reset?${q}`, { method: 'POST', headers: H })
  const go = async (path) => { await send('Page.navigate', { url: `${BASE}${path}${path.includes('?') ? '&' : '?'}t=dev` }); await sleep(1600) }
  const text = (sel) => ev(`document.querySelector(${JSON.stringify(sel)})?.textContent?.trim() || ''`)
  const path = () => ev(`location.pathname`)
  const pos = (sel, t) => ev(`(() => { const b = [...document.querySelectorAll(${JSON.stringify(sel)})].find(x => x.textContent.includes(${JSON.stringify(t || '')})); if (!b) return null; const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
  const press = async (sel, t) => { const p = await pos(sel, t); if (!p) throw new Error(`no ${sel} "${t}"`); await click(p.x, p.y) }
  const waitFor = async (expr, ms = 6000) => { for (let i = 0; i < ms / 200; i++) { if (await ev(expr)) return true; await sleep(200) } return false }
  const FIX = new URL('../../fixtures/', import.meta.url).pathname
  const { writeFileSync: wf } = await import('node:fs')
  const mkv = `${OUT}/clip.mkv`; wf(mkv, 'not really a video')
  const drag = async (files, type = 'drop') => {
    const data = { items: [], files, dragOperationsMask: 1 }
    await send('Input.dispatchDragEvent', { type: 'dragEnter', x: 700, y: 400, data })
    await send('Input.dispatchDragEvent', { type: 'dragOver', x: 700, y: 400, data })
    if (type === 'hover') return
    await send('Input.dispatchDragEvent', { type: 'drop', x: 700, y: 400, data })
    await sleep(300)
  }

  // ---- home ----
  await reset('projects=fixture&edits=fixture')
  await go('/')
  const rows = await ev(`document.querySelectorAll('.row').length`)
  check('home: the recent list shows every project', rows >= 4, `${rows} rows`)
  check('home: an offline row says not connected', /not connected/.test(await ev(`[...document.querySelectorAll('.row-meta')].map(x => x.textContent).join('|')`)))
  check('home: a missing row says Missing', /Missing/.test(await ev(`[...document.querySelectorAll('.row-meta')].map(x => x.textContent).join('|')`)))
  await shot('o-01-home')
  await ev(`document.querySelector('.row .row-more').style.opacity = 1`)
  await press('.row .row-more')
  check('home: ⋯ has Show in Finder and Remove from list…', /Show in Finder.*Remove from list/.test(await text('.menu')))
  await shot('o-02-row-menu')
  await press('.menu button', 'Show in Finder')
  await sleep(300)
  check('home: Show in Finder asks Bubble', (await (await fetch(`${BASE}/mock/state`, { headers: H })).json()).revealed.length === 1)
  await ev(`document.querySelectorAll('.row .row-more')[1].style.opacity = 1`)
  const more2 = await ev(`(() => { const r = document.querySelectorAll('.row .row-more')[1].getBoundingClientRect(); return { x: r.left + 10, y: r.top + 10 } })()`)
  await click(more2.x, more2.y)
  await press('.menu button', 'Remove from list')
  check('home: Remove asks first, says the file stays', /The video file stays/.test(await text('.dialog')))
  await shot('o-03-remove-dialog')
  await press('.dialog .btn', 'Remove')
  await sleep(400)
  check('home: Remove deletes the project, the row goes', (await ev(`document.querySelectorAll('.row').length`)) === rows - 1)
  await reset('projects=empty')
  await go('/')
  check('home: empty = only the drop zone, taller', await ev(`document.getElementById('recent').hidden && document.getElementById('dropzone').classList.contains('tall')`))
  await shot('o-04-home-empty')

  // ---- Open Video… ----
  await reset('projects=fixture&panel=hold')
  await go('/')
  await press('#openVideo')
  await sleep(500)
  check('Open Video…: the button says Choose a video in Bubble…', /Choose a video in Bubble/.test(await text('#openVideo')))
  check('Open Video…: the quiet line says the panel is open', /The file panel is open in Bubble/.test(await text('.notice')))
  await shot('o-05-open-waiting')
  await press('#openVideo')
  await sleep(300)
  check('pressing again re-fronts the panel (no second panel)', (await (await fetch(`${BASE}/mock/state`, { headers: H })).json()).fronts >= 1)
  await fetch(`${BASE}/mock/panel?answer=pick`, { method: 'POST', headers: H })
  check('picked: the page goes to its editor', await waitFor(`location.pathname.startsWith('/edit/')`))
  await sleep(1200)
  await shot('o-06-opened-editor')
  check('editor: the Bubble glyph links home (All videos)', await ev(`document.querySelector('a.brand').getAttribute('href') === '/' && document.querySelector('a.brand').title === 'All videos'`))
  await reset('projects=fixture&panel=cancel&panelDelay=200')
  await go('/')
  await press('#openVideo'); await sleep(1200)
  check('canceled: the button comes back, nothing else', (await text('#openVideo')) === 'Open Video…' && (await path()) === '/' && !(await ev(`!!document.querySelector('.notice')`)))
  await reset('projects=fixture&panel=unsupported&pick=Talk.mkv&panelDelay=200')
  await go('/')
  await press('#openVideo'); await sleep(1200)
  const ref = await text('.notice')
  check('refused: the sentence says why and what to do', /can't|Convert/.test(ref), ref.slice(0, 90))
  await shot('o-07-open-refused')

  // ---- drop ----
  await reset('projects=fixture&dropped=found')
  await go('/')
  await drag([`${FIX}demo.mp4`], 'hover')
  check('drag over: overlay "Drop to edit this video"', (await text('.drop-text')) === 'Drop to edit this video', await text('.drop-text'))
  await shot('o-08-drop-overlay')
  await send('Input.dispatchDragEvent', { type: 'drop', x: 700, y: 400, data: { items: [], files: [`${FIX}demo.mp4`], dragOperationsMask: 1 } })
  check('drop found: the page goes to its editor', await waitFor(`location.pathname.startsWith('/edit/')`))
  const st = await (await fetch(`${BASE}/mock/state`, { headers: H })).json()
  const d0 = st.dropped.at(-1) || {}
  check('drop: sends name, size and two sha256, no path', d0.name === 'demo.mp4' && /^[0-9a-f]{64}$/.test(d0.head) && /^[0-9a-f]{64}$/.test(d0.tail) && !JSON.stringify(d0).includes('/'), JSON.stringify(d0).slice(0, 80))
  await reset('projects=fixture&dropped=not_found&droppedDelay=1500')
  await go('/')
  await drag([`${FIX}demo.mp4`])
  check('drop: "Finding demo.mp4 on your Mac…"', /Finding demo.mp4 on your Mac/.test(await text('.notice')))
  await sleep(1000)
  await shot('o-09-finding')
  await sleep(1200)
  check('not found: card with Choose it in Bubble…', /couldn't find demo.mp4/.test(await text('.notice')) && /Choose it in Bubble/.test(await text('.notice')))
  await shot('o-10-not-found')
  await drag([`${FIX}demo.mp4`, `${FIX}demo.mp4`], 'hover')
  check('two files: "Drop one video at a time"', (await text('.drop-text')) === 'Drop one video at a time')
  await send('Input.dispatchDragEvent', { type: 'drop', x: 700, y: 400, data: { items: [], files: [`${FIX}demo.mp4`, `${FIX}demo.mp4`], dragOperationsMask: 1 } })
  await sleep(300)
  await drag([mkv])
  check('a .mkv: refused with the convert sentence', /can't open .mkv files/.test(await text('.notice')), await text('.notice'))
  await shot('o-11-mkv')

  // ---- editor states ----
  await reset('source=missing&locate=different_video')
  await go('/edit/demo')
  check('missing: "The video file is missing." + Locate…', /The video file is missing/.test(await text('.source-state')) && /Locate/.test(await text('.source-state')))
  check('missing: Download is off', await ev(`document.getElementById('download').disabled`))
  await shot('o-12-missing')
  await press('.source-state .btn', 'Locate')
  check('Locate… another length: says why', await waitFor(`/different length/.test(document.querySelector('.source-state .msg')?.textContent || '')`))
  await shot('o-13-locate-different')
  await reset('source=missing&locate=other_bytes')
  await go('/edit/demo')
  await press('.source-state .btn', 'Locate')
  check('Locate… same length, other bytes: relinked + "check your cuts"', await waitFor(`/check your cuts/.test(document.querySelector('.notice')?.textContent || '')`, 8000))
  check('relinked: the video plays again', await waitFor(`!!document.getElementById('video') && document.getElementById('video').readyState > 0`))
  await shot('o-14-linked')
  await reset('source=offline')
  await go('/edit/demo')
  check('offline drive: says which drive to connect', /T7.*isn't connected/.test(await text('.source-state')), await text('.source-state'))
  await shot('o-15-offline-drive')
  await reset('video=unplayable')
  await go('/edit/demo')
  check("browser can't play: says so, Download stays on", await waitFor(`/browser can't play/.test(document.querySelector('.source-state')?.textContent || '')`, 12000) && !(await ev(`document.getElementById('download').disabled`)))
  await shot('o-16-cant-play')
  await reset('sound=none')
  await go('/edit/demo')
  check('no sound: the sentence, no Retry, no ⋯', /no sound/.test(await text('.tstate')) && !(await ev(`[...document.querySelectorAll('.tstate .btn')].some(b => /Retry/.test(b.textContent))`)) && await ev(`document.getElementById('tmenu').hidden`))
  await shot('o-17-no-sound')
  await reset('projects=fixture')
} catch (e) { results.push('ERROR ' + e.message) }
writeFileSync(`${OUT}/e2e-open.txt`, results.join('\n') + '\n')
console.log(results.join('\n'))
ws?.close(); chrome.kill()
process.exit(0)
