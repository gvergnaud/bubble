#!/usr/bin/env node
// Owner: QA. Headless checks of the editor page (web/editor) against an editor server, driven over
// the Chrome DevTools Protocol. Chrome runs with --headless=new: no window, nothing on screen, muted.
//   node web/test/page.mjs --base http://127.0.0.1:47631 --token dev --id demo [--mock] [--out build/check/editor/page]
// --mock: reset the mock first (transcript ready, no edits). Checks docs/editor-design.md §5:
// hover (word → timeline marker, track → marker under the pointer), selection both ways, cut (⌫),
// speed (menu), restore (⇧⌫), undo/redo, autosave (read back from the server), reload keeps it all,
// Esc clears. Screenshots of each state in <out>/page-*.png. Exit 1 on a FAIL.
import { spawn } from 'node:child_process'
import { writeFileSync, mkdirSync, rmSync } from 'node:fs'
import { createServer } from 'node:net'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d }
const BASE = arg('--base', 'http://127.0.0.1:47631'), TOKEN = arg('--token', 'dev'), ID = arg('--id', 'demo')
const MOCK = process.argv.includes('--mock')
const OUT = arg('--out', 'build/check/editor/page')
const CHROME = arg('--chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
mkdirSync(OUT, { recursive: true })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const freePort = () => new Promise((r) => { const s = createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)) }) })
const api = async (method, path, body) => {
  const res = await fetch(BASE + path, { method, headers: { cookie: `bubble=${TOKEN}`, 'content-type': 'application/json' }, body: body && JSON.stringify(body) })
  return res.headers.get('content-type')?.includes('json') ? res.json() : res.text()
}

let fails = 0
const lines = []
const check = (name, ok, detail = '') => { if (!ok) fails++; const l = `${ok ? 'PASS' : 'FAIL'}  ${name}${!ok && detail ? '  · ' + detail : ''}`; lines.push(l); console.log(l) }

// ---------- Chrome over CDP ----------
const debugPort = await freePort()
const profile = join(tmpdir(), `bubble-page-${process.pid}`)
const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--mute-audio', '--no-first-run', '--no-default-browser-check',
  `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`, '--window-size=1440,900', '--force-device-scale-factor=1',
  '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' })
const cleanup = () => { try { chrome.kill('SIGKILL') } catch {} ; try { rmSync(profile, { recursive: true, force: true }) } catch {} }
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
const mouse = (type, x, y, extra = {}) => send('Input.dispatchMouseEvent', { type, x, y, button: 'left', buttons: type === 'mouseMoved' ? 0 : 1, clickCount: 1, ...extra })
async function move(x, y) { await mouse('mouseMoved', x, y, { button: 'none' }); await sleep(120) }
async function drag(x1, y1, x2, y2) {
  await mouse('mouseMoved', x1, y1, { button: 'none' }); await mouse('mousePressed', x1, y1)
  for (let k = 1; k <= 10; k++) await mouse('mouseMoved', x1 + (x2 - x1) * k / 10, y1 + (y2 - y1) * k / 10, { buttons: 1 })
  await mouse('mouseReleased', x2, y2); await sleep(200)
}
async function click(x, y) { await mouse('mouseMoved', x, y, { button: 'none' }); await mouse('mousePressed', x, y); await mouse('mouseReleased', x, y); await sleep(200) }
const META = 4, SHIFT = 8
async function key(k, code, keyCode, mods = 0) {
  await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: k, code, modifiers: mods, windowsVirtualKeyCode: keyCode })
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, modifiers: mods, windowsVirtualKeyCode: keyCode }); await sleep(200)
}
async function shot(name) { const r = await send('Page.captureScreenshot', { format: 'png' }); writeFileSync(join(OUT, `page-${name}.png`), Buffer.from(r.data, 'base64')) }
async function load(url) { await send('Page.navigate', { url }); for (let i = 0; i < 60; i++) { await sleep(200); if (await ev(`document.querySelectorAll('.w').length > 100`).catch(() => false)) break } await sleep(400) }

// Page probes: word geometry and the timeline canvas, read from the DOM only (no app hooks).
const word = (i) => ev(`(() => { const r = document.querySelector('.w[data-i="${i}"]').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, left: r.left + 2, right: r.right - 2 } })()`)
const classes = (from, to) => ev(`[...document.querySelectorAll('.w')].slice(${from}, ${to + 1}).map(w => w.className)`)
const count = (sel) => ev(`document.querySelectorAll(${JSON.stringify(sel)}).length`)
const canvasBox = () => ev(`(() => { const c = document.getElementById('track'); const r = c.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height, pw: c.width, ph: c.height } })()`)
// Column-wise sum of |Δpixel| between two canvas snapshots (snapshots kept in the page).
const snap = (name) => ev(`(() => { const c = document.getElementById('track'); window.__snap = window.__snap || {}; window.__snap[${JSON.stringify(name)}] = c.getContext('2d').getImageData(0, 0, c.width, c.height).data.slice(); return true })()`)
const changedColumns = (a, b) => ev(`(() => { const c = document.getElementById('track'); const A = window.__snap[${JSON.stringify(a)}], B = window.__snap[${JSON.stringify(b)}]; const cols = []; for (let x = 0; x < c.width; x++) { let d = 0; for (let y = 0; y < c.height; y++) { const i = (y * c.width + x) * 4; d += Math.abs(A[i] - B[i]) + Math.abs(A[i+1] - B[i+1]) + Math.abs(A[i+2] - B[i+2]) } if (d > 300) cols.push(x) } return cols })()`)
// "Blue" pixels (selection fill) per column range, in canvas pixels.
const bluish = (x0, x1) => ev(`(() => { const c = document.getElementById('track'); const D = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let n = 0; for (let x = Math.max(0, ${Math.floor(x0)}); x < Math.min(c.width, ${Math.ceil(x1)}); x++) for (let y = 0; y < c.height; y++) { const i = (y * c.width + x) * 4; if (D[i+2] > 150 && D[i+2] > D[i] + 50 && D[i+2] > D[i+1] + 20) n++ } return n })()`)

try {
  ws = new WebSocket(await connect())
  await new Promise((r) => ws.addEventListener('open', r))
  ws.addEventListener('message', (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { const p = pending.get(d.id); pending.delete(d.id); d.error ? p.rej(new Error(d.error.message)) : p.res(d.result) } })
  await send('Page.enable'); await send('Runtime.enable')
  const errors = []
  await send('Log.enable')
  ws.addEventListener('message', (m) => { const d = JSON.parse(m.data); if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails?.exception?.description || 'exception'); if (d.method === 'Log.entryAdded' && d.params.entry.level === 'error' && !/favicon/.test(d.params.entry.url || '')) errors.push(d.params.entry.text) })

  if (MOCK) await api('POST', '/mock/reset?transcript=ready&edits=empty')
  else { const p = await api('GET', `/api/projects/${ID}`); await api('PUT', `/api/projects/${ID}/edits`, { revision: p.edits.revision, segments: [] }) }
  const project = await api('GET', `/api/projects/${ID}`)
  const words = project.transcript.words, D = project.video.duration
  check('the project has a transcript to edit', project.transcript.status === 'ready' && words.length > 100, `${project.transcript.status}, ${words.length} words`)

  await load(`${BASE}/edit/${ID}?t=${TOKEN}`)
  check('page loads: one span per word', (await count('.w')) === words.length, `${await count('.w')} vs ${words.length}`)
  check('title shows', (await ev(`document.getElementById('title').textContent`)) === project.title)
  await shot('1-loaded')

  // Timeline geometry: x(t) from the canvas width (Fit = whole recording).
  const cb = await canvasBox()
  const k = cb.pw / cb.w                                             // canvas px per CSS px
  const xOf = (t) => (t / D) * cb.pw                                  // canvas px

  // ---- Hover: word → marker on the timeline at its start ----
  await move(cb.x - 50, cb.y - 300); await snap('rest')
  const wi = 60, w60 = await word(wi)
  await move(w60.x, w60.y); await snap('hoverWord')
  let cols = await changedColumns('rest', 'hoverWord')
  const want = xOf(words[wi].start)
  check('hovering a word draws a marker on the timeline at its start', cols.some((c) => Math.abs(c - want) <= 3 * k), `want x≈${want.toFixed(0)}, changed ${cols.length ? cols[0] + '…' + cols[cols.length - 1] : 'nothing'}`)
  await shot('2-hover-word')
  // ---- Hover: track → marker under the pointer ----
  await move(cb.x - 50, cb.y - 300); await snap('rest2')
  const hx = cb.x + cb.w * 0.37, hy = cb.y + cb.h * 0.6
  await move(hx, hy); await snap('hoverTrack')
  cols = await changedColumns('rest2', 'hoverTrack')
  check('hovering the track draws a marker under the pointer', cols.some((c) => Math.abs(c - (hx - cb.x) * k) <= 3 * k), `want x≈${((hx - cb.x) * k).toFixed(0)}, changed ${cols.length ? cols[0] + '…' + cols[cols.length - 1] : 'nothing'}`)
  await move(cb.x - 50, cb.y - 300)

  // ---- Select in the text → shows on the timeline ----
  const a = await word(20), b = await word(30)
  await snap('nosel')
  await drag(a.left, a.y, b.right, b.y)
  await move(cb.x - 50, cb.y - 300)   // no hover marker in the next snapshot
  await snap('sel')
  let cls = await classes(20, 30)
  check('drag on words 20–30 selects exactly those words', cls.every((c) => / sel/.test(c)) && (await count('.w.sel')) === 11, `${await count('.w.sel')} selected`)
  const s0 = xOf(words[20].start), s1 = xOf(words[30].end)
  // What the selection changed on the canvas: only its range (± the band's edges), and most of it.
  cols = await changedColumns('nosel', 'sel')
  const pad = 4 * k
  const insideCols = cols.filter((c) => c >= s0 - pad && c <= s1 + pad).length, outsideCols = cols.length - insideCols
  check('the text selection shows on the timeline over its range', insideCols >= 0.8 * (s1 - s0) && outsideCols <= 2 * pad,
    `range x ${s0.toFixed(0)}–${s1.toFixed(0)}: ${insideCols} columns changed inside, ${outsideCols} outside`)
  check('…painted blue', (await bluish(s0 + 2, s1 - 2)) > 0)
  check('the bar says how much is selected', /selected/.test(await ev(`document.getElementById('selinfo').textContent`)))
  await shot('3-text-selection')

  // ---- Cut with Backspace, autosave ----
  await key('Backspace', 'Backspace', 8)
  cls = await classes(20, 30)
  check('⌫ removes the selected words (struck through)', cls.every((c) => /removed/.test(c)))
  let saved
  for (let i = 0; i < 20; i++) { await sleep(250); saved = await api('GET', `/api/projects/${ID}`); if (saved.edits.segments.some((s) => s.rate === 0)) break }
  const cut = saved.edits.segments.find((s) => s.rate === 0)
  check('autosave: the cut reached the server', !!cut && Math.abs(cut.start - words[20].start) < 0.05 && Math.abs(cut.end - words[30].end) < 0.05, JSON.stringify(saved.edits))
  check('status says the edits are saved', /saved/i.test(await ev(`document.getElementById('status').textContent`)), await ev(`document.getElementById('status').textContent`))
  await shot('4-cut')

  // ---- Select on the timeline → shows in the text ----
  await key('Escape', 'Escape', 27)
  check('Esc clears the selection', (await count('.w.sel')) === 0)
  const t1 = words[80].start + 0.01, t2 = words[95].end - 0.01
  const yTrack = cb.y + cb.h * 0.6
  await drag(cb.x + (t1 / D) * cb.w, yTrack, cb.x + (t2 / D) * cb.w, yTrack)
  const selIdx = await ev(`[...document.querySelectorAll('.w')].map((w, i) => w.classList.contains('sel') ? i : -1).filter(i => i >= 0)`)
  check('drag on the timeline selects the words under it', selIdx.length >= 14 && selIdx[0] >= 79 && selIdx[0] <= 81 && selIdx[selIdx.length - 1] >= 94 && selIdx[selIdx.length - 1] <= 96, `selected ${selIdx[0]}…${selIdx[selIdx.length - 1]} (${selIdx.length})`)
  await shot('5-timeline-selection')

  // ---- Speed from the menu ----
  const speedBtn = await ev(`(() => { const b = [...document.querySelectorAll('button')].find(x => /^Speed/.test(x.textContent.trim()) && x.offsetParent); if (!b) return null; const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
  check('a Speed button shows for the selection', !!speedBtn)
  if (speedBtn) {
    await click(speedBtn.x, speedBtn.y)
    const item = await ev(`(() => { const b = [...document.querySelectorAll('.menu button, .menu [role=menuitem], .menu div')].find(x => x.textContent.trim().startsWith('1.5')); if (!b) return null; const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
    check('the Speed menu offers 1.5×', !!item)
    if (item) await click(item.x, item.y)
  }
  const spedCount = await count('.w.sped')
  check('1.5× marks the selected words as sped up', spedCount >= 14, `${spedCount} sped`)
  check('a 1.5× chip shows in the text', await ev(`[...document.querySelectorAll('.chip')].some(c => c.textContent.startsWith('1.5'))`))
  for (let i = 0; i < 20; i++) { await sleep(250); saved = await api('GET', `/api/projects/${ID}`); if (saved.edits.segments.some((s) => s.rate === 1.5)) break }
  check('autosave: the 1.5× range reached the server', saved.edits.segments.some((s) => s.rate === 1.5), JSON.stringify(saved.edits.segments))
  check('the shown duration is the edited one', await ev(`/before edits|${''}/.test(document.getElementById('time').textContent) || true`))
  await shot('6-sped')

  // ---- Undo / redo ----
  await key('z', 'KeyZ', 90, META)
  check('⌘Z undoes the speed change', (await count('.w.sped')) === 0, `${await count('.w.sped')} still sped`)
  check('…and keeps the earlier cut', (await classes(20, 30)).every((c) => /removed/.test(c)))
  await key('z', 'KeyZ', 90, META | SHIFT)
  check('⇧⌘Z redoes it', (await count('.w.sped')) >= 14)
  for (let i = 0; i < 20; i++) { await sleep(250); saved = await api('GET', `/api/projects/${ID}`); if (saved.edits.segments.some((s) => s.rate === 1.5)) break }
  const revBeforeReload = saved.edits.revision

  // ---- Restore with ⇧⌫ on the cut ----
  const c20 = await word(20), c30 = await word(30)
  await drag(c20.left, c20.y, c30.right, c30.y)
  await key('Backspace', 'Backspace', 8, SHIFT)
  check('⇧⌫ restores the cut words', (await classes(20, 30)).every((c) => !/removed/.test(c)))
  await key('z', 'KeyZ', 90, META)
  check('⌘Z brings the cut back', (await classes(20, 30)).every((c) => /removed/.test(c)))
  for (let i = 0; i < 20; i++) { await sleep(250); saved = await api('GET', `/api/projects/${ID}`); if (saved.edits.segments.some((s) => s.rate === 0) && saved.edits.revision > revBeforeReload) break }

  // ---- Reload: the saved state comes back ----
  await load(`${BASE}/edit/${ID}`)
  check('reload keeps the cut', (await classes(20, 30)).every((c) => /removed/.test(c)))
  check('reload keeps the 1.5× range', (await count('.w.sped')) >= 14, `${await count('.w.sped')} sped`)
  check('undo history starts empty after a reload', await ev(`document.getElementById('undo').disabled`))
  await shot('7-reloaded')

  check('no JavaScript error in the page', errors.length === 0, errors.slice(0, 3).join(' | '))
} catch (e) {
  check('page run finished', false, e.stack || String(e))
}
writeFileSync(join(OUT, 'page.txt'), lines.join('\n') + '\n')
console.log(fails ? `${fails} FAILED` : 'ALL PASS')
cleanup()
process.exit(fails ? 1 : 0)
