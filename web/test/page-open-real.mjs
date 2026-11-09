#!/usr/bin/env node
// Owner: QA. Headless page checks of "open any video" on Bubble's REAL editor server
// (docs/editor-open-video.md §2-§4), run by Tests/BubbleEditorTests/OpenVideoPageTests.swift: the
// server runs with the fake panel and lookup of OpenVideoContractTests (steered through files in
// --steer), on copies of web/fixtures/open-video/* in --media, plus one project whose drive
// ("BubbleQA-T7") isn't connected. Chrome --headless=new: no window.
//   node web/test/page-open-real.mjs --base http://127.0.0.1:<port> --token <t> --media <dir> --steer <dir> --out <dir>
// Screenshots <out>/real-*.png; exit 1 on a FAIL.
import { writeFileSync, mkdirSync, existsSync, unlinkSync, copyFileSync } from 'node:fs'
import { join } from 'node:path'
import { launch, checker, sleep } from './cdp.mjs'

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d }
const BASE = arg('--base'), TOKEN = arg('--token'), MEDIA = arg('--media'), STEER = arg('--steer')
const OUT = arg('--out', 'build/check/editor/page-open-real')
if (!BASE || !TOKEN || !MEDIA || !STEER) { console.error('needs --base --token --media --steer'); process.exit(2) }
mkdirSync(OUT, { recursive: true })
const { check, done } = checker(OUT, 'page-open-real.txt')
const media = (n) => join(MEDIA, n)
const pick = (what) => writeFileSync(join(STEER, 'pick'), ['cancel', 'hold'].includes(what) ? what : media(what))
const found = (...names) => writeFileSync(join(STEER, 'found'), names.map(media).join('\n'))
const api = async (method, path) => {
  const res = await fetch(BASE + path, { method, headers: { cookie: `bubble=${TOKEN}` } })
  return res.headers.get('content-type')?.includes('json') ? res.json() : res.status
}
const projectOf = async (name) => (await api('GET', '/api/projects')).projects.find((p) => p.file.name === name)

let b
try {
  // The editor asks for media of a missing / offline video and gets the 404s it then shows.
  // Expected 404s Chrome logs: media of a missing / offline video, a drop Bubble can't find.
  b = await launch({ out: OUT, ignoreError: (e) => /\/media\/[\w-]+\/(source|poster\.jpg)|\/waveform|\/api\/open\/dropped/.test(e.url || '') })
  const { ev, shot, text, waitFor, press, dropFiles, navigate, errors } = b
  const go = (p) => navigate(`${BASE}${p}${p.includes('?') ? '&' : '?'}t=${TOKEN}`)
  const path = () => ev('location.pathname')
  const onHome = () => go('/').then(() => waitFor(`document.body.classList.contains('home-page')`))

  // ---- F. Home ----
  await onHome()
  check('home: the recent list shows the projects', (await ev(`document.querySelectorAll('#rows > li.row').length`)) >= 2)
  check('home: the drive that isn\'t connected says so', /on "BubbleQA-T7", not connected/.test(await ev(`[...document.querySelectorAll('#rows .row-meta, #rows .row-warn')].map(x => x.textContent).join('|')`)),
    await ev(`[...document.querySelectorAll('#rows .row')].map(x => x.textContent).join(' | ')`))
  await shot('real-01-home')

  // ---- A. Open Video…: pick, then the same file again, cancel, hold + reload, refusals ----
  pick('h264.mov')
  await press('#openVideo')
  check('Open Video… → picked → its editor', await waitFor(`location.pathname.startsWith('/edit/')`, 8000), await path())
  const movPath = await path()
  check('the editor plays the picked .mov', await waitFor(`document.getElementById('video')?.readyState >= 1`, 8000))
  await shot('real-02-opened-mov')
  await onHome()
  pick('h264.mov')
  await press('#openVideo')
  check('the same file again → the same project', await waitFor(`location.pathname === ${JSON.stringify(movPath)}`, 8000), `${await path()} vs ${movPath}`)
  await onHome()
  pick('cancel')
  await press('#openVideo')
  await sleep(1200)
  check('cancel → the button comes back, the page stays', (await path()) === '/' && !(await ev(`document.getElementById('openVideo').classList.contains('busy')`)))
  pick('hold')
  await press('#openVideo')
  check('held panel → "Choose a video in Bubble…"', await waitFor(`/Choose a video in Bubble/.test(document.getElementById('openVideo').textContent)`))
  await b.send('Page.reload'); await sleep(1500)
  check('reload → still waiting for the panel', await waitFor(`/Choose a video in Bubble/.test(document.getElementById('openVideo').textContent)`))
  await shot('real-03-panel-held')
  pick('h264.m4v')
  check('the held panel answers → its editor', await waitFor(`location.pathname.startsWith('/edit/')`, 8000), await path())
  for (const [file, words] of [['h264.mkv', "can't open .mkv files"], ['vp9.mp4', "can't read this video's format"], ['audio-only.mp4', 'This file has no video.']]) {
    await onHome()
    pick(file)
    await press('#openVideo')
    check(`Open Video… ${file} → "${words}"`, await waitFor(`(document.querySelector('.notice')?.textContent || '').includes(${JSON.stringify(words)})`, 8000), await text('.notice'))
    await shot(`real-04-refused-${file.replace(/\W/g, '-')}`)
  }

  // ---- B. Drop: found by its bytes, not found, a .webm ----
  await onHome()
  found('h264.mp4')
  await dropFiles([media('h264.mp4')])
  check('drop h264.mp4 → Bubble finds it → its editor', await waitFor(`location.pathname.startsWith('/edit/')`, 8000), `${await path()} · ${await text('.notice')}`)
  await onHome()
  found()
  await dropFiles([media('p25.mp4')])
  check('drop a file Bubble can\'t find → the card with Choose it in Bubble…', await waitFor(`/couldn't find p25.mp4/.test(document.querySelector('.notice')?.textContent || '') && /Choose it in Bubble/.test(document.querySelector('.notice').textContent)`, 8000), await text('.notice'))
  await shot('real-05-not-found')
  pick('p25.mp4')
  await press('.notice .btn', 'Choose it in Bubble')
  check('…Choose it in Bubble… → the panel → its editor', await waitFor(`location.pathname.startsWith('/edit/')`, 8000), await path())
  await onHome()
  await dropFiles([media('clip.webm')])
  check('drop a .webm → "can\'t open .webm files", nothing opens', await waitFor(`/can't open .webm files/.test(document.querySelector('.notice')?.textContent || '')`) && (await path()) === '/', await text('.notice'))

  // ---- §4: no sound, the browser can't play ProRes ----
  await onHome()
  pick('no-sound.mp4')
  await press('#openVideo')
  check('no sound: "This video has no sound, so there\'s no transcript.", no ⋯', await waitFor(`/no sound/.test(document.querySelector('.tstate')?.textContent || '') && document.getElementById('tmenu').hidden`, 10000), await text('.tstate'))
  await shot('real-06-no-sound')
  await onHome()
  pick('prores.mov')
  await press('#openVideo')
  check("ProRes: \"Your browser can't play this video's format\", Download stays on",
    await waitFor(`/browser can't play/.test(document.querySelector('.source-state')?.textContent || '') && !document.getElementById('download').disabled`, 14000), await text('.source-state'))
  await shot('real-07-cant-play')

  // ---- Missing → Locate… (another length, then same length other bytes); offline drive ----
  unlinkSync(media('h264.mov'))
  await go(movPath)
  check('deleted video: "The video file is missing." + Locate…', await waitFor(`/The video file is missing/.test(document.querySelector('.source-state')?.textContent || '') && /Locate/.test(document.querySelector('.source-state').textContent)`, 8000), await text('.source-state'))
  check('missing: the transcript and edits are still there', (await ev(`document.querySelectorAll('.w').length`)) >= 0)
  await shot('real-08-missing')
  pick('one-second.mp4')
  await press('.source-state .btn', 'Locate')
  check('Locate… a 1 s file: "a different length…"', await waitFor(`/different length/.test(document.querySelector('.source-state')?.textContent || '')`, 8000), await text('.source-state'))
  copyFileSync(media('h264.mp4'), media('h264 other bytes.mp4'))   // 2 s like the lost .mov, other bytes, H.264 (plays in Chrome)
  pick('h264 other bytes.mp4')
  await press('.source-state .btn', 'Locate')
  check('Locate… same length, other bytes: "check your cuts", the video plays', await waitFor(`/check your cuts/.test(document.querySelector('.notice')?.textContent || '')`, 8000)
    && await waitFor(`document.getElementById('video')?.readyState >= 1`, 8000), await text('.notice'))
  await shot('real-09-linked')
  const offline = (await api('GET', '/api/projects')).projects.find((p) => p.file.state === 'offline')
  await go(`/edit/${offline?.id}`)
  check('offline drive: "This video is on “BubbleQA-T7”, which isn\'t connected."', await waitFor(`/BubbleQA-T7.*isn't connected/.test(document.querySelector('.source-state')?.textContent || '')`, 8000), await text('.source-state'))
  await shot('real-10-offline')

  // ---- Home: Remove from list… keeps the file ----
  await onHome()
  const m4v = await projectOf('h264.m4v')
  const rows0 = await ev(`document.querySelectorAll('#rows > li.row').length`)
  const rowWith = await ev(`[...document.querySelectorAll('#rows > li.row')].findIndex(r => r.textContent.includes(${JSON.stringify(m4v?.title ?? 'h264')}))`)
  await ev(`document.querySelectorAll('#rows > li.row')[${rowWith}].querySelector('button.row-more').click()`)
  await press('.menu button', 'Remove from list')
  await press('.dialog .btn', 'Remove')
  check('Remove from list… → the row goes', await waitFor(`document.querySelectorAll('#rows > li.row').length === ${rows0 - 1}`, 6000))
  check('…the video file stays', existsSync(media('h264.m4v')))

  check('no JavaScript error in the page', errors.length === 0, errors.slice(0, 3).join(' | '))
} catch (e) {
  check('page-open-real run finished', false, e.stack || String(e))
}
b?.close()
done()
