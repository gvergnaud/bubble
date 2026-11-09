// Owner: QA. Headless Chrome over the DevTools Protocol for the page checks: --headless=new (no
// window, nothing on screen), muted, its own temp profile, killed on exit.
import { spawn } from 'node:child_process'
import { writeFileSync, rmSync } from 'node:fs'
import { createServer } from 'node:net'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
export const freePort = () => new Promise((r) => { const s = createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)) }) })
export const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

/** Starts Chrome, connects to its page. Returns the helpers; `errors` collects page errors. */
export async function launch({ out, chrome = CHROME, ignoreError = () => false }) {
  const debugPort = await freePort()
  const profile = join(tmpdir(), `bubble-cdp-${process.pid}-${debugPort}`)
  const proc = spawn(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--mute-audio', '--no-first-run', '--no-default-browser-check',
    `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`, '--window-size=1440,900', '--force-device-scale-factor=1',
    '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' })
  const close = () => { try { proc.kill('SIGKILL') } catch {} ; try { rmSync(profile, { recursive: true, force: true }) } catch {} }
  process.on('exit', close)

  let url
  for (let i = 0; i < 100 && !url; i++) {
    try { url = (await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json()).find((t) => t.type === 'page')?.webSocketDebuggerUrl } catch {}
    if (!url) await sleep(100)
  }
  if (!url) throw new Error('Chrome did not start')
  const ws = new WebSocket(url)
  await new Promise((r) => ws.addEventListener('open', r))
  let seq = 0
  const pending = new Map()
  const errors = []
  ws.addEventListener('message', (m) => {
    const d = JSON.parse(m.data)
    if (d.id && pending.has(d.id)) { const p = pending.get(d.id); pending.delete(d.id); d.error ? p.rej(new Error(d.error.message)) : p.res(d.result) }
    if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails?.exception?.description || 'exception')
    if (d.method === 'Log.entryAdded' && d.params.entry.level === 'error' && !/favicon/.test(d.params.entry.url || '')
        && !ignoreError(d.params.entry)) errors.push(`${d.params.entry.text} ${d.params.entry.url || ''}`)
  })
  const send = (method, params = {}) => new Promise((res, rej) => { const i = ++seq; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })) })
  await send('Page.enable'); await send('Runtime.enable'); await send('Log.enable')

  const ev = async (expr) => { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || JSON.stringify(r.exceptionDetails)); return r.result.value }
  const mouse = (type, x, y) => send('Input.dispatchMouseEvent', { type, x, y, button: type === 'mouseMoved' ? 'none' : 'left', buttons: type === 'mouseMoved' ? 0 : 1, clickCount: 1 })
  const click = async (x, y) => { await mouse('mouseMoved', x, y); await mouse('mousePressed', x, y); await mouse('mouseReleased', x, y); await sleep(200) }
  const shot = async (name) => { const r = await send('Page.captureScreenshot', { format: 'png' }); writeFileSync(join(out, `${name}.png`), Buffer.from(r.data, 'base64')) }
  const text = (sel) => ev(`document.querySelector(${JSON.stringify(sel)})?.textContent?.trim() || ''`)
  const waitFor = async (expr, ms = 6000) => { for (let i = 0; i < ms / 100; i++) { if (await ev(expr).catch(() => false)) return true; await sleep(100) } return false }
  /** Clicks the first `sel` whose text includes `words`. */
  const press = async (sel, words = '') => {
    const p = await ev(`(() => { const b = [...document.querySelectorAll(${JSON.stringify(sel)})].find(x => x.textContent.includes(${JSON.stringify(words)})); if (!b) return null; b.scrollIntoView({ block: 'center' }); const r = b.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()`)
    if (!p) throw new Error(`nothing to press: ${sel} "${words}"`)
    await click(p.x, p.y)
  }
  /** Drags real files over the page (the page gets real File objects), then drops unless 'hover'. */
  const dropFiles = async (files, how = 'drop') => {
    const data = { items: [], files, dragOperationsMask: 1 }
    await send('Input.dispatchDragEvent', { type: 'dragEnter', x: 700, y: 450, data })
    await send('Input.dispatchDragEvent', { type: 'dragOver', x: 700, y: 450, data })
    await sleep(150)
    if (how === 'hover') return
    await send('Input.dispatchDragEvent', { type: 'drop', x: 700, y: 450, data })
    await sleep(300)
  }
  const navigate = async (u) => { await send('Page.navigate', { url: u }); await sleep(1500) }
  return { send, ev, click, shot, text, waitFor, press, dropFiles, navigate, errors, close }
}

/** PASS/FAIL lines; `done()` writes them and exits 1 on a FAIL. */
export function checker(out, file) {
  let fails = 0
  const lines = []
  const check = (name, ok, detail = '') => { if (!ok) fails++; const l = `${ok ? 'PASS' : 'FAIL'}  ${name}${!ok && detail ? '  · ' + detail : ''}`; lines.push(l); console.log(l); return ok }
  const done = () => {
    const last = fails ? `${fails} FAILED` : 'ALL PASS'
    writeFileSync(join(out, file), lines.join('\n') + '\n' + last + '\n'); console.log(last); process.exit(fails ? 1 : 0)
  }
  return { check, done }
}
