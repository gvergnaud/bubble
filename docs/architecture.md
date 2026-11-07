# Bubble — architecture

How Bubble is built. What the user sees and does is in `docs/design.md` (the designer's spec);
this doc says how to build it, who builds what, and how we check it.

Status: written 2026-11-06 by the architect. Shared contracts:
`Sources/BubbleCore/Contracts/Contracts.swift` and `Sources/BubbleCore/Capture/EngineAPI.swift`
(stubs that compile; `swift build` and `scripts/test.sh` pass on the skeleton).

---

## 1. Decisions in one screen

| Topic | Decision | Why |
|---|---|---|
| Stack | Native Swift 6 (language mode 6), AppKit windows + SwiftUI views, ScreenCaptureKit, AVFoundation | The only way to get hardware encoding, the system screen capture and a menu bar app with no runtime. Electron/Tauri would still need native code for all of it |
| Min macOS | 15.0 (the user is on 26.7) | SCK microphone capture (`captureMicrophone`) and click highlights (`showMouseClicks`) are macOS 15+ |
| Build | SwiftPM only (`swift build`, `scripts/*.sh`). No Xcode project | This Mac has the Command Line Tools but **no Xcode** (`xcodebuild` is not available). An `.app` bundle is assembled by a script |
| Screen | ScreenCaptureKit `SCStream`, one display, native pixels, long side capped at 3840 px, 30 fps, BGRA, cursor on | Sharp text; H.264 levels stop around 4K; BGRA is required by `showMouseClicks` |
| Camera bubble in the video | The bubble is a **real window** on screen; the screen capture records it. No compositing code | What you see is what you get, drag/resize for free, zero sync work. **Verified** (spike) |
| Our own UI out of the video | `SCContentFilter(display:, excludingApplications: [Bubble], exceptingWindows: [bubble window])` | Excludes every Bubble window (panel, countdown, hover controls, alerts) except the bubble. **Verified** (spike) |
| Mic | ScreenCaptureKit's own mic capture (`captureMicrophone`, `microphoneCaptureDeviceID`) | Same stream, same host clock as the video. **Verified** (spike: 48 kHz mono float, timestamps on the host clock) |
| Computer sound | SCK `capturesAudio = true`, `excludesCurrentProcessAudio = true`, mixed with the mic in our `AudioMixer` into one AAC track | One track plays everywhere. Off by default (design) |
| File | `.mp4`, H.264 High (auto level) + AAC-LC 48 kHz mono 128 kb/s | Plays everywhere (QuickTime, Slack, browsers, Windows) |
| Crash safety | `AVAssetWriter.movieFragmentInterval = 2 s`, file written in place under its final name | A crash leaves a playable file up to the last fragment. **Verified** (spike: killed at 9 s → 8.0 s playable, mp4 and mov, H.264 and HEVC, AVFoundation + ffmpeg) |
| Constant frame rate | `FramePump`: a 30 Hz tick appends the latest screen frame | Fixes the writer bug (§6). **Verified on synthetic frames** |
| Memory, length | Samples go straight from SCK to the encoder to disk; nothing accumulates | No duration limit; memory stays flat (to measure in the soak test) |
| Hotkeys | Carbon `RegisterEventHotKey` | Global, no Accessibility permission needed |
| Signing | Codesign with a **stable identity** (this Mac has a "Developer ID Application" identity); ad-hoc fallback | macOS ties the Screen Recording grant to the code signature: ad-hoc signing changes every build and loses the grant |
| Bundle id | `local.bubble.Bubble` | Stable forever (permissions are keyed on it) |
| Network | None. No dependency fetched at build time either (no SwiftPM packages) | Fully local |

---

## 2. v1 scope (from docs/design.md)

design.md's "v1 scope" note is the source of truth. Mapped to engineering:

| design.md | v1? | Track |
|---|---|---|
| 1 Principles | yes | all |
| 3 Pieces: menu bar item, Recorder panel, camera bubble, bubble hover controls, countdown, welcome window, settings window | yes | UI |
| 3 Pieces: floating toolbar, Saved card | **later** (toolbar actions live in the menu bar menu; after Stop: clipboard + Finder + player) | — |
| 4 States: Idle, Ready, Countdown, Recording, Paused, Saving, Error | yes (no Saved state: the file just opens) | UI + capture |
| 5.1 First launch (3 permissions, relaunch) | yes | UI (+ `PermissionsProviding` from capture) |
| 5.2 Record, ⌥⇧L fast path | yes | all |
| 5.3 Pause / resume (menu + ⌥⇧P, resume countdown) | yes | capture (Timeline) + UI |
| 5.4 Restart | **later** | — |
| 5.5 Discard (menu + alert, ⌥⇧C twice) → Trash | yes | capture (`discard()`) + UI |
| 5.6 After a recording: clipboard (file URL) → Finder with file selected → open in default player; "Show Last Recording in Finder" | yes | UI |
| 5.6 Saved card, Recent submenu | **later** | — |
| 5.7 Menu bar menu while recording (Stop, Pause/Resume, Hide/Show Camera, Discard…) | yes | UI |
| 6.1 Menu bar item with timer | yes | UI |
| 6.2 Recorder panel: camera, mic, computer sound switch, display menu (2+ displays) | yes; mic level meter **later** | UI |
| 6.3 Bubble: circle, mirrored, ring + shadow, drag + snap, S/M/L, per-display memory, camera off, spinner before first frame | yes | UI (+ `CameraFeed` from capture) |
| 6.4 Countdown | yes | UI |
| 6.5 Toolbar | **later** | — |
| 6.6 Settings: shortcuts (fixed defaults in v1, shown read-only), folder, countdown, mirror, highlight clicks, open at login | yes, but **shortcut editing later** (v1 shows them) | UI |
| 7.1 Permissions edge cases | yes | UI + capture |
| 7.2 Displays (unplug → stop and save) | yes | capture |
| 7.3 Camera/mic unplugged | yes (mic switch: see §5.4 risk) | capture + UI |
| 7.4 Disk (1 GB / 2 GB / 300 MB), crash, same-second name | yes; "Recovered a recording" card **later** (the file is already in the folder and plays) | capture |
| 7.5 System: auto-pause on lock/sleep, quit dialog, logout → save | yes | capture (events) + UI (dialog) |
| 8 Defaults, 9 Words | yes | UI |

---

## 3. Recording pipeline

```
 SCStream (one display, filter = all of Bubble except the bubble window)
   ├─ .screen      BGRA CVPixelBuffer, host-clock PTS, only when the screen changes
   │                └─▶ FramePump.submit(latest)          ┌─ 30 Hz DispatchSourceTimer (writer queue)
   │                                                      └─▶ FramePump.tick(now) ─▶ Timeline.fileTime ─▶ RecordingWriter.appendVideo
   ├─ .microphone  LPCM (device format), host-clock PTS ─▶ AudioMixer.push(.microphone)
   └─ .audio       LPCM (computer sound, optional)      ─▶ AudioMixer.push(.computer)
                                                         AudioMixer.pull(upTo: now) ─▶ Timeline.fileTime ─▶ RecordingWriter.appendAudio
 RecordingWriter = AVAssetWriter(.mp4, H.264 + AAC, movieFragmentInterval 2 s) ─▶ ~/Movies/Bubble/Bubble <date>.mp4 (streamed)
```

- **One serial queue** (`writerQueue`) receives SCK's sample handlers and the pump's timer, and owns
  the pump, mixer, timeline and writer. No locks; the classes are `@unchecked Sendable` with that
  confinement documented at the top of each file. `LiveRecorder` (main actor) talks to it with
  `writerQueue.async` and publishes `state`/`elapsed`/events back on the main actor.
- **Clock**: everything is in host time (`CMClockGetHostTimeClock`). SCK's video, mic and audio
  buffers all carry host-time PTS (spike: first video and mic PTS 1–40 ms apart, mic delivered
  ~12 ms after capture). File time = `Timeline.fileTime(host)`: host time minus the start time minus
  the paused spans. The writer's session starts at file time 0.
- **SCStreamConfiguration**: `width/height` from `VideoSettings.forDisplay` (pointPixelScale of the
  filter × contentRect, cap 3840, even), `minimumFrameInterval = 1/30`, `queueDepth = 6`,
  `pixelFormat = BGRA`, `colorSpaceName = sRGB`, `showsCursor = true`,
  `showMouseClicks = <setting>`, `captureMicrophone = mic != nil`,
  `microphoneCaptureDeviceID = mic`, `capturesAudio = computerSound`,
  `excludesCurrentProcessAudio = true`, `sampleRate = 48000`, `channelCount = 1`.
- **Frames**: keep only `SCFrameStatus.complete` (attachment `SCStreamFrameInfo.status`); the other
  statuses are idle/blank notifications.
- **Writer settings**: `AVVideoCodecType.h264`, `AVVideoProfileLevelH264HighAutoLevel`,
  `AVVideoAverageBitRateKey` = `clamp(width × height × 30 × 0.04, 4 Mb/s, 16 Mb/s)` (≈ 7 Mb/s at
  3024×1964, ≤ 3.2 GB/h worst case; a static screen costs far less), `MaxKeyFrameIntervalDuration = 2`,
  `ExpectedSourceFrameRate = 30`, color properties BT.709 (`AVVideoColorPropertiesKey`) so colors do
  not shift; `expectsMediaDataInRealTime = true`. Audio: `kAudioFormatMPEG4AAC`, 48 kHz, 1 ch, 128 kb/s.
  `movieFragmentInterval = 2 s`, `shouldOptimizeForNetworkUse = false`.
  Create the `AVAssetWriterInputPixelBufferAdaptor` **before** `startWriting()` (it throws otherwise).
- **Start**: preflight (permission, display found, `DiskPolicy` ≥ 1 GB), find the bubble's
  `SCWindow` by `windowID` in `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`
  (the bubble must be on screen: it is, from Ready on), build the filter, start capture
  (~170 ms in the spike), start the pump on the first complete frame. `start()` returns once the
  first frame is written.
- **Stop**: stop the timer, stop capture, `appendVideo(last frame, at: stop time)`, flush the mixer,
  `endSession(atSourceTime: stop)`, `finishWriting`. Without the last append, a static screen at the
  end shortens the video (spike: an 8 s take came out at 6.25 s).
- **Pause**: `Timeline.pause(now)`; the pump and mixer keep running but `fileTime` returns nil, so
  nothing is written. `resume(now)` adds the span to the offset. The video jumps cut; no gap in the file.
- **Discard**: stop, then `NSWorkspace.shared.recycle([url])`.
- **Writer failure** (`status == .failed`): never force-unwrap `pixelBufferPool` or keep appending
  (the spikes crashed with SIGTRAP doing that). Stop capture, keep the file (playable to the last
  fragment), emit `.stoppedOnItsOwn(reason: .failed(msg))`.

### 3.1 Camera bubble

- `CameraFeed` (capture track) owns an `AVCaptureSession` with the chosen camera, preset 1280×720
  (enough for a 260 pt bubble at 2x). `AVCaptureDevice.wasDisconnectedNotification` →
  `onDisconnected`.
- The bubble window (UI track): borderless `NSPanel`, `.nonactivatingPanel`, `level = .floating`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, clear background,
  a layer-backed view with `AVCaptureVideoPreviewLayer(session:)`, `videoGravity = .resizeAspectFill`,
  circular mask, 2 pt white ring, shadow. Mirroring: `connection.automaticallyAdjustsVideoMirroring = false`,
  `isVideoMirrored = setting`.
- Hover controls (S/M/L, ⦸) are a **second** panel above the bubble: excluded like every other Bubble
  window.
- **Camera off during a take (or hidden in Ready, then Start)**: the bubble panel stays ordered in,
  with `alphaValue = 0` and `ignoresMouseEvents = true`, and the camera session stops. A transparent
  window is invisible in the video too. Show Camera = `alphaValue = 1` and restart the session.
  Never `orderOut` or recreate the bubble panel during a take: the filter is built from the on-screen
  window list at start and references its window ID. So `RecordingOptions.bubbleWindowID` is set
  whenever a camera exists, even when hidden at start. `orderOut` only when no take is running.
  Resizing the same panel is fine.

### 3.2 Audio mixer

- Input: CMSampleBuffers from SCK (mic: device format, e.g. 48 kHz mono Float32 interleaved in the
  spike; computer: 48 kHz). Each source: `AVAudioConverter` → 48 kHz mono Float32 → a ring buffer
  indexed by sample time (`host seconds × 48000`).
- `pull(upToHost: now − maxWait)`: emits contiguous 1024-frame chunks: sum of the sources present
  (clamped to [-1, 1]), silence where a source has nothing. So mic dropouts, a device switch and
  computer-sound silence never create holes or stalls in the audio track.
- Mic only = the same code with one source (one path to test).

### 3.3 System events (capture track, `SystemEvents.swift`)

| Event | Source | Action |
|---|---|---|
| Screen lock / sleep | `com.apple.screenIsLocked` (DistributedNotificationCenter), `NSWorkspace.willSleepNotification`, `screensDidSleepNotification` | `pause()` + event (no auto-resume) |
| Recorded display gone | `SCStreamDelegate.stream(_:didStopWithError:)`, `NSApplication.didChangeScreenParametersNotification` | finish, `.stoppedOnItsOwn(.displayDisconnected)` |
| Screen permission revoked | `didStopWithError` (user-stopped / permission error codes) | finish, `.screenPermissionRevoked` |
| Mic unplugged | `AVCaptureDevice.wasDisconnectedNotification` for the mic | `stream.updateConfiguration` with the new default `microphoneCaptureDeviceID`, `.microphoneSwitched(name)` |
| Disk | `URLResourceValues.volumeAvailableCapacityForImportantUsage` every 5 s | `DiskPolicy`: warn < 2 GB, stop < 300 MB |
| Logout / shutdown | `NSWorkspace.willPowerOffNotification` | stop and save (`.appQuitting`) |

---

## 4. Permissions, signing, running an unsigned local build

- `Resources/Info.plist`: `CFBundleIdentifier = local.bubble.Bubble`, `CFBundleName = Bubble`,
  `LSUIElement = true` (menu bar only, no Dock icon), `LSMinimumSystemVersion = 15.0`,
  `NSCameraUsageDescription` ("Bubble shows your camera in the round bubble of your recordings."),
  `NSMicrophoneUsageDescription` ("Bubble records your voice with your screen."). Screen recording has
  no plist key.
- Screen recording: `CGPreflightScreenCaptureAccess()` (never prompts) for status;
  `CGRequestScreenCaptureAccess()` once (registers the app in System Settings › Privacy & Security ›
  Screen & System Audio Recording); then open
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. After the user
  turns it on, macOS needs a relaunch. The running process cannot reliably tell "granted, not yet
  applied" from "not granted" (preflight may stay false until relaunch; guessing from window names
  gave a relaunch loop on macOS 26), so once the request was made the screen row keeps
  **Open Settings** and the Welcome window's main button becomes **Relaunch Bubble**. `needsRelaunch` → relaunch via
  `NSWorkspace.openApplication(at: Bundle.main.bundleURL, configuration: createsNewApplicationInstance)` then terminate.
  Computer sound is covered by the same permission.
- Camera / mic: `AVCaptureDevice.authorizationStatus(for:)` and `requestAccess(for:)`. SCK's mic
  capture uses the app's microphone permission.
- **Signing**: `scripts/build-app.sh` signs with `$BUBBLE_SIGN_IDENTITY`, else the first
  "Developer ID Application" or "Apple Development" identity in the keychain, else ad-hoc (`-`) with
  a warning. No hardened runtime, no sandbox, no entitlements needed for a local build. With ad-hoc
  signing the Screen Recording grant breaks at each rebuild; reset with
  `tccutil reset ScreenCapture local.bubble.Bubble` and grant again.
- **Gatekeeper**: a locally built app has no quarantine flag, so it opens without "unidentified
  developer". A copy received from elsewhere: `xattr -dr com.apple.quarantine Bubble.app`.
- Run it from one stable place: `build/Bubble.app` while developing, `~/Applications/Bubble.app`
  for daily use (`scripts/build-app.sh release --install`).
- macOS shows its own screen-recording indicator in the menu bar during a take, and may re-ask
  periodically whether Bubble may keep recording the screen. That is the OS.

---

## 5. Project layout and ownership

```
Package.swift                         architect
Resources/Info.plist, AppIcon.icns    QA (Info.plist content: §4)
scripts/build-app.sh                  QA   swift build + assemble build/Bubble.app + codesign
scripts/run.sh                        QA   build-app + quit the running Bubble + open build/Bubble.app
scripts/test.sh                       QA   swift test (CLT flags already handled; written by the architect)
scripts/check.sh                      QA   build + test + snapshots + synthetic crash test → build/check/
docs/architecture.md                  architect
docs/design.md                        designer
docs/qa.md                            QA   manual checklist (the runs that need a person)

Sources/BubbleCore/Contracts/Contracts.swift   architect   shared types and protocols (Recorder, CameraFeed, ...)
Sources/BubbleCore/Capture/                    capture
  EngineAPI.swift          public stubs → split into the files below as they get real
  VideoSettings.swift  Timeline.swift  RecordingWriter.swift  FramePump.swift  AudioMixer.swift
  ScreenCapture.swift      SCStream, filter, configuration, SCStreamOutput/Delegate
  LiveRecorder.swift       Recorder implementation: glues the above on writerQueue
  LiveCameraFeed.swift  LiveDeviceCatalog.swift  LivePermissions.swift
  SystemEvents.swift  RecordingFiles.swift  DiskPolicy.swift
Sources/BubbleUI/                              app/UI
  AppModel.swift           @MainActor @Observable state machine (design.md §4), takes a Recorder,
                           CameraFeed, DeviceCatalog, PermissionsProviding: all injectable
  AppDelegate.swift  StatusItemController.swift  MenuBuilder.swift (menus as data → NSMenu)
  RecorderPanelView.swift (SwiftUI, popover)
  BubbleWindow.swift  BubbleView.swift  BubbleHoverControls.swift  BubblePlacement.swift (snap, per-display memory: pure)
  CountdownWindow.swift  CountdownView.swift
  WelcomeWindow.swift  WelcomeView.swift  SettingsView.swift  DiscardAlert.swift
  Hotkeys.swift            Carbon RegisterEventHotKey
  AfterStop.swift          clipboard (file URL) → Finder select → open in default player
  Settings.swift           UserDefaults-backed values
Sources/Bubble/main.swift                      app/UI   wires Live* into AppModel, runs NSApplication
Sources/BubbleTesting/                         QA   FakeRecorder (exists), FakeCameraFeed, FakeDeviceCatalog,
                                                    FakePermissions, SyntheticFrames (BGRA buffers with text), SyntheticAudio (sine)
Sources/bubble-diag/main.swift                 QA   synthetic / check / record commands
Tests/BubbleCoreTests/                         QA (capture engineer adds unit tests next to their code too)
Tests/BubbleUITests/                           QA   AppModel tests + snapshot catalog
```

A file has one owner. To change a file you do not own, `sb send <owner>`. Contracts change only
through the architect.

**View rule for snapshots (UI track):** every SwiftUI view takes plain values (a state struct, a
list of devices, a placeholder image for the camera) and has no singleton, timer or device access
inside. Windows host views; views never reach for `NSApp`. So QA can render every state offscreen
with `ImageRenderer` (verified in `swift test` on this Mac). AppKit-only pieces (the status item, NSMenu)
are tested as data (`MenuBuilder` returns titles/shortcuts/enabled flags), not as pictures.

---

## 6. The writer bug (open; inherited by the capture track)

**Symptom.** With a real SCK stream and the mic, `AVAssetWriter` failed in about half the runs with
`AVFoundationErrorDomain -11800`, underlying `OSStatus -16341`, always at a fragment boundary
(+2.1, +4.1, +6.1, +8.2 s). The file stays playable up to the last good fragment.

**What I measured.**
- Fragments + video only: no failure (3/3). Mic + no fragments: no failure (3/3). Fragments + mic
  (SCK or AVCaptureSession): fails often.
- No backpressure involved: `isReadyForMoreMediaData` was never false (0 drops), no audio
  timestamp discontinuity.
- **Reproduced without any capture** (`spikes/writer-crash`, `GAPS=1`): synthetic CFR video + audio,
  then no video frame for 2.5 s while audio continues (what SCK does on a static screen) → the same
  -16341 failure, every run.
- **Fix tested on synthetic frames**: re-append the last frame at every 1/30 s tick (`PUMP=0.0333`)
  → 2/2 clean, 9.00 s, 270 frames. Re-appending only every 0.5 s or 1 s still fails. So the rule
  is: **constant frame rate, no video gap**, which is what `FramePump` does.

**Update (capture track, after building `RecordingWriter`).** The spike still fails with `GAPS=1`,
but the real `RecordingWriter` does **not** fail on the same 2.5 s video gap without the pump
(640×400 and 3024×1964, real-time paced, audio in 1024 or 1600 frames). So the synthetic repro is
tied to something in the spike (its adaptor pool attributes, most likely), and the
`staticScreenWithAudio` test passes either way: it does not guard the bug. The real SCK stream did
fail without the pump, through a different append path. The pump stays (cheap, and it also makes the
file end at Stop and keeps offline tests from stalling: with `realTime: false` and a video gap,
AVAssetWriter's interleaving holds the audio input until video catches up). The real run (§8.3) is
the check that counts.

**Real run (2026-11-06, §8.3, approved by the user): 12/13 pass.** No -16341 with a real SCK
stream + mic + fragments + the pump; 3024×1964, 10.04 s video and mic audio; bubble in, other
windows out; a start with the bubble at alpha 0 found and recorded. The one fail (29.90 fps, one
67 ms gap at the start: first frame at its capture time, ticks at "now") led to the frame grid:
video slots at exact file times n/30, each tick fills every slot due (catch-up, capped at 1 s).
Not re-run on a real stream; `docs/qa.md` checks 30.00 fps and max gap ≤ 0.034 s with
`bubble-diag check` on the user's first real recording.

**Was open before the real run.** The fix with a real SCK stream (needs one real capture, see §8.3), and why a
gap shorter than the fragment interval also fails at 0.5 s repeats (likely: the fragment writer
wants video samples in every fragment chunk; not worth more digging since CFR works).
Repeated frames cost almost nothing in H.264 (skip blocks).

**Regression test (QA):** `WriterTests.staticScreenWithAudio`: synthetic video with a 2.5 s
static span through `FramePump` + continuous sine audio, fragments on, 10 s, `realTime: false`
→ writer status `.completed`, duration 10 s ± 0.1, 300 frames.

---

## 7. Build and run (no Xcode needed)

```
swift build                         # compiles everything (debug)
scripts/test.sh                     # unit + snapshot tests (Swift Testing; CLT paths handled)
scripts/build-app.sh [debug|release] [--install]   # → build/Bubble.app, signed
scripts/run.sh                      # build, quit the running Bubble, open the new one
scripts/check.sh                    # the gate: build + test + snapshots + crash test → build/check/
log stream --predicate 'subsystem == "local.bubble.Bubble"'   # logs (os.Logger, one category per file)
```

`build-app.sh` lays out `Bubble.app/Contents/{MacOS/Bubble, Info.plist, Resources/AppIcon.icns}`
from `.build/<config>/Bubble`, then `codesign --force --sign "$IDENTITY" --identifier local.bubble.Bubble`.
The icon is made with `iconutil` from a PNG set (no asset catalogs: they need Xcode's actool).

---

## 8. Test plan

### 8.1 Automated (`scripts/check.sh`, no permission, no real capture, no camera)

All on synthetic data: generated `CVPixelBuffer`s (with text, to judge sharpness) and sine audio.
Nothing in the gate touches the screen, the camera or the mic.

| Suite | Checks |
|---|---|
| `VideoSettingsTests` | 1512×982@2 → 3024×1964; 5K → 3840×2160; 1920×1080@1 → 1920×1080; odd sizes made even |
| `TimelineTests` | start/pause/resume math, multiple pauses, nil while paused, elapsed |
| `RecordingFilesTests` | name format, ` (2)`, folder creation |
| `DiskPolicyTests` | 1 GB / 2 GB / 300 MB thresholds |
| `AudioMixerTests` | one and two sources, different rates (44.1 → 48 kHz), offset start, holes → silence, sum clamped, dead source → no stall |
| `WriterTests` | 10 s synthetic file: plays, right duration/frames/tracks; **static screen + audio** (§6 regression); pause cut; finish at stop time after a static end; text sharpness: decode a frame, PSNR vs source ≥ 35 dB |
| `CrashTests` | spawn `bubble-diag synthetic --seconds 20 --crash-after 9` (real-time pacing), it aborts; `bubble-diag check` → ≥ 7.9 s decodable |
| `SoakTests` (opt-in, `BUBBLE_SOAK=1`) | 2 h synthetic at faster than real time: file > 4 GB OK, duration exact, RSS of the writer process flat (sampled), A/V drift < 1 frame at the end |
| `AppModelTests` | state machine with fakes: Idle→Ready→Countdown→Recording→Paused→…; ⌥⇧L fast path; ⌥⇧C twice in 3 s; Esc in countdown; permission missing → Welcome; `.stoppedOnItsOwn` → error state; menus as data per state |
| `SnapshotTests` | every UI state below, light and dark, @2x PNG → `build/check/snapshots/` + `index.html` contact sheet |

Snapshot catalog (QA owns the list, designer reviews the pictures): Recorder panel (1 display,
2 displays, camera blocked, mic blocked, no camera, computer sound on); bubble S/M/L with a
placeholder face, with hover controls, before the first frame (spinner), dimmed (paused); countdown
3/2/1; menu bar label idle / `● 03:12` / `● 1:02:03` / paused; Welcome (all grey, mixed, all green,
needs relaunch); Settings; Discard alert; low-disk / display-disconnected / mic-switched messages.

`check.sh` exits non-zero on any failure and writes `build/check/summary.txt`. Register
`build/check/snapshots/index.html` as an artifact for the designer at each run that changes UI.

### 8.2 Engineers' own loops

Same rule: synthetic only. Capture engineer iterates with `bubble-diag synthetic` and unit tests;
UI engineer with `FakeRecorder` + `FakeCameraFeed` (`scripts/run.sh` with `BUBBLE_FAKE=1` makes
`main.swift` wire the fakes, so the app runs without capturing anything).

### 8.3 Real capture: one batched run, announced

Real ScreenCaptureKit/camera runs put a recording indicator and test windows on the user's screen.
So: none in the automated gate, none while iterating. Once, at the end of the capture track, the
capture engineer asks main first, then runs `bubble-diag record` for 10 s with mic, which checks in
one go: CFR fix with a real stream (no -16341), bubble window in / other windows out (pixel test,
as in `spikes/sck-record`), mic present and in sync, last-frame stop time. Plus one start with the
bubble at `alphaValue = 0` (camera hidden): it must still be found on screen and be invisible in
the video.

Writer note (capture track): both writer inputs always use `expectsMediaDataInRealTime = true`.
With `false`, AVAssetWriter interleaves strictly (no video past a ~0.5 s chunk until audio reaches
it), which deadlocks a producer that writes both tracks from one thread. `realTime: false` in
`RecordingWriter` now only means "wait for the encoder instead of dropping".

### 8.4 Manual (needs the user, `docs/qa.md`)

First-launch prompts and relaunch; camera image in the bubble (camera permission was never
granted to anything here, so nothing about the camera ran); a 1-minute real take with drag/resize;
⌥⇧L from another app; unplug a display, AirPods leaving; lock screen; a 1-hour take; `kill -9`
during a take then play the file.

---

## 9. Engineering tasks (3 parallel tracks)

Everyone starts at once on the skeleton (it builds). Contracts first, fakes first, real things last.

### Track 1 — capture engineer (BubbleCore/Capture)
1. `VideoSettings`, `Timeline`, `RecordingFiles`, `DiskPolicy` (pure, quick; unblocks QA's tests).
2. `RecordingWriter` + `FramePump` (§3, §6). Done when QA's `WriterTests` and `CrashTests` pass.
3. `AudioMixer` (§3.2). Done when `AudioMixerTests` pass.
4. `ScreenCapture` + `LiveRecorder` (start/stop/pause/discard, events, failure path).
5. `LiveCameraFeed`, `LiveDeviceCatalog`, `LivePermissions`, `SystemEvents`.
6. Ask main, then the one real run (§8.3). Report.

### Track 2 — app/UI engineer (BubbleUI, Bubble)
1. `AppModel` state machine on the fakes + `AppDelegate` + `StatusItemController` + `MenuBuilder`; `BUBBLE_FAKE=1`.
2. `Hotkeys` (⌥⇧L/P/C), countdown window.
3. Bubble window: preview layer, circle, mirror, ring, drag + snap + per-display memory (`BubblePlacement`, pure, tested), hover controls S/M/L/⦸, spinner.
4. Recorder panel (camera, mic, computer sound, display menu), Settings, Welcome (permissions, relaunch).
5. Menu bar timer, recording menu, Discard alert, after-stop actions, quit dialog, error messages.
6. Wire the Live* implementations in `main.swift` when track 1 lands them.

### Track 3 — QA engineer (scripts, BubbleTesting, bubble-diag, Tests)
1. `scripts/build-app.sh`, `run.sh`, `check.sh`, `Resources/Info.plist`, icon. **First, today**: the
   other two need `run.sh`.
2. Fakes: `FakeCameraFeed`, `FakeDeviceCatalog`, `FakePermissions`, `SyntheticFrames`, `SyntheticAudio`.
3. Core test suites against `EngineAPI.swift` (they fail until track 1 lands each piece: mark them
   `.disabled("waiting for capture")` and enable as pieces land).
4. `bubble-diag synthetic` / `check` + `CrashTests`; `record` for the one real run.
5. Snapshot harness + catalog + contact sheet; `AppModelTests`.
6. `docs/qa.md` manual checklist; `SoakTests`.

### Review
The architect reviews code (contracts kept, queue confinement, failure paths, no real capture in
tests); the designer reviews the snapshot contact sheet. A track is done when `scripts/check.sh`
is green and its reviewer says so.

---

## 10. Spikes (in `spikes/`, throwaway, `swiftc` single files)

| Spike | What it proved | Run |
|---|---|---|
| `writer-crash/` | Fragmented writing survives `abort()`: 8.0 of 9 s playable (mp4/mov, H.264/HEVC, AVFoundation + ffmpeg). `GAPS=1` reproduces the -16341 writer bug; `PUMP=0.0333` fixes it | `swiftc -O main.swift -o w && ./w out.mp4 h264 20 9`; `./check out.mp4` |
| `sck-record/` | SCK → AVAssetWriter at 3024×1964; app excluded except the bubble (pixel test: red bubble in, blue toolbar out); SCK mic works, host clock shared; startCapture ~170 ms | real capture: do not rerun casually (§8.3) |
| `permissions/` | Reads the 3 permission states without prompting | `swiftc main.swift -o p && ./p` |

Not verified (needs the user or real devices): permission prompts and the relaunch flow; anything
with the camera (never authorized here); the mic switch on unplug via `updateConfiguration`;
computer-sound capture and mixing; `showMouseClicks` look; windows created after `startCapture`
being excluded (expected, since the whole app is excluded; check in the §8.3 run); behaviour on a
display unplug or resolution change mid-take; hours-long real takes.
