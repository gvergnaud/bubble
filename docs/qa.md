# Bubble — manual checks

The automated gate (`scripts/check.sh`) runs on synthetic frames and fake devices: it never
touches your screen, camera or mic. These are the checks only a person on a real Mac can do.
About 50 minutes, plus the 1-hour take (leave it running).

**Before you start**

```
scripts/build-app.sh release --install     # → ~/Applications/Bubble.app, signed
open ~/Applications/Bubble.app
```

The first build may show a keychain prompt "codesign wants to use the key … Developer ID
Application": click **Always Allow** (otherwise `build-app.sh`, and the app-bundle step of
`scripts/check.sh`, wait for it).

Run Bubble from `~/Applications` every time: macOS ties the Screen Recording grant to the app's
place and signature. To start the permission checks from zero:

```
tccutil reset ScreenCapture local.bubble.Bubble
tccutil reset Camera local.bubble.Bubble
tccutil reset Microphone local.bubble.Bubble
defaults delete local.bubble.Bubble        # forgets settings, bubble places, "welcome done"
```

Each check: what to do → what you should see. Tick it, or write what you saw instead.

---

## 1. First launch and permissions (design.md §5.1, §7.1)

- [ ] **1.1 Welcome opens.** Reset as above, open Bubble.
  → The "Welcome to Bubble" window opens by itself, three grey rows (Screen Recording, Camera,
  Microphone). A Bubble icon in the Dock and one in the menu bar. **Done** (once Screen
  Recording works) closes it and opens the Recordings window.
- [ ] **1.2 Camera prompt.** Click Allow on the Camera row.
  → macOS asks "Bubble would like to access the camera" with the text *"Bubble shows your camera
  in the round bubble of your recordings."* Allow → the row turns green, "Allowed".
- [ ] **1.3 Microphone prompt.** Same on the Microphone row.
  → The prompt says *"Bubble records your voice with your screen."* Allow → green.
- [ ] **1.4 Screen Recording.** Click Open Settings on the Screen Recording row.
  → System Settings opens on Privacy & Security › Screen & System Audio Recording, Bubble is in
  the list. Turn it on (macOS may offer "Quit & Reopen": choose **Later**).
  → Back in Bubble, within a few seconds the row turns orange, "Relaunch to finish", and the
  main button is **Relaunch Bubble**.
- [ ] **1.5 Relaunch.** Click Relaunch Bubble.
  → Bubble quits and comes back by itself (menu bar icon reappears). The Welcome window does not
  open again.
- [ ] **1.6 Denied camera.** `tccutil reset Camera local.bubble.Bubble`, relaunch, click the menu
  bar icon, then Allow → **Don't Allow** in the macOS prompt.
  → The panel's Camera row says "Camera blocked · Open Settings". No bubble. Start Recording still
  records (screen + mic, no bubble). Grant it again afterwards.
- [ ] **1.7 Screen missing at start.** Turn Screen Recording off in System Settings, press ⌥⇧L.
  → The Welcome window opens on the Screen Recording row. Nothing records, no file appears.
  Turn it back on and relaunch.

## 2. The main flow (design.md §5.2, §5.6)

- [ ] **2.1 Panel and preview.** Click the menu bar icon.
  → The Recorder panel opens under the icon (Camera, Mic, Computer sound off, Start Recording,
  "or press ⌥⇧L from anywhere"). The bubble appears bottom-left of the display with the mouse,
  24 pt from the edges, size M, **your face mirrored** (raise your right hand: it is on the
  right of the bubble, like a mirror). Before the first camera frame: a dark circle with a small
  spinner, never a black square.
- [ ] **2.2 Esc closes.** Press Esc (or click elsewhere).
  → Panel and bubble disappear. The green camera dot of macOS goes off.
- [ ] **2.3 A 1-minute take.** Open the panel, Start Recording.
  → The panel closes; 3, 2, 1 in the middle of the display, a soft tick on each digit; then the
  menu bar shows a red dot and `00:00` counting up, digits do not jiggle.
  During the take: drag the bubble to the top-right corner and drop it near (not on) the corner;
  hover it and click L, then S, then M; open a few windows, scroll some text, play a video with
  sound (computer sound is off: it must not be in the file), talk.
  → The bubble snaps to the corner (24 pt margin) and resizes in place. The hover buttons and the
  countdown never show in the video (check below).
- [ ] **2.4 Stop.** Press ⌥⇧L.
  → Within about a second: the bubble disappears, a Finder window opens on `~/Movies/Bubble` with
  the new file selected (`Bubble 2026-… at HH.MM.SS.mp4`), and the file opens in QuickTime in
  front. ⌘V in a Finder window or a Slack message pastes the video file.
- [ ] **2.5 The file.** In QuickTime: Window › Show Movie Inspector.
  → H.264, AAC, 30 fps, the display's native size (e.g. 3024×1964 on a 14" MacBook Pro), length
  = the menu bar timer at stop (± 1 s). Text is sharp at 100 %. Your voice is in sync with your
  lips (clap once on camera: sound and image of the clap match). The bubble is round with its
  white ring, moves and resizes where you did it. No panel, countdown, hover buttons, menu bar
  menu or alert in the video. Click rings show where you clicked.
- [ ] **2.5b Constant 30 fps, no gap.** On the file from 2.3:
  `swift run bubble-diag check ~/Movies/Bubble/<file>.mp4`
  → "playable", about 30 frames per second of duration, **max gap ≤ 0.034 s**, no errors, exit
  code 0. (The one engine run on a real screen had a single 67 ms gap; the fix is verified only on
  synthetic frames, so this is the first real check of it.)
- [ ] **2.5c Click highlight look.** Click a few times during the take in 2.3 (note the timer when
  you do). Then grab one frame with a click ring:
  `swift run bubble-diag frame ~/Movies/Bubble/<file>.mp4 --at <seconds> --out ~/Desktop/click.png`
  → A ring shows around the pointer at each click. Send `click.png` to the designer (via main):
  it is the first look at macOS's click ring in a Bubble video, with the bubble in the same frame.
- [ ] **2.6 Last recording.** Right-click the menu bar icon → Show Last Recording in Finder.
  → Finder selects the file from 2.4.
- [ ] **2.7 Fast path from another app.** Click in another app (e.g. Safari), press ⌥⇧L, talk 10 s,
  press ⌥⇧L.
  → No panel: straight to 3-2-1 on the display with the mouse, same bubble place and size as last
  time; the second press stops and the file opens. Two keystrokes, one video.
- [ ] **2.8 Same second.** Press ⌥⇧L, Return to skip the countdown, ⌥⇧L at once; twice within the
  same second if you can (or record twice quickly with countdown off in Settings).
  → Two files; the second one ends in ` (2).mp4` when the seconds match. Nothing is overwritten.

## 3. Pause, resume, discard, camera off (v1 add-ons)

- [ ] **3.1 Pause.** During a take, press ⌥⇧P.
  → The menu bar shows a grey pause glyph and the time stops; the bubble dims to half on screen.
  Wait 10 s, talking.
- [ ] **3.2 Resume.** Press ⌥⇧P again.
  → 3-2-1 with "Resuming" under it, then the timer goes on from where it stopped. Stop.
  → The video jumps from the pause to the resume (a cut): the 10 s you talked while paused are
  not in it, and the bubble is not dimmed in the video.
- [ ] **3.3 Menu while recording.** Click the menu bar item during a take.
  → A short menu: Stop Recording ⌥⇧L, Pause ⌥⇧P (Resume when paused), Hide Camera, Discard… ⌥⇧C.
  Never the Recorder panel.
- [ ] **3.4 Hide / show camera.** Hide Camera from that menu, wait 5 s, Show Camera.
  → The bubble disappears from screen and comes back at the same place and size. In the video it
  is gone for those 5 s. The next recording starts with the camera on again.
- [ ] **3.5 ⦸ in the hover controls.** Hover the bubble, click ⦸.
  → Same as Hide Camera; Show Camera in the menu brings it back.
- [ ] **3.6 Discard with the menu.** Discard… → the alert "Discard this recording? It goes to the
  Trash." [Discard] [Keep Recording]. Keep Recording → recording goes on. Again → Discard.
  → Back to idle, nothing opens, the file is in the Trash (Put Back works).
- [ ] **3.7 Discard with ⌥⇧C twice.** During a take press ⌥⇧C once.
  → A small message "Press ⌥⇧C again to discard" (not in the video). Wait 5 s, press once more:
  the same message again, nothing discarded. Now press twice within 3 s → discarded, to the Trash.

## 4. Displays, devices, system (design.md §7.2, §7.3, §7.5)

- [ ] **4.1 Display menu.** With an external display plugged in, open the panel.
  → A Display row lists both by name; default = the one with the mouse. Picking the other moves
  the bubble preview there. With one display there is no Display row.
- [ ] **4.2 Per-display place.** Put the bubble top-right L on one display, bottom-left S on the
  other. Quit Bubble, reopen, open the panel on each.
  → Each display keeps its own place and size.
- [ ] **4.3 Unplug the recorded display.** Record on the external display, unplug it after 20 s.
  → Recording stops and saves; an alert "Display disconnected, recording saved"; the menu bar
  icon has a yellow ! until you open its menu. The file plays up to the unplug.
- [ ] **4.4 AirPods leave.** Record with AirPods as the mic, put them in their case after 15 s,
  keep talking 15 s.
  → A message "Now using MacBook Pro Microphone"; the recording goes on; the file has your voice
  all along (AirPods, then the built-in mic), no silence longer than a second, no stop.
- [ ] **4.5 Camera unplugged** (external webcam, or close the lid with an external display).
  → The bubble hides, "Camera disconnected", the recording goes on.
- [ ] **4.6 Lock the screen.** During a take press ⌃⌘Q, wait 10 s, unlock.
  → The take is paused (grey pause glyph, dimmed bubble), it does not resume by itself. Resume →
  the locked time is not in the video.
- [ ] **4.7 Quit while recording.** During a take, right-click the icon → Quit Bubble (or ⌘Q with
  Bubble in front).
  → "Stop and save the recording?" [Stop and Save] [Keep Recording]. Keep Recording → goes on.
  Again → Stop and Save: the file is saved and Bubble quits.
- [ ] **4.8 Settings.** Right-click → Settings….
  → Shortcuts ⌥⇧L / ⌥⇧P / ⌥⇧C shown read-only; Save recordings to ~/Movies/Bubble with Change…;
  Countdown, Highlight clicks, Mirror my camera on; Open at login off. Turn Countdown off → the
  next ⌥⇧L starts at once. Mirror off → your raised right hand shows on the left of the bubble.
  Highlight clicks off → no click rings in the next file. Open at login on → Bubble is in System
  Settings › General › Login Items.
- [ ] **4.9 Shortcut taken.** Give ⌥⇧L to another app (e.g. a Shortcuts.app shortcut), relaunch
  Bubble, open Settings.
  → "In use by another app" next to Start / stop recording; the menu bar item still records.
- [ ] **4.10 Computer sound.** Turn Computer sound on in the panel, record 20 s while a video plays
  and you talk (use headphones).
  → Both the video's sound and your voice are in the file, in one track. The switch is still on
  next time. Bubble's countdown tick is not in the file.

## 5. Files you can't lose (design.md §1.5, §7.4)

- [ ] **5.1 kill -9 during a take.** Record 30 s, then in Terminal:
  `kill -9 $(pgrep -f Bubble.app/Contents/MacOS/Bubble)`
  → The file is in `~/Movies/Bubble` under its normal name, plays in QuickTime, and lasts at least
  28 s (at most ~2 s lost). Check it: `swift run bubble-diag check ~/Movies/Bubble/<file>.mp4`
  → "playable", no errors, exit code 0.
- [ ] **5.2 Low disk at start** (optional, needs a nearly full volume: an external drive or a
  small disk image). `hdiutil create -size 1500m -fs APFS -volname Tiny /tmp/tiny.dmg && open /tmp/tiny.dmg`,
  fill it to under 1 GB free (`mkfile 700m /Volumes/Tiny/fill`), set it as the save folder in Settings, press ⌥⇧L.
  → An alert "Not enough space" · "0.x GB free on Tiny. Free some space or pick another folder."
  Nothing starts, no file.
- [ ] **5.3 Disk running out** (same image, ~1.9 GB free with a 2.5 GB image). Record.
  → Under 2 GB: the menu bar timer turns yellow and a message "2 GB left, about N min". Under
  300 MB (fill more with `mkfile` in Terminal while recording): the recording stops and saves,
  alert "Disk almost full, recording stopped and saved", the file plays.
- [ ] **5.4 A 1-hour take.** Record one hour of normal work (leave it running).
  → The timer shows `1:00:00` and on. Activity Monitor: Bubble's memory stays about the same from
  minute 5 to minute 60 (not growing steadily). The file plays to the end, voice in sync at the
  end (clap test again at minute 59), size roughly 1–3 GB.

## 6. Never in the video, never on the network

- [ ] **6.1 Our windows.** In the files from 2.3 and 3.x, step frame by frame through the
  countdown end, a hover over the bubble, the menu bar menu, the Discard alert, a message.
  → Only the bubble is ever in the video. (The menu bar menu is drawn by macOS in the menu bar
  area: if the menu bar is recorded, the menu may show, like any menu.)
- [ ] **6.2 No network.** With Little Snitch or LuLu, or `nettop -p $(pgrep -f Bubble.app/Contents/MacOS/Bubble)`
  during a take.
  → Bubble opens no connection, ever.

## 7. Bubble as a regular app (design.md §10)

- [ ] **7.1 Opening.** Quit Bubble. Open it from Spotlight (`Bubble`), then quit and open it by
  double-clicking `~/Applications/Bubble.app` in Finder.
  → Each time: the Recordings window in front, "Bubble" top-left in the menu bar, the Dock icon.
  Close the window (⌘W): Bubble keeps running (Dock icon and menu bar item stay). Click the Dock
  icon → the window comes back. Same during a take.
- [ ] **7.2 Open at login.** Turn Open at login on in Settings, log out and back in.
  → Bubble runs (Dock icon, menu bar item) but no window opens.
- [ ] **7.3 The list.** With a few recordings in `~/Movies/Bubble`, open Recordings (⌘0).
  → Title "Recordings", subtitle `~/Movies/Bubble · N recordings`. Newest first; each row has a
  thumbnail (grey film tile for a moment, then a frame), the file name, then `Today at 14:22`,
  `Yesterday at …` or a weekday · duration · size. Reopening the window: thumbnails show at once.
- [ ] **7.4 Live folder.** With the window open: record a short take; rename one file in Finder;
  drag one to the Trash in Finder.
  → The new take appears at the top, selected, once saved (not while recording); the renamed
  row shows the new name; the trashed one disappears.
- [ ] **7.5 Actions.** Select a row: double-click → it plays in the default player; Space → Quick
  Look plays it in place; drag the row into a Finder window or a Slack message → the file is
  copied there; right-click → Open, Show in Finder, Copy, Move to Trash all work; ⌘C then ⌘V in
  Finder pastes the file; ⌘⌫ → straight to the Trash, no dialog, and Finder's Put Back restores
  it. ⌘-click / ⇧-click select several; the actions apply to all of them.
- [ ] **7.6 A broken file.** `head -c 100000 <a recording>.mp4 > ~/Movies/Bubble/broken.mp4`
  → A row with the grey tile and "Can't read this file" · size; Show in Finder and Move to Trash
  still work.
- [ ] **7.7 Empty state.** Set the save folder to an empty folder in Settings.
  → The window lists that folder: centered app icon, "No recordings yet", "Press ⌥⇧L anywhere,
  or click New Recording.", the folder path, a New Recording button.
- [ ] **7.8 New Recording from the window.** With another app in front first (e.g. Safari), switch
  to Bubble and click New Recording (toolbar).
  → The Recordings window hides, Safari is in front again, the countdown starts. After Stop:
  player and Finder as in 2.4, and the window back behind them with the new take selected at the
  top. The Recordings window is never in the video.
- [ ] **7.9 Menus.** Look through the Bubble, File, Edit and Window menus at rest and during a take.
  → At rest: File › New Recording ⌥⇧L; Pause and Discard… greyed out; Open, Show in Finder, Copy
  and Move to Trash greyed out when nothing is selected. During a take: Stop Recording ⌥⇧L, Pause
  ⌥⇧P (Resume when paused), Discard… ⌥⇧C enabled. Window › Recordings ⌘0. Right-click the Dock
  icon: New Recording (Stop Recording during a take), Recordings. The menu bar item's idle menu
  has Recordings ⌘0; the Recorder panel's footer says Recordings (opens the window).
- [ ] **7.10 Quit from the Dock while recording.** Right-click the Dock icon → Quit.
  → The "Stop and save the recording?" dialog, as in 4.7.

## 8. The editor (docs/editor-design.md, docs/editor-api.md)

The gate already checks the editor headless: the server's contract, the page's interactions in
Chrome without a window, and the exported file. What it can't do: your browsers, your real
recordings, transcription on this Mac or with Mistral, a long take.

- [ ] **8.1 Open it.** In Recordings, select a take and choose Edit (or the menu bar's Edit Last
  Recording).
  → Your default browser opens `http://127.0.0.1:47621/edit/<id>` (the `?t=…` is gone from the
  address bar). Video on the left, waveform timeline at the bottom, a Transcribe button on the
  right. Bubble shows no window of its own.
- [ ] **8.2 Transcribe on this Mac.** With the engine toggle on "On this Mac", click Transcribe.
  → macOS may ask for Speech Recognition once: allow. Progress shows; words appear; one speaker
  "Speaker 1". Click a few words: the video jumps to each, and what you hear is that word.
- [ ] **8.3 Transcribe with Mistral** (optional, needs your key). Paste the key in the editor's
  settings. → "Voxtral" becomes the default and the page says the audio is sent to Mistral. A bad
  key → "Mistral did not accept this key". Transcribe a take with two people → two speakers.
  Remove the key → back to "On this Mac".
  The key is kept in your login keychain. With the Developer ID signing of `build-app.sh`, macOS
  never asks about it. A build signed ad-hoc (no identity found: `build-app.sh` warns) makes macOS
  ask "Bubble wants to use your confidential information" on the first key read after each
  rebuild: that's the signature changing, not a bug. Always Allow, or rebuild with the Developer ID.
- [ ] **8.4 Hover and select both ways.** Hover a word → a thin marker with its time on the
  timeline. Drag across a sentence → the same range turns blue on the timeline. Drag on the
  timeline → the words under it turn blue.
- [ ] **8.5 Cut, speed, undo.** Select a sentence, press ⌫ → struck through, grey on the timeline,
  the clock says the shorter length. Select a slow stretch, Speed ▾ → 1.5× → a 1.5× chip; play it:
  faster, same voice pitch. ⌘Z / ⇧⌘Z step back and forth. Play from the start: the cut is skipped
  with no visible stall.
- [ ] **8.6 Nothing is lost.** Close the tab, reopen it from Bubble → all edits are there ("Edits
  saved"). Quit Bubble with the tab open → the page says "Open Bubble to keep editing"; reopen
  Bubble → it carries on. The original file in `~/Movies/Bubble` is unchanged (same size and date).
- [ ] **8.7 Download.** Click Download. → Progress, then `<title> (edited).mp4` in Downloads. It
  plays in QuickTime and in Safari/Chrome; its length is the clock's edited length; voice in sync
  with lips at the start, middle and end (clap test); text sharp.
  Check: `swift run bubble-diag check ~/Downloads/"<title> (edited).mp4"` → playable, max gap ≤ 0.034 s.
- [ ] **8.8 A long take.** Open a 30-minute (or longer) recording in the editor.
  → The waveform shows within a few seconds; seeking anywhere is instant; Download of a few cuts
  finishes (a few minutes for an hour of 4K), Bubble's memory stays flat in Activity Monitor.
- [ ] **8.9 Safari too.** Open the same edit URL in Safari (copy it from the address bar).
  → It asks nothing, plays, seeks and edits like Chrome (the cookie was set by Bubble's link).
- [ ] **8.10 Only this Mac.** `lsof -iTCP:47621 -sTCP:LISTEN` → Bubble listens on `127.0.0.1`
  only. Another device on your network can't open the page.

## 9. Open any video (docs/editor-open-video.md)

The gate fakes Bubble's open panel and its Spotlight lookup; these need the real ones. Use a
video of your own outside `~/Movies/Bubble` (a phone clip on the Desktop is ideal).

- [ ] **9.1 Open Video… from the page.** On the editor's home (`/`), click **Open Video…**.
  → Bubble comes forward with its panel (starts in Movies the first time); pick the clip → the
  browser comes back on its editor. Again: the panel starts in that folder. Cancel → the browser
  comes back, nothing changes. Click the button while the panel is up → the same panel comes to the front.
- [ ] **9.2 Drop on the page.** Drag the clip from Finder onto the home page. → "Finding <name> on
  your Mac…", then its editor (the same project as 9.1). From Downloads or Documents the first
  time: macOS may ask "Bubble would like to access files in your Downloads folder"; Allow → it
  opens; Don't Allow → "Bubble couldn't find…" with **Choose it in Bubble…**.
- [ ] **9.3 From Finder and the Dock.** Right-click the clip > Open With > Bubble → its editor in a
  new tab. Drop two clips on Bubble's Dock icon → one tab each. Double-clicking a video still opens
  QuickTime (Bubble is never the default). **File > Open Recent** lists them.
- [ ] **9.4 Never copied, never written.** Before: `ls -l@ <clip>; shasum -a 256 <clip>`. Open
  it, cut, download, remove it from the list. After: same size, date, hash, and no new `@` attribute.
- [ ] **9.5 Moved, renamed, gone.** Rename the clip in Finder, then move it to another folder →
  reopening it from Recent finds it (same edits). Trash it → the editor says "The video file is
  missing." with **Locate…**; locate it in the Trash → linked again.
- [ ] **9.6 A drive.** A clip on a USB drive: open it, eject the drive → home row `on "<drive>",
  not connected`, the editor says to connect it; plug it back → it plays.
- [ ] **9.7 Refusals.** Open a `.mkv` or `.webm` (Open With or the panel) → "Bubble can't open
  .mkv files…" in a Bubble alert (from Finder) or on the page. A ProRes `.mov` in Chrome → "Your
  browser can't play this video's format", Download still works.
  Fake files for all §4 cases: `web/fixtures/open-video/` (2 s each).

## 10. Record a window or an area (design.md §11)

The gate checks the model, the crop math and the files on synthetic frames; these need the real
window picker and a real take.

- [ ] **10.1 A window.** Panel → **Window** → Apple's picker opens; pick a Safari window. → The row
  reads "Safari — <title>" with **Change…**; the bubble preview sits inside the window, bottom-left.
  Start, talk 20 s, Stop. → The file is the window only (no menu bar, no other app), sharp,
  its size the window's in pixels (even numbers, at most 3840 wide). Menu bar menu: "Recording Safari".
- [ ] **10.2 Move, resize, cover.** During a window take: drag the window, resize it, put another
  app's window over it. → The bubble follows the window; the video keeps showing the window
  (letterboxed after a resize), never the window on top.
- [ ] **10.3 Hide, minimize, other display.** ⌘H the app → paused, toast "Paused: Safari is
  hidden…". Show it → "The window is back. Resume with ⌥⇧P."; it stays paused until ⌥⇧P.
  Same with minimize (⌘M) and with dragging the window to another display.
- [ ] **10.4 Close it.** Close the window mid-take → the take stops and saves with the toast "The
  window was closed…" (no alert); the file plays to the end.
- [ ] **10.5 An area.** Panel → **Area** → the overlay dims the display; draw 1280 × 720 (⌘ snaps
  to 16:9), Use This Area. Record 20 s. → Four corner brackets during the take, not in the video;
  the file is exactly that area at native pixels. Under 320 × 240 the button is off ("At least 320 × 240").
- [ ] **10.6 ⌥⇧L remembers.** After 10.1, ⌥⇧L records that window at once; with the window
  closed, it opens the panel on Window with the picker up (never full screen by surprise).
  After 10.5, ⌥⇧L records the saved area on the display with the mouse.
- [ ] **10.7 Too small.** A window 400 × 300 pt → the bubble steps down to S; a 300 × 250 one →
  "This window is too small for your bubble: recording without the camera."

---

When something fails: note the check number, what you saw, and attach the file or a screenshot.
Logs: `log stream --predicate 'subsystem == "local.bubble.Bubble"'` while you reproduce.
