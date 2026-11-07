# Bubble — UX spec

A free, fully local screen recorder for macOS, inspired by Loom's desktop recorder.
Press one shortcut, talk, press it again: you get an `.mp4` of your whole screen with
your face in a round bubble at the bottom-left, saved in `~/Movies/Bubble`.

> **Name.** The app is called **Bubble** (the user's pick, 2026-11-06).

> **Regular app (2026-11-06, after the user's first install).** Bubble has a Dock icon, its
> name in the main menu, a real menu bar and a Recordings window. Spec: §10. It overrides
> "no Dock icon" and "no library window" below.

> **v1 scope (MVP, the user's cut, 2026-11-06).** v1 = menu bar button + ⌥⇧L, Recorder
> panel (camera, mic, Start Recording; no display menu), 3-2-1 countdown, whole display with
> the mouse + mic + fixed bottom-left bubble (M, mirrored), Stop (menu bar button or ⌥⇧L),
> the file is saved and opens in the default player. Plus the permissions, disk, crash and
> device edge cases of section 7. Everything else in this doc (Pause, Restart, Discard,
> toolbar, mic level, bubble drag/sizes, Saved card, display picker) is **later**, unless the
> user says yes to it on the page `loom-like-design` (add-on picks); this note lists the yeses
> when they come.
>
> **Yeses so far:**
> - **Pause / resume** (5.3). Without the v1 toolbar it lives in the menu bar: while recording,
>   the menu bar item's menu has Stop and Pause/Resume (5.7 minus Restart and Discard), plus
>   ⌥⇧P. Paused: the menu bar item shows the grey pause glyph, the bubble gets a dark scrim + pause glyph (table in §4),
>   Resume runs the 3-2-1 again. Screen lock / sleep auto-pauses (7.5).
> - **Discard** (5.5). Also in the menu bar menu ("Discard…"), and ⌥⇧C. Without the toolbar's
>   two-step button, the confirm is: menu item → a small alert "Discard this recording? It goes
>   to the Trash." [Discard] [Keep Recording]; ⌥⇧C pressed twice within 3 s skips the alert
>   (first press: a notification-style hint "Press ⌥⇧C again to discard", not recorded). The
>   take goes to the Trash, nothing opens, back to Idle.
> - **Timer in the menu bar** (6.1): red dot + `MM:SS` (`H:MM:SS` past an hour, monospaced
>   digits) while recording; grey pause glyph + frozen time while paused.
> - **Move the bubble** (6.3): drag anywhere on the recorded display, snap to the nearest
>   corner within 64 pt (24 pt margin), position remembered per display. Draggable in the
>   Ready preview and while recording.
> - **Bubble sizes** (6.3): S 120 / M 180 (default) / L 260 pt, picked from hover controls
>   laid over the bubble in a separate window excluded from the video [arch]; size remembered
>   per display with the position. Hover controls: S / M / L and ⦸ (camera off).
> - **Camera off mid-take** (6.3): ⦸ in the hover controls, or **Hide Camera** in the menu bar
>   menu, hides the bubble (gone from screen and video, the camera stops). With the bubble gone
>   there is nothing to hover, so it comes back with **Show Camera** in the menu bar menu, at
>   the same place and size. Also works in Ready (then the recording starts without camera;
>   the next recording starts with the camera on again).
> - **Copy the file after Stop** + **Show in Finder after Stop** (replace the Saved card in
>   v1). On Stop, once the file is finalized, in this order: (1) the file (as a file URL, like
>   ⌘C in Finder) goes on the clipboard, so ⌘V in Slack, Mail or Finder pastes the video;
>   (2) a Finder window opens on `~/Movies/Bubble` with the file selected; (3) the file opens
>   in the default player, in front. Closing the player leaves you on the selected file, ready
>   to drag. The menu bar's idle menu gets **Show Last Recording in Finder**. Discard does none
>   of this.
> - **Choose the display** (6.2, 7.2): the Display menu in the Recorder panel, shown only with
>   2+ displays; default = the one with the mouse; picking one moves the bubble preview there.
>   The ⌥⇧L fast path still records the display with the mouse.
> - **Click highlights**: on by default, the macOS capture's own click ring
>   (`showMouseClicks`, macOS 15+) [arch]; a "Highlight clicks" checkbox in Settings turns it
>   off. Look not checked yet: no real recording with clicks so far; qa grabs a frame from
>   the user's first real recording (docs/qa.md) and design reviews it then.
> - **Computer sound** (the one medium item [arch]): what the Mac plays, mixed with the mic
>   into the one AAC track. A **Computer sound** switch in the Recorder panel, under Mic;
>   **off by default** (with speakers the mic hears it again: echo), remembered once turned
>   on. Bubble's own sounds (countdown tick) are never recorded. The ⌥⇧L fast path uses the
>   last setting. If capture of computer sound fails mid-take: go on with the mic, toast.
>
> **All 11 add-ons got a yes** (2026-11-06). So v1 also has, from the full spec: Pause/Resume,
> Discard, the menu bar timer, bubble drag + S/M/L + camera off, copy + Finder after Stop, the
> display menu, click highlights, computer sound. Still **later**: Restart, the floating
> toolbar (its actions live in the menu bar menu), the mic level meter, the Saved card.
>
> v1 menu bar menu while recording:
> ```
>  ● 03:12 ▾
> ┌──────────────────────────┐
> │ Stop Recording       ⌥⇧L │
> │ Pause                ⌥⇧P │   (Resume when paused)
> │ Hide Camera              │   (Show Camera when hidden)
> │ Discard…             ⌥⇧C │
> └──────────────────────────┘
> ```
> Idle (right-click or the menu's lower part): Show Last Recording in Finder, Open
> Recordings Folder, Settings…, Quit.
>
> **Decided while building (app-ui, approved by design, round 1):**
> - The bubble's 24 pt margin is from the display's usable area (above the Dock, below the
>   menu bar).
> - Hover controls: S/M/L pill inside the top of the circle, camera-off on the ring at the
>   top-right (smaller on S).
> - Panel: icon + label column, Computer sound switch under the pickers, Start Recording is
>   the one colored (red) control; footer Folder · Settings · Quit icon. Blocked camera/mic:
>   "Blocked · Open Settings" in place of the picker; not asked yet: "Allow Camera…".
> - A take that stops on its own (display unplugged, disk full, permission revoked, writer
>   failure): file on the clipboard + Finder with it selected, **no player**, an alert saying
>   why, and a yellow `!` on the menu bar icon until the menu is opened.
> - Toasts: a small card at the top-right under the menu bar for 4 s, drawn by Bubble, never
>   in the video.
> - Resume countdown caption: "click to resume now · Esc to stay paused".
> - During the 3-2-1, ⌥⇧L cancels (back to Idle); Return or a click skips. Countdown menu:
>   Start Now ↩, Cancel ⎋.

Companion doc: `docs/architecture.md` (how it is built). This doc says what the user sees
and does. Where they meet, the architect agreed on the points marked **[arch]**.

---

## 1. Principles

1. **One way to start.** The menu bar icon, or the global shortcut. Nothing else.
2. **Nothing between you and the recording.** No account, no upload, no network, no time
   limit, no watermark, no sign-in, no paywall. The app never opens a network connection.
3. **What you see is what you get.** The camera bubble on screen is exactly what is in
   the video. Our controls (toolbar, countdown, hover buttons) are never in the video.
4. **A recording is a file.** One `.mp4` per recording, in a folder you own. Finder is the
   library. Delete means "move to Trash".
5. **Never lose a recording.** The file is written to disk while you record; a crash, a
   full disk or an unplugged display leaves a playable file.

---

## 2. How Loom does it (what we kept)

Loom's desktop recorder, as of 2026 (Atlassian support docs, see sources at the end):

| Loom | Bubble |
|---|---|
| Menu bar app; a panel to pick mode (screen + cam, screen only, cam only), screen area (full screen, window, custom), camera and mic, then "Start Recording" | Same panel, cut down to: camera, mic, display (only if 2+), Start Recording. Mode is always screen + cam |
| 3-2-1 countdown, can be skipped | Same, skippable, can be turned off |
| Camera bubble: drag anywhere, snaps to corners and sides, 5 sizes, remembered position; double-click fills the screen | Drag, snap to corners, 3 sizes, remembered per display. No full-screen camera |
| Floating control bar next to the bubble: stop, timer, pause, restart, delete, drawing, hide controls | Toolbar: Stop, timer, Pause, Restart, Discard, camera on/off, mic level. No drawing |
| Controls can be hidden from the final video | Always hidden from the video |
| Shortcuts: start/stop, pause (Option-Shift-P), cancel (Option-Shift-C) | Option-Shift-L / P / C, changeable |
| After stop: upload, the video page opens in the browser, the share link is in the clipboard | After stop: the file is already on disk; a "saved" card like the macOS screenshot thumbnail lets you open it, drag it into Slack or Mail, show it in Finder or delete it |
| Free plan: 5 min per video, 25 videos | No limits |

### What we leave out, and why

| Left out | Why |
|---|---|
| Account, cloud, share links, comments, reactions, view counts | Fully local is the point. You share the file (drag it into Slack, Mail, Drive) |
| Window / custom-region capture | You asked for the whole screen. One mode = no choice to make before each recording |
| Camera-only and screen-only modes | Screen-only = turn the camera off in the toolbar. Camera-only is out of scope |
| System audio (sound from apps) | Mic is what a Loom-style video needs; system audio adds a second track and echo issues. Easy to add later with ScreenCaptureKit |
| Trim, edit, chapters, transcripts, AI titles, filler-word removal | Big features; the file opens in QuickTime, which trims (Edit > Trim). Trim in-app can come later |
| Drawing tool, confetti, click highlight, speaker notes | Nice to have, not needed to record |
| Virtual backgrounds, blur, camera frames | Heavy (segmentation) and not asked |
| Library window | The folder is the library; the menu lists the 5 most recent |
| Hiding the controls / toolbar options | They are never in the video, so there is nothing to choose |
| Quality picker | One good default (sharp text, 30 fps). No setting to get wrong |

---

## 3. The pieces

| Piece | What it is | In the video? |
|---|---|---|
| **Menu bar item** | Always there, the fastest way to start. Bubble is also a regular app with a Dock icon, a main menu and a Recordings window (§10) | no |
| **Recorder panel** | Popover under the menu bar item: camera, mic, display, Start Recording | no |
| **Camera bubble** | Round floating window with your camera, always on top, on every Space | **yes** [arch] |
| **Bubble controls** | Small buttons over the bubble on hover (size, camera off). A separate window, laid over the bubble | no [arch] |
| **Countdown** | Big 3-2-1 in the middle of the recorded display | no |
| **Toolbar** | Small floating pill next to the bubble while recording | no |
| **Saved card** | Thumbnail card at the bottom-right after a recording | no (not recording anymore) |
| **Welcome window** | First launch only: the 3 permissions | n/a |
| **Settings window** | Shortcuts, folder, countdown, mirror, launch at login | n/a |

---

## 4. States

```
            ┌──────────── Discard / Esc ─────────────┐
            ▼                                        │
  ┌──────┐ click icon ┌───────┐ Start Recording ┌───────────┐ 3 s  ┌───────────┐
  │ Idle │──────────▶│ Ready │────────────────▶│ Countdown │─────▶│ Recording │
  └──────┘◀──────────└───────┘  or shortcut    └───────────┘      └───────────┘
     ▲  ▲   Esc /      (bubble   (from Idle,     click = skip      │  ▲   │   │
     │  │   click away  preview)  skips Ready)                  Pause│  │Resume│
     │  │                                                           ▼  │   │   │
     │  │                                                     ┌────────┐ │   │
     │  │                                                     │ Paused │─┘   │
     │  │                                                     └────────┘     │
     │  │  Restart (Recording or Paused): file dropped ──▶ Countdown          │
     │  │  Discard (Recording or Paused): file to Trash ──▶ Idle              │
     │  │                                                     Stop           │
     │  │                                              ┌────────────┐◀───────┘
     │  └──────────── card closes (8 s or ×) ─────────│   Saved    │
     │                                                 └────────────┘
     └── Saving (finalizing file, usually < 1 s; a spinner in the menu bar)
```

| State | Menu bar item | Bubble | Toolbar | File |
|---|---|---|---|---|
| Idle | plain icon | hidden | hidden | none |
| Ready | icon highlighted, panel open | visible (preview) | hidden | none |
| Countdown | icon | visible | hidden | not started |
| Recording | `● 03:12` red dot + elapsed time | visible (recorded) | visible | growing |
| Paused | `❚❚ 03:12` grey | opaque, a black 45% scrim inside the circle + a white pause glyph (28% of the diameter); both go when the resume countdown starts. Paused time is cut from the video | visible, "Paused" | not growing |
| Saving | spinner | hidden | hidden | finalizing |
| Saved | icon | hidden | hidden | done, card shown |
| Error | icon with a yellow `!` | hidden | hidden | whatever was recorded is saved |

There is only one recording at a time. While recording, clicking the menu bar item opens
a short menu (Stop, Pause/Resume, Restart, Discard), never the recorder panel.

---

## 5. Flows

### 5.1 First launch

1. The app opens the **Welcome window** (the only time it shows a regular window
   without being asked).
2. Three rows, each with a status and a button. Each button triggers the macOS prompt or
   opens the right pane of System Settings.
3. Screen Recording needs a relaunch: once granted, the row says "Relaunch to finish" and
   the main button becomes **Relaunch Bubble**. [arch]
4. When all three are green, the button is **Done**. The window shows the shortcut and
   points at the menu bar icon ("Bubble lives here ↑").
5. Camera and Microphone may be skipped ("Not now"): the app still records (see 7.1).
   Screen Recording cannot be skipped: without it there is nothing to record.

```
┌──────────────────────────── Welcome to Bubble ───────────────────────────┐
│                                                                          │
│   Record your screen and your face. Files stay on this Mac.              │
│                                                                          │
│   ● Screen Recording   to see your screen           [ Open Settings ]    │
│   ● Camera             for the bubble                [ Allow ]           │
│   ● Microphone         for your voice                [ Allow ]           │
│                                                                          │
│   Start and stop anytime with  ⌥⇧L                                       │
│                                                       [ Relaunch Bubble ]│
└──────────────────────────────────────────────────────────────────────────┘
  ● grey = not asked · green = allowed · red = denied (button: Open Settings)
```

### 5.2 Record (the main flow)

1. Click the menu bar icon. The **Recorder panel** opens and the **bubble appears** at its
   saved place (default: bottom-left of the display with the mouse) as a live preview.
2. Optional: drag the bubble, change its size, pick another camera, mic or display.
3. Click **Start Recording** (or press Return, or the shortcut).
4. The panel closes. **Countdown** 3, 2, 1 in the middle of the recorded display.
   Click it or press Return to skip; Esc cancels back to Idle.
5. **Recording.** The toolbar appears next to the bubble. The menu bar shows `● 00:00`.
6. Press **Stop** (toolbar, menu bar menu, or the shortcut).
7. **Saved.** The bubble and toolbar disappear, the file is finalized, the **Saved card**
   slides in at the bottom-right.

Fast path: press **⌥⇧L** from anywhere. It skips the panel and goes straight to the
countdown with the last camera, mic, display (the one with the mouse) and bubble place.
Press **⌥⇧L** again to stop. Two keystrokes, one video.

### 5.3 Pause and resume

- **Pause** (toolbar, ⌥⇧P, or menu): recording stops writing; the paused time is not in
  the video (the video jumps cut from the pause to the resume).
- The toolbar shows "Paused" and the Pause button becomes **Resume**. The bubble is
  dimmed on screen as a reminder.
- **Resume** (same button, ⌥⇧P): a short 3-2-1 countdown (if countdown is on), then
  recording goes on in the same file.
- No limit on pause length.

### 5.4 Restart

- **Restart** throws away the current take and starts a new one in the same place.
- Two-step button, no modal dialog: first click turns the button into **Restart?** (red,
  3 s); a second click confirms. Otherwise it goes back.
- The partial file is deleted (not in Trash: it was never "saved"). Then countdown, then
  recording.

### 5.5 Discard

- **Discard** (toolbar, ⌥⇧C, or menu): same two-step confirm as Restart.
- The partial file is moved to the Trash (recoverable), back to Idle. No Saved card.
- ⌥⇧C pressed once shows the toolbar's **Discard?** state; pressed again within 3 s,
  it confirms.

### 5.6 After a recording

The **Saved card** (like the macOS screenshot thumbnail):

```
                                              ┌──────────────────────────────┐
                                              │ ┌──────────┐  Bubble 2026-11-06│
                                              │ │ ▶ thumb  │  at 14.22.05     │
                                              │ │  (frame) │  4:12 · 186 MB   │
                                              │ └──────────┘                  │
                                              │ [Show in Finder] [Copy] [Delete]│ ×
                                              └──────────────────────────────┘
                                                              bottom-right, 24 pt margin
```

- **Click the thumbnail**: opens the file in the default video player (QuickTime).
- **Drag the thumbnail**: drags the file itself, to drop into Slack, Mail, a Finder
  window, a browser upload field.
- **Show in Finder**: opens the folder with the file selected.
- **Copy**: puts the file on the clipboard (paste in Slack, Mail, Finder).
- **Delete**: moves it to the Trash. The card says "Moved to Trash · Undo" for 5 s.
- Rename: in Finder (click the name in the card = rename inline is **not** in v1).
- The card stays 8 s, longer while the mouse is over it; × closes it. It never steals
  focus.
- The menu's **Recent** submenu lists the last 5 recordings; **Open Recordings Folder**
  opens `~/Movies/Bubble`.

### 5.7 While recording: the menu bar menu

```
 ● 03:12  ▾
┌──────────────────────────┐
│ Stop Recording       ⌥⇧L │
│ Pause                ⌥⇧P │
│ Restart                  │
│ Discard…             ⌥⇧C │
└──────────────────────────┘
```

---

## 6. Screens

### 6.1 Menu bar item

- Idle: **two bubbles** (the user's pick, option B): a big filled bubble and a small one at
  its bottom-left, 1.5 pt of air between them, on a 17 × 17 pt canvas. Template image,
  monochrome, follows the menu bar's tint. Drawn in code: `Sources/BubbleUI/MenuBarGlyph.swift`
  (owned by design; `MenuBarGlyph.idle`, `.recording`, `MenuBarGlyphView`).
- Recording: the same glyph with the big bubble in system red (the small one in the menu
  bar's text color) + `MM:SS` (`H:MM:SS` after an hour), monospaced digits so it does
  not jiggle.
- Paused: grey pause glyph + frozen time.
- Click (Idle): Recorder panel. Right-click (Idle): the app menu (Recent, Open
  Recordings Folder, Settings…, Quit).

### 6.2 Recorder panel (popover, 320 pt wide; popup titles leading-aligned, long device names truncate in the middle)

```
            ▲
┌───────────────────────────────┐
│  Camera   [FaceTime HD Camera ▾]│
│  Mic      [MacBook Pro Mic   ▾]│
│           ▮▮▮▮▮▯▯▯▯▯  level    │
│  Display  [Built-in Retina   ▾]│   ← only when 2+ displays
│                               │
│  ┌───────────────────────────┐│
│  │      Start Recording      ││   ← default button, Return
│  └───────────────────────────┘│
│  or press ⌥⇧L from anywhere   │
│ ───────────────────────────── │
│  Recent ▸   Folder   Settings │
└───────────────────────────────┘
```

- Camera menu: every camera + **No Camera** (screen only).
- Mic menu: every input + **No Microphone** (silent video, the toolbar says "No mic").
- The mic level meter moves live, so you know the mic works before you start.
- Display menu: lists displays by name; picking one moves the bubble preview there. Shown
  only with 2+ displays.
- Closing the panel (Esc, click away) hides the bubble preview.

### 6.3 Camera bubble

```
   bubble controls appear on hover (not recorded)
          ┌─ S  M  L ─┐
       .-'''''''''''''-.
     .'                 '.
    /      your face      \        ⦸  camera off (top-right on hover)
   |      (mirrored)       |
    \                     /
     '.                 .'
       '-..._______..-'
   ↖ 24 pt from the left and bottom edges of the recorded display
```

- Circle, sizes **S 120 pt, M 180 pt (default), L 260 pt** diameter.
- Camera image center-cropped to the circle, **mirrored** (like a selfie, the way you
  expect to see yourself; Settings can turn this off).
- Thin white ring (2 pt) and a soft shadow so it reads on any background.
- **Drag** anywhere on the recorded display; on drop it snaps to the nearest corner if
  within 64 pt of it (24 pt margin). Position and size are remembered **per display**.
- Hover shows the **bubble controls** (S / M / L and camera off) over the bubble; they are
  a separate window excluded from the video [arch], so hovering is safe while recording.
- **Camera off** while recording: the bubble disappears from screen and video; the toolbar's
  camera button turns it back on.
- The bubble never leaves the recorded display: dragging it to another display snaps it
  back to the nearest corner of the recorded one.
- Before the camera's first frame arrives, the bubble shows a dark circle with a small
  spinner, never a black square.

### 6.4 Countdown

```
                 ┌─────────┐
                 │    3    │    big digit in a dark translucent rounded square
                 └─────────┘
          click to start now · Esc to cancel
```

- Middle of the recorded display, 160 pt square, 1 s per digit, a soft tick on each digit
  (silent if the Mac is muted). Not recorded.
- Turned off in Settings: recording starts at once.

### 6.5 Toolbar (while recording)

A dark pill, 36 pt tall, docked next to the bubble (to its right, aligned to its bottom;
it follows the bubble when you move it; above the bubble if there is no room). Draggable
by its grip. Not recorded.

```
┌──────────────────────────────────────────────────────┐
│ ⋮  ■ Stop   03:12   ❚❚   ↺   🗑   ◉cam   ▮▮▮▯ mic   │
└──────────────────────────────────────────────────────┘
  grip  red   timer  Pause Restart Discard camera on/off  live mic level
```

- **Stop** is the only colored, labeled button (red square + "Stop").
- Every icon button has a tooltip with its name and shortcut ("Pause ⌥⇧P").
- Paused: the timer turns grey, Pause → Resume (▶), and a "Paused" label appears.
- Restart / Discard turn into **Restart?** / **Discard?** (red) for 3 s on first click.
- Mic level: 4 bars; if the level stays flat for 10 s the bars turn yellow with the
  tooltip "No sound from MacBook Pro Mic" (a muted or wrong mic is the #1 Loom regret).

### 6.6 Settings (one small window, one pane)

```
┌──────────────────────── Bubble Settings ────────────────────────┐
│  Start / stop recording     [ ⌥⇧L ]                              │
│  Pause / resume             [ ⌥⇧P ]                              │
│  Discard                    [ ⌥⇧C ]                              │
│  Save recordings to         ~/Movies/Bubble        [ Change… ]   │
│  [x] Countdown before recording (3 s)                            │
│  [x] Mirror my camera                                            │
│  [ ] Open at login                                               │
└──────────────────────────────────────────────────────────────────┘
```

---

## 7. Edge cases

### 7.1 Permissions

| Case | What happens |
|---|---|
| Screen Recording not granted | Start Recording opens the Welcome window on that row. Nothing records |
| Screen Recording granted, app not relaunched | Welcome row says "Relaunch to finish" with **Relaunch Bubble** |
| Welcome rows (after the user's first real install) | Every row has an action on the right. Screen, never asked: grey dot, "Needed to record. Open Settings and switch on Bubble.", **Open Settings** (prominent, opens Privacy & Security › Screen & System Audio Recording). Screen, after the Settings visit (macOS says "denied" either way): **orange** dot, "Switch on Bubble in Screen & System Audio Recording, then relaunch.", Open Settings, and **Relaunch Bubble** becomes the main button. Camera/mic blocked: red dot, secondary-color text "Optional. Switch on Bubble in Privacy & Security › Camera." (or Microphone), Open Settings |
| Camera denied | Records without the bubble. Panel's camera menu shows "Camera blocked · Open Settings". No nagging on each start |
| Microphone denied | Records silent video. Panel shows "Mic blocked · Open Settings"; the toolbar shows a crossed mic |
| Permission revoked while recording | Screen: stop and save what was recorded, alert. Camera/mic: go on without it, toast |

### 7.2 Displays

| Case | What happens |
|---|---|
| One display | No display menu anywhere |
| 2+ displays, start from the panel | The display menu picks; default = the one with the mouse |
| 2+ displays, start from the shortcut | The display with the mouse |
| Recorded display unplugged while recording | Stop and save, Saved card shows on the remaining display with "Display disconnected, recording saved" |
| Resolution or scaling changes while recording | Recording goes on; the video keeps its starting size (scaled) [arch] |
| Display plugged in while recording | Nothing changes |
| Full-screen apps, Spaces, Mission Control | The bubble and toolbar follow across Spaces and over full-screen apps |

### 7.3 Camera and mic

| Case | What happens |
|---|---|
| No camera at all | Camera menu = "No camera found". Records screen + mic. No bubble |
| Camera unplugged while recording | The bubble hides, recording goes on, toast "Camera disconnected" |
| Camera on but sending no frames (2 s or more) | The bubble stays: dark circle, ring kept, a `video.slash` glyph (30% of the diameter, white 55%), **no text** (the bubble is in the video; viewers shouldn't read an error). The user gets a toast, not recorded: "No video from FaceTime HD Camera". Hide Camera stays in the menu. The first frame brings the picture back |
| Camera busy (another app) | macOS shares the camera; if it fails, same as unplugged |
| Lid closed with an external display | The built-in camera is gone: same as unplugged |
| Mic unplugged (AirPods leave) | Switch to the system default input, toast "Now using MacBook Pro Mic" |
| No mic at all | Silent video, toolbar shows a crossed mic |

### 7.4 Disk and files

| Case | What happens |
|---|---|
| Less than 1 GB free at start | Alert "Not enough space: 0.6 GB free on Macintosh HD. Free some space or pick another folder." Not started |
| 2 GB left while recording | Toolbar timer turns yellow, tooltip "2 GB left, about N min" |
| 300 MB left while recording | Stop and save. Saved card says "Disk almost full, recording stopped and saved" |
| Save folder deleted or on an unplugged drive | Recreate `~/Movies/Bubble` if possible; else alert and fall back to `~/Movies/Bubble` |
| Crash, force quit | The file is written as movie fragments every 2 s: it plays up to the last fragment, at most ~2 s lost [arch]. It keeps its name. On next launch: a Saved card "Recovered a recording from 14:22" |
| Power loss, kernel panic | Usually the same, not guaranteed (disk cache) [arch] |
| Same-second file name | Add ` (2)` |

### 7.5 System

| Case | What happens |
|---|---|
| Screen locks or Mac sleeps while recording | Auto-pause. On unlock: toolbar shows "Paused" (no auto-resume: you choose) |
| Quit (⌘Q / menu) while recording | Dialog: "Stop and save the recording?" [Stop and Save] [Keep Recording] |
| Log out / shut down while recording | Stop and save without asking |
| Shortcut already used by another app | Settings shows "In use by another app" next to it; the menu still works |
| Very long recording (hours) | No limit. The timer shows `H:MM:SS`. File size is the only bound (see disk) |
| Notifications pop up while recording | They are in the video (they are on screen). Out of scope: turning on Focus |
| Recording the recorder | Our panel, toolbar, countdown, card are excluded; only the bubble is recorded |
| macOS indicators | The orange mic dot shows while the Recorder panel is open (the level meter opens the mic) and while recording; macOS adds its own screen-recording indicator and may ask again about screen recording from time to time. That's the OS: we don't hide or fight it |

---

## 8. Defaults

| Setting | Default |
|---|---|
| Start / stop shortcut | ⌥⇧L (Option-Shift-L) |
| Pause / resume | ⌥⇧P |
| Discard | ⌥⇧C (press twice) |
| Capture | Whole display with the mouse, cursor visible |
| Camera | Last used; first time: built-in camera |
| Mic | Last used; first time: system default input |
| Camera bubble | On, round, M (180 pt), bottom-left with a 24 pt margin, mirrored |
| Countdown | On, 3 s (also on resume) |
| Video | `.mp4`, H.264, 30 fps, sharp text (native resolution, capped at 4K) [arch] |
| Audio | Mic only, AAC, mono |
| Folder | `~/Movies/Bubble` |
| File name | `Bubble 2026-11-06 at 14.22.05.mp4` |
| Saved card | 8 s, bottom-right |
| Open at login | Off |
| Dock icon | Yes, a regular app (§10); the menu bar item stays |
| Time limit | None |
| Network | None, ever |

---

## 10. Bubble as a regular app

The menu bar item stays the fastest way in. On top of it, Bubble behaves like any Mac app:
you open it from the Dock, Spotlight or Finder, you see its name top-left, you can quit it,
and you can find every past recording.

### 10.1 Launch and windows

| How Bubble opens | What shows |
|---|---|
| First launch ever | The Welcome window; **Done** closes it and opens Recordings |
| Dock, Spotlight, Finder, `open -a Bubble` | The Recordings window, in front |
| Click on the Dock icon while running (reopen) | The Recordings window, in front (also while recording) |
| Open at login | Nothing: Dock icon and menu bar item only |

- Closing the last window does **not** quit: the Dock icon and the menu bar item stay.
  Quit is ⌘Q (Bubble menu, Dock menu, the panel's power button).
- All Bubble windows stay out of the video, as before (only the bubble is recorded).
- **Starting a recording from Bubble** (New Recording in the window or the menu): the
  Recordings window hides and the app that was in front before Bubble gets the focus back,
  so you record your work, not Bubble. After Stop, the window comes back behind the player
  and Finder, with the new recording selected at the top. The Stop flow itself is unchanged.

### 10.2 Main menu

```
 Bubble                      File                              Edit
 About Bubble                New Recording            ⌥⇧L      Copy                 ⌘C
 ──────────                  Pause                    ⌥⇧P      Select All           ⌘A
 Settings…            ⌘,     Discard…                 ⌥⇧C
 ──────────                  ──────────
 Hide Bubble          ⌘H     Open                     ⌘O       Window
 Hide Others         ⌥⌘H     Show in Finder          ⇧⌘R       Minimize             ⌘M
 Show All                    Move to Trash            ⌘⌫       Zoom
 ──────────                  ──────────                         ──────────
 Quit Bubble          ⌘Q     Open Recordings Folder            Recordings           ⌘0
                             Close Window             ⌘W       Bring All to Front
```

- While recording, **New Recording** reads **Stop Recording** (same shortcut), and
  Pause / Discard turn on; at rest they are greyed out. Pause reads **Resume** when paused.
- Open, Show in Finder, Copy, Move to Trash act on the selected recordings and are greyed
  out when nothing is selected or the window is not in front.
- Quit while recording: the existing "Stop and save the recording?" dialog (§7.5).
- No View or Help menu content of our own (macOS adds Help's search field).
- **Dock menu** (right-click the icon): New Recording / Stop Recording, Recordings.
- **Menu bar item**: unchanged, plus **Recordings** (⌘0) in its idle menu. The Recorder
  panel's footer button **Folder** becomes **Recordings** (opens the window).

### 10.3 Recordings window

```
┌───────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   Recordings                                       [● New Recording] │
│         ~/Movies/Bubble · 12 recordings                                    │
├───────────────────────────────────────────────────────────────────────────┤
│ ┌────────┐  Bubble 2026-11-06 at 14.22.05                                 │
│ │ thumb  │  Today at 14:22 · 4:12 · 186 MB                                │
│ └────────┘                                                                │
│ ┌────────┐  Demo for Camille                ← renamed in Finder: shown as is│
│ │ thumb  │  Yesterday at 09:10 · 12:48 · 610 MB                           │
│ └────────┘                                                                │
│ ┌────────┐  Bubble 2026-11-02 at 17.03.44                                 │
│ │ thumb  │  Sunday at 17:03 · 0:52 · 31 MB                                │
│ └────────┘                                                                │
└───────────────────────────────────────────────────────────────────────────┘
```

- **Window:** title "Recordings", subtitle `<folder> · N recordings`. Default 720 × 520 pt,
  minimum 480 × 360, frame remembered. Toolbar: **New Recording** (red dot + label, same as
  ⌥⇧L), at the trailing edge. Nothing else in the toolbar.
- **Content:** one list, newest first (file creation date). Every `.mp4` and `.mov` at the
  top level of the save folder; the file being recorded right now is not listed until it is
  saved. The list follows the folder live: a new recording appears at the top; a file renamed,
  moved or trashed in Finder updates or disappears.
- **Row** (72 pt tall, 16 pt side margins, thin separators inset like the Welcome rows):
  - thumbnail 96 × 54 pt, 6 pt corners: a frame at 1 s; while it loads, a grey tile with a
    film glyph; cached, so reopening is instant;
  - title: the file name without its extension (a rename in Finder shows here), one line,
    truncated in the middle;
  - subtitle (secondary color): `Today at 14:22` / `Yesterday at 09:10` / weekday within the
    last 7 days / `6 Nov 2026` · duration `M:SS` or `H:MM:SS` · size (`186 MB`);
  - a file Bubble can't read: the grey tile, subtitle "Can't read this file" · size. It can
    still be shown in Finder or trashed.
- **Actions** (on the selection; ⌘-click and ⇧-click select several):
  - double-click, Return or ⌘O: open in the default player;
  - Space: Quick Look preview (plays in place);
  - drag a row out: drags the file (Slack, Mail, Finder);
  - right-click: **Open**, **Show in Finder**, **Copy**, **Move to Trash**;
  - ⌘C copies the files (like Finder); ⌘⌫ moves them to the Trash at once, no dialog
    (Finder's Put Back undoes it).
- **Empty state** (no recordings, or the folder doesn't exist yet), centered:

```
                         ( ◉ )         app icon, 64 pt
                   No recordings yet
     Press ⌥⇧L anywhere, or click New Recording.
       Your videos are saved in ~/Movies/Bubble.
                   [ New Recording ]
```

- **Folder changed in Settings:** the window lists the new folder (old files stay where they
  are, not listed).
- **Edit (the editor, `docs/editor-design.md`):** opens the recording in the browser editor.
  Where: first item of the row's context menu; File > **Edit** ⌘E (one selected row, greyed
  otherwise); a small secondary **Edit** button (pencil + "Edit") at the trailing edge of a
  row, shown on hover and on the selected row, tooltip "Edit in your browser  ⌘E"; the menu
  bar's idle menu gets **Edit Last Recording**. Double-click stays Open (player). After Stop:
  unchanged, no Settings choice. Opening: nothing under 1 s; past 1 s a toast "Opening the
  editor…"; on failure an alert "Bubble couldn't open the editor." with the reason.
- **As built (approved):** New Recording sits in the window's own header (title and
  subtitle on the left, red button on the right) under a transparent title bar, not in an
  NSToolbar; thumbnails and durations are cached in memory per session; dragging drags the
  one row dragged. Empty list: no header button (the centered one is enough) and the
  subtitle is just the folder; "1 recording" in the singular.

---

## 9. Words (UI copy)

English, sentence case, short. Buttons: **Start Recording**, **Stop**, **Pause**,
**Resume**, **Restart**, **Discard**, **Show in Finder**, **Copy**, **Delete**,
**Open Settings**, **Relaunch Bubble**, **Done**. Confirm states: **Restart?**,
**Discard?**. Tooltips: name + shortcut.

## Sources

- Loom keyboard shortcuts: https://support.atlassian.com/loom/docs/use-looms-keyboard-shortcuts/
- Loom capture modes, camera bubble (drag, snap, 5 sizes, double-click): https://support.atlassian.com/loom/docs/use-looms-different-capture-modes/
- Pause and resume (⌥⇧P): https://support.atlassian.com/loom/docs/pause-and-resume-while-recording/
- Restart a recording: https://support.atlassian.com/loom/docs/restart-a-recording
- Hide the recording controls: https://support.atlassian.com/loom/docs/hide-the-recording-controls/
- 3-second countdown, controls next to the bubble: https://madeonsundays.com/loompresentations/
