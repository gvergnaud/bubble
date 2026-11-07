# Bubble editor — architecture

The editor turns a recording into an edited video: a transcript on the side, select words or a
stretch of the timeline, cut it or change its speed, download the result. It runs as a web page in
the user's browser, served by Bubble itself on `127.0.0.1`. The source recording is never modified.

- Page ↔ server contract: **`docs/editor-api.md`** (the source of truth for every request and type).
- Fixture + mock server (build the page today): `web/fixtures/`, `node web/mock-server.mjs`.
- Page (designer): `web/editor/`. UX: Loom's editor (`docs/reference/loom-editor.mov`) plus speed ranges.
- Recorder architecture (unchanged): `docs/architecture.md`.

Status: written 2026-11-06 by the architect. Open decision for the user: which transcription
engine (§5). Everything else is decided here.

---

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| Where the UI runs | The user's default browser, page served by Bubble | What he asked; the web gives a rich text + timeline UI cheaply |
| Server | In-process in Bubble, **Network.framework `NWListener`**, a small HTTP/1.1 server we write (~500 lines), bound to `127.0.0.1` | No dependency, no network fetch at build time (same rule as the recorder); we need only GET/PUT/POST/PATCH/DELETE, Range, static files, cookies |
| Port | `47621`, next free one if taken | Stable URL so a reopened tab works while Bubble runs |
| Auth | Per-install token (Keychain-free file `0600` in Application Support), exchanged once for an `HttpOnly; SameSite=Strict` cookie; `Host` header must be `127.0.0.1:<port>`/`localhost:<port>` | Any website the user visits can send requests to localhost: the cookie + SameSite blocks cross-site use, the Host check blocks DNS rebinding. The page code does nothing for it |
| Edit model | One sorted list of `{start, end, rate}` in source time, `rate 0` = cut (designer's model). Undo/redo in the page | Non-destructive, tiny, easy to validate; the same list drives preview and export |
| Persistence | One project folder per recording in `~/Library/Application Support/Bubble/Projects/<id>/` (project.json, waveform, poster, exports). Atomic writes. Autosave from the page (600 ms debounce) | The recordings folder stays clean (it is the user's library); close the page, reopen, it's all there |
| Project id ↔ recording | UUID; stored in an extended attribute of the recording (`local.bubble.project-id`) **and** in `Projects/index.json` (path, size, creation date) | Survives a rename/move in Finder. An xattr is metadata, the video bytes are never written |
| Preview | The page plays the **source** file and skips cuts / sets `playbackRate` (pitch kept by the browser) | No render to edit; instant |
| Export | `AVAssetReader` on an `AVMutableComposition` (cuts by insertion, speed by `scaleTimeRange`, audio via `AVAssetReaderAudioMixOutput` with `audioTimePitchAlgorithm = .spectral`) → `AVAssetWriter` H.264 + AAC, 30 fps CFR | **Verified (spike):** exact duration. `AVAssetExportSession` with H.264 presets **fails** (-16364) as soon as a range is sped up; HEVC preset works but HEVC plays in fewer places. Reader/writer gives codec, bitrate, progress and cancel |
| Transcription | Behind a `Transcriber` protocol; engines listed to the page (`GET /api/engines`) | Which engine is the user's decision (§5); the rest of the system doesn't care |
| Web stack | Plain HTML/CSS/ES modules in `web/editor/`, no CDN, no runtime fetch outside the server; copied into `Bubble.app/Contents/Resources/editor/` by `scripts/build-app.sh` | Fully local, no Node needed to build the app |

---

## 2. Server (`Sources/BubbleEditor/Server/`)

- `HTTPServer`: `NWListener` on `127.0.0.1:47621` (`requiredLocalEndpoint` / `NWParameters.tcp` with
  `requiredInterfaceType = .loopback`), one `NWConnection` per client, HTTP/1.1 keep-alive,
  request parsing (method, path, query, headers, `Content-Length` body ≤ 1 MB), chunked responses
  not needed. Files are streamed in 256 KB chunks (a 2 GB recording never sits in memory).
- `Router`: the routes of `docs/editor-api.md`, JSON in/out with `Codable` types (`ProjectModels.swift`
  mirrors the TypeScript types field for field).
- `Range`: `bytes=a-b`, `bytes=a-`, `bytes=-n` → `206` with `Content-Range`; `416` when out of
  bounds. Seeking in `<video>` depends on it.
- `StaticFiles`: `/edit/:id` → `editor/index.html`; `/editor/*` → the bundle's `Resources/editor/`
  (path normalized, no `..`). `Cache-Control: no-cache` (the files change with app updates).
- `Auth`: token file `~/Library/Application Support/Bubble/editor-token` (32 random bytes, hex,
  mode 0600). `/edit/:id?t=<token>` → `Set-Cookie` + `302` to the clean URL. Every `/api/*` and
  `/media/*` request needs the cookie; static files don't. Host check on every request.
- Lifecycle: started lazily the first time something opens the editor, stopped at quit. Runs
  its own serial queue for I/O; project mutations go through `ProjectStore` (an actor).
- Opening: `NSWorkspace.shared.open(URL("http://127.0.0.1:<port>/edit/<id>?t=<token>"))` from the
  Recordings window ("Edit") and after Stop (if design wants it there). The browser opens in the
  user's current Space; nothing else is shown by Bubble.

## 3. Projects (`Sources/BubbleEditor/Projects/`)

```
~/Library/Application Support/Bubble/
  editor-token
  Projects/
    index.json                       [{ id, path, bytes, createdAt }]   (rebuilt by scanning if lost)
    <id>/project.json                Project minus derived URLs (editor-api.md §2), version: 1
    <id>/waveform.bin                peaks, 1 byte per 1/50 s
    <id>/poster.jpg
    <id>/transcript-raw/<engine>.json  the engine's raw answer (to re-derive words without re-paying)
    <id>/exports/<jobId>.mp4         deleted 24 h after it was made, or at the next export
```

- `ProjectStore` (actor): `project(for recordingURL) -> Project` (creates it on first open: id,
  title = file name, duration/size via AVFoundation, xattr written), `project(id)`,
  `saveEdits(id, revision, segments) throws(stale|invalid)`, `update(id, title/speakers)`,
  `setTranscript(id, Transcript)`. Writes are atomic (`Data.write(options: .atomic)`), one file per
  project, so a crash never leaves half a project.
- Finding a recording: xattr id first; else `index.json` by path; else by size + creation date
  (moved without xattr, e.g. a copy). Recording gone: `404 { error: "source_missing" }` and the
  page says so; the project is kept.
- `EditPlan` (pure, `Sendable`): validation (editor-api.md §3 invariants), `pieces(duration:segments:)`
  → kept pieces with rates, `outputDuration`, `outputTime(forSource:)`. Used by the export and by
  tests. The page has its own JS twin; both are checked against the same cases (§8).

## 4. Media (`Sources/BubbleEditor/Media/`)

- `Waveform`: `AVAssetReader` audio → mono Float32 at 48 kHz → peak of |x| per 1/50 s → `UInt8`
  (×255, a gentle gain of 1.4 then clamp). ~1 s for an hour of audio. Computed on first open,
  `202` until ready.
- `Poster`: `AVAssetImageGenerator` at 1 s, 1280 px wide, JPEG.
- `Exporter` (job queue, one export at a time, cancellable):
  1. `EditPlan.pieces` → `AVMutableComposition`: insert each kept piece; `scaleTimeRange` the
     ones with rate ≠ 1.
  2. `AVAssetReaderTrackOutput` (video, `420v`) on that composition. The sound is not in it:
     **`AudioJoiner`** reads each kept piece on its own (`AVAssetReaderAudioMixOutput`, LPCM 48 kHz
     mono, `.spectral`, pitch kept) and **crossfades every join** (cuts and speed changes; the
     picture stays a hard cut): 40 ms equal-power (cos/sin), centred on the join, each side
     running 20 ms past it into the recording's neighbouring sound (shorter for a piece under
     40 ms or at the recording's edges). Each piece also reads 200 ms before and after, thrown
     away: the spectral stretcher ramps up over ~15 ms, sometimes drops out in its first ~110 ms
     (2-3 runs in 30 with 30 ms of pre-roll, none from 150 ms) and rings out past its end.
     Measured (MediaTests): a butt splice of a tone at crest/trough jumps 1.0; with the fade the
     largest sample step at the join ≤ 1.3× the steady tone's; on noise the level across a cut and
     into/out of 1.5× stays within 2 dB of its two sides (equal-gain dipped 3-4 dB at speed
     changes: the stretcher decorrelates the two sides, so equal power everywhere).
     No drift (MediaTests.manyJoinsDoNotDrift): 100 short cuts + a 1.5×, a 2× and a 0.5× range
     (107 parts) on a 60 s flashes/beeps file: the last flashes and beeps land within 1 frame of
     their output times, A/V within 1 frame. Cost (optimized build, 10 min 1280×720 30 fps
     source): no cut 38.8 s, 200 cuts (201 parts, one reader each + 200 ms pre-roll) 37.3 s
     (0.96×), the same butt-spliced 37.9 s: the video encode dominates, so no reader reuse.
  3. **Resample video to 30 fps CFR**: compute each frame's output slot (`round(t × 30)`), skip a
     frame whose slot is already written (speed-ups), repeat the previous frame for an empty slot
     (slow-downs). Without it, sped-up parts give duplicate timestamps (spike: ffmpeg flags
     non-monotonic DTS in the 1.5× range).
  4. `AVAssetWriter` `.mp4`: H.264 High, the source's size, bitrate from `VideoSettings`'s formula,
     AAC 128 kb/s, `shouldOptimizeForNetworkUse = true` (moov first: plays while downloading).
     Both inputs pumped with `requestMediaDataWhenReady` on their own queues (offline interleaving),
     **one `AVAssetReader` per track**: with a single reader, when the audio side stopped pulling
     (audio longer than video) the video side's `copyNextSampleBuffer` blocked forever (seen once
     in the gate, a 2 h hang). Plus a stall watchdog: no sample written for 60 s → the export fails
     with "The export stopped making progress. Try again."
  5. Progress = last written video time / output duration. Cancel = `reader.cancelReading()` +
     `writer.cancelWriting()` + delete the file.
  Spike numbers (68.6 s fixture, 3 segments incl. 1.5×): 62.585 s expected and got (0 ms off),
  5.7 s to render (≈11× real time) on this Mac. A 1 h 4K recording: expect a few minutes.
- No edits at all: same pipeline (one code path to test); the user can also just use the source.

## 5. Transcription (`Sources/BubbleEditor/Transcription/`) — engine pending the user's choice

```swift
public protocol Transcriber: Sendable {
    var id: String { get }             // "apple-local", "voxtral-mini-2602", "voxtral-mini-transcribe-3"...
    var name: String { get }
    var isLocal: Bool { get }
    func availability() async -> Availability          // .available / .unavailable(why)
    func transcribe(audio: URL, language: String?, progress: @Sendable (Double) -> Void) async throws -> TranscriptResult
}
public struct TranscriptResult: Sendable { var language: String?; var speakers: [String]; var words: [TimedWord] }
public struct TimedWord: Sendable { var start: Double; var end: Double; var text: String; var speaker: String }
```

- `AudioExtract`: recording → 16 kHz mono FLAC (or 16-bit WAV) in a temp file; ~2 MB per minute
  as FLAC. Long recordings are cut into chunks at silences (≤ 20 min each, 2 s overlap, words in
  the overlap deduped by time) for API limits; local engines take the whole file.
- `TranscriptionJob` (one at a time, queued): extract → engine → `Words.post`: fillers flagged
  (`uh um uhm euh hmm erm ben bah` + engine hints), speakers renamed `Speaker 1…` in order of
  first appearance → `ProjectStore.setTranscript`. Raw answer saved under `transcript-raw/`.
- API key (if a Mistral engine is chosen): in the Keychain (`kSecClassGenericPassword`, service
  `local.bubble.Bubble.mistral`), entered in Bubble's Settings, never sent to the page.

Options researched 2026-11-06 (Mistral docs, migrate-from-voxtral-2, model cards; brought to the user):

| Option | Diarization | Word times | Where audio goes | Cost | Notes |
|---|---|---|---|---|---|
| A. Voxtral Mini Transcribe V2 (`voxtral-mini-2602`), API | yes | **yes** | Mistral API (EU), key | $0.003/min | One call does it all; 13 languages; on a deprecation path (no date yet) |
| B. Voxtral Mini/Small Transcribe 3, API | yes (best) | **no**: segment only, `word` → 400 | Mistral API, key | $0.0035–0.004/min | Public Preview; we'd align words ourselves (local aligner): more work, less precise |
| C. Voxtral Mini 4B Realtime 2602, local (Apache 2.0) | no | no (token-position proxy) | stays on the Mac | free | ~2–3 GB model + MLX runtime; not enough alone |
| D. Apple SpeechAnalyzer/SpeechTranscriber (macOS 26) + FluidAudio diarization, local | yes (FluidAudio, CoreML) | timed text runs (`audioTimeRange`); word granularity **to verify** | stays on the Mac | free | Built into macOS; FluidAudio is a SwiftPM package (breaks our no-dependency rule) + a model download; quality below Voxtral |

**The user's pick (2026-11-06):** a toggle local ↔ Voxtral 3, **Voxtral 3 by default when an API
key is found** (Keychain item `local.bubble.Bubble.mistral`, or `MISTRAL_API_KEY`). Not V2.

- **Voxtral 3 path:** `voxtral-mini-transcribe-3-0`, `diarize=true`, segment timestamps → text,
  punctuation, speakers per segment. Word timing comes from **Apple's SpeechTranscriber run
  locally** on the same audio (locale = the language Voxtral detected), merged by `WordAligner`
  (pure): normalized tokens aligned by edit distance; matched words take Apple's times; unmatched
  runs are spread by letter count between matched neighbours; all clamped inside their Voxtral
  segment; speaker = the segment holding the word's midpoint. Fallback when Apple can't run:
  spread by letter count inside each segment, engine labelled "(approximate timing)". Alignment
  never fails a transcript. Long audio: chunks ≤ 15 min at silences, 2 s overlap, words deduped
  by time, speakers matched across chunks through the overlap words.
- **Local path:** Apple's SpeechTranscriber alone; one speaker ("Speaker 1"). Decided with main:
  no FluidAudio for now (it would add a SwiftPM dependency + a model download); speakers come
  with Voxtral 3.
- One real API call is allowed, on the synthetic fixture only, with main's OK (it uses his key);
  its raw answer becomes `web/fixtures/voxtral3-demo.raw.json`, the parser's test fixture. Tests
  never call the API. No `AppleTranscriber` run on his Mac while he records (Speech may prompt).

Files: `Transcription/MistralTranscriber.swift`, `MistralKey.swift`, `AppleTranscriber.swift`,
`WordAligner.swift` (E2).

## 6. Security and privacy

- Loopback only; Host check; cookie auth with SameSite=Strict; no CORS headers (no other origin
  may read responses); request bodies ≤ 1 MB; paths normalized.
- The page loads nothing from the internet (no CDN, fonts bundled or system fonts).
- With a Mistral engine, only the extracted audio of that recording leaves the Mac, when the user
  opens it in the editor (auto-transcription, default engine = Voxtral when a key is set) or picks
  "Re-transcribe with…" that engine; the page says so while it transcribes.

## 7. Layout and ownership (who writes which files)

```
Package.swift                                   architect (new target BubbleEditor, tests)
docs/editor-api.md, docs/editor-architecture.md architect
web/fixtures/, web/mock-server.mjs              architect (QA extends the fixtures)
web/editor/                                     designer (the page)

Sources/BubbleEditor/                           new library target, no AppKit, no SwiftPM deps
  Server/HTTPServer.swift  Router.swift  StaticFiles.swift  Auth.swift            E1 (server)
  Projects/ProjectModels.swift  ProjectStore.swift  EditPlan.swift  RecordingIndex.swift   E1
  EditorService.swift      facade for the app: start(), open(recording:), stop()  E1
  Media/Waveform.swift  Poster.swift  Exporter.swift  ExportJobs.swift            E2 (media)
  Transcription/Transcriber.swift  AudioExtract.swift  TranscriptionJobs.swift  Words.swift
                FixtureTranscriber.swift  + the chosen engine(s)                  E2
Sources/BubbleUI/ (Recordings window "Edit", after-stop hook, Settings: engine + API key)  app-ui
scripts/build-app.sh (copy web/editor into Resources/editor)                          qa
Tests/BubbleEditorTests/ + web/test/ + scripts/check.sh steps                         qa
```

Seams: E1 ↔ E2 through `EditorService` calling `Exporter`, `Waveform`, `Poster`,
`TranscriptionJobs` (protocols in `ProjectModels.swift`, stubbed by E1 on day one so E2 builds);
page ↔ server through `docs/editor-api.md` only.

## 8. Tasks, in order

**E1 — server engineer**
1. `BubbleEditor` target, `ProjectModels` (Codable, exactly editor-api.md), stubs for E2's types.
2. `HTTPServer` + `StaticFiles` + `Auth` (+ Range); serve `web/editor/` from the repo in debug.
3. `ProjectStore` + `RecordingIndex` + `EditPlan`; routes for project, PATCH, PUT /edits.
4. Routes for waveform, poster, transcription, export, engines (calling E2's pieces).
5. `EditorService` + hand-off to app-ui (open URL).

**E2 — media + transcription engineer**
1. `Waveform`, `Poster` (+ tests on the fixture).
2. `Exporter` with CFR resample, progress, cancel; `ExportJobs`.
3. `AudioExtract`, `Words.post`, `Transcriber`, `TranscriptionJobs`, `FixtureTranscriber`.
4. The engine(s) the user picks.

**app-ui**: "Edit" in the Recordings window (and after Stop if the designer wants it), Settings
section for transcription (engine, API key → Keychain), `EditorService` start/stop.

**designer**: `web/editor/` against the mock server; then against the real one.

**qa**
1. `build-app.sh` copies `web/editor`; `check.sh` gains the editor steps.
2. Contract tests: start `EditorService` on a temp Application Support folder + the fixture as the
   recording; replay the same request script against it **and** the mock server; responses must
   match `docs/editor-api.md` (shape) and each other (status codes, 409/422/401/403/206/416).
3. Edits golden cases: `web/fixtures/edits-cases.json` (inputs → valid/invalid, pieces, output
   duration), run by Swift tests (`EditPlan`) and by `node --test` (the page's JS).
4. Export checks: render the fixture's edits; duration = Σ kept/rate ± 1 frame; ffprobe 30.00 fps;
   `ffmpeg -v error -i out.mp4 -f null -` prints nothing; source file hash unchanged.
5. Page checks, headless: Chrome is installed (`/Applications/Google Chrome.app`): run it with
   `--headless=new --screenshot` against the mock server for each state (`/mock/reset?...`) →
   PNGs in `build/check/editor/` for the designer. Never a visible browser window.

Order of merge: E1 1–3 and E2 1–2 in parallel → E1 4 wires E2 → app-ui hooks → engine last.

## 9. Measured, and not verified yet

**Apple SpeechTranscriber, measured 2026-11-07** (headless CLI on `web/fixtures/demo.mp4`, synthetic voices):
- No authorization step was needed and the run was not blocked; whether a dialog appeared on
  screen, and whether Bubble.app itself gets a prompt, is not verified (docs/qa.md §8 covers his
  first "On this Mac" run).
- Granularity: 215 runs, all single words. But runs are back to back (median gap 0.00 s): a word's
  start absorbs the pause before it (sentence starts off by 0.68 s median, 1.2 s max). Fix shipped
  in `AppleTranscriber`: start = end − (0.12 s + 0.06 s per letter) when that is later. After it:
  starts median 0.149 s off, p90 0.375; sentence starts median 0.164, max 0.32. Ends median 0.147.
  (The fixture's in-sentence times are themselves ±0.1 s estimates; sentence edges are exact.)
- Speed: 68.6 s of audio in ~1 s (≈60× real time). Text quality very good ("Option Shift L" →
  "option shift Al", "one and a half" → "one. 5"; "uh" heard as "Ah", Voxtral too).
- Speech model: already installed on this Mac (shared with dictation), so its download size is
  unknown; `AssetInventory` reports progress in units, not bytes.
- Voxtral 3 path on the same file (real saved answer + these Apple words): 7/215 words
  approximate (3.3%); timed words' start error median 0.144 s, p90 0.38.

Not verified yet:
- Voxtral API behaviour on long audio (chunking ≤ 15 min, speaker matching across chunks): only
  the 68 s fixture was sent.
- Export of a multi-hour 4K source: time and memory (expected fine: streamed, but not run).
- Browser autoplay/seek behaviour with very long fragmented sources (the recorder's mp4s are
  fragmented): Chrome and Safari both play fragmented mp4, Range seeking on a 2 GB file not tried.
