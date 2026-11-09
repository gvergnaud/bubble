# Bubble editor — page ↔ server contract (v1)

Owner: architect. The page (designer, `web/editor/`) and the server (inside Bubble, Swift) both
build against this file. Change it only through the architect. Fixture: `web/fixtures/`.
Mock server with the same API: `node web/mock-server.mjs` (no dependencies).

Built from the designer's draft shape (m_299); the differences from it are marked **Δ**.

---

## 1. Basics

- Server: `http://127.0.0.1:47621` (Bubble picks the next free port if taken and opens the page
  with the right one). Listens on the loopback interface only.
- Page: `GET /edit/:id` → `web/editor/index.html`; its assets at `/editor/*` (the files of
  `web/editor/`, served as they are). One page, no build step needed.
- **Δ Home:** `GET /` → the same `index.html` (the page routes on its path: `/` = home, recent
  videos + Open Video…, `docs/editor-open-video.md` §3F). `/?t=<token>` does the same token
  exchange as `/edit/:id?t=` and redirects to `/`.
- **Δ Auth (the page does nothing for it):** Bubble opens `/edit/:id?t=<token>`. The server checks
  the token, sets the cookie `bubble=<token>; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000`
  and redirects to `/edit/:id`. After that, every `fetch` and `<video src>` carries the cookie by
  itself. Requests without a valid cookie get `401`. The token is stable across launches (stored
  by Bubble), so a bookmarked or reopened tab keeps working while Bubble runs. The server also
  rejects a `Host` header other than `127.0.0.1:<port>` or `localhost:<port>` (DNS rebinding).
  In the mock server the token is `dev`: open `http://127.0.0.1:47621/edit/demo?t=dev`.
- Times are **seconds in source time** (the original recording), as numbers with ms precision.
- JSON everywhere, `Content-Type: application/json`. Errors: `{ "error": "<code>", "message": "<text for a human>" }`.
- Bubble not running = server not running: the page shows "Open Bubble to keep editing" when a
  request fails to connect (retry every 3 s).

## 2. Project

`GET /api/projects/:id` → `Project`

```ts
type Project = {
  id: string                 // stable per recording (not the file name)
  title: string              // default: file name without extension
  createdAt: string          // ISO 8601, when the recording was made
  updatedAt: string
  video: {
    url: string              // "/media/:id/source": the source file, HTTP Range supported (seek)
    duration: number         // seconds
    width: number; height: number; fps: number
    posterUrl: string        // "/media/:id/poster.jpg": a frame at 1 s, for the page while loading
  }
  waveform: { url: string }  // Δ separate request (big for long recordings): see §4
  transcript: Transcript
  edits: Edits
  export: ExportJob | null   // the latest export of this project, if any (§6)
  source: SourceFile         // Δ where the video file is, and whether it's reachable (§8)
}

type SourceFile = {
  name: string               // "Interview raw.mov"
  folder: string             // display name of its folder: "Desktop", "Movies/Bubble", "T7/Footage"
  path: string               // full path, for a tooltip only (the page never sends it back)
  state: 'ok' | 'missing' | 'offline'   // offline = on a volume that isn't connected
  volume?: string            // with 'offline': the volume's name, "T7"
}

type Transcript = {
  status: 'none' | 'queued' | 'running' | 'ready' | 'failed'   // Δ 'queued' added
  progress: number           // 0..1, meaningful while 'running'
  engine: string | null      // e.g. "voxtral-mini-transcribe-api", "fixture"; shown in a tooltip
  language: string | null    // "en", "fr"...
  error?: string             // when 'failed': a sentence for the user
  errorCode?: 'no_sound'     // Δ with 'failed': the video has no sound track; no Retry, no engine switch
  speakers: { id: string; name: string }[]     // name defaults to "Speaker 1", "Speaker 2"...
  words: Word[]              // in time order
}

type Word = {
  start: number; end: number
  text: string               // with its trailing punctuation: "everybody,"
  speaker: string            // a speakers[].id
  filler?: true              // Δ "uh", "um", "euh"... flagged by the server: "Remove filler words"
}
```

Paragraphs are the page's job: a new paragraph at a speaker change, or a pause > 1.5 s
(Loom-like), with its start time on the left.

## 3. Edits (non-destructive)

```ts
type Edits = {
  revision: number           // bumped by the server on every accepted PUT
  segments: Segment[]        // only what differs from "normal speed, kept"
}
type Segment = { start: number; end: number; rate: number }
// rate 0 = removed (cut). rate 0.5 | 0.75 | 1.25 | 1.5 | 1.75 | 2 = played at that speed.
```

Invariants (the page normalizes, the server **validates** and answers `422` if broken):
1. sorted by `start`; non-overlapping (`end <= next.start`); `0 <= start < end <= duration`;
2. `rate !== 1` (rate 1 = no segment); `rate === 0` or `0.25 <= rate <= 4`;
3. touching segments with the same rate are merged; segments shorter than 1/30 s are dropped.

Operations, all done by the page on the segment list, then saved:
- **Delete** a selection = set rate 0 on [start, end) (overwrites what was there).
- **Restore** = remove any segment over [start, end) (back to normal).
- **Speed** = set rate r on [start, end); a cut inside it stays cut (cut wins).
  Rule: setting a range replaces everything inside it, except that **Speed never un-cuts**: the
  cut parts inside the selection keep rate 0.
- A selection made from text runs from the first word's `start` to the last word's `end`; a word
  counts as removed/sped-up when its midpoint is inside the segment.

`PUT /api/projects/:id/edits` body `{ revision, segments }` (the revision the page started from)
→ `200 { revision }`, or `409 { error: "stale", edits: Edits }` (another tab saved first: take
theirs and re-apply nothing), or `422 { error: "invalid", message }`.
Autosave: debounced 600 ms after the last change, and on `pagehide` with `fetch(..., { keepalive: true })`.

**Undo / redo** live in the page (an in-memory stack of `segments` lists). They are lost on reload;
the saved state is not.

Playback in the page (no render needed): play the source `<video>`, jump over rate-0 segments, set
`playbackRate` inside speed segments (`preservesPitch` is on by default in browsers). The edited
duration shown is `Σ kept / rate`.

## 4. Waveform

`GET /api/projects/:id/waveform` → `{ peaksPerSecond: 50, encoding: "uint8-base64", peaks: string }`
(one byte per 1/50 s: the peak of |sample|, 0..255). **Δ** base64 bytes rather than a float array:
4 h = 720 000 peaks = 960 KB instead of ~4 MB of JSON. Decode:
`Uint8Array.from(atob(peaks), c => c.charCodeAt(0))`. `202 { status: "pending" }` while Bubble is
computing it (first open of a long recording): retry after 1 s.

## 5. Title, speakers, transcription

- `PATCH /api/projects/:id` body `{ title?: string, speakers?: { id, name }[] }` → `200 Project`.
- **Δ** `POST /api/projects/:id/transcription` body `{ engine?: string }` → `202 { transcript: Transcript }`
  (status `queued`). Starts or restarts it (a running job is canceled and started over). No
  `engine` = the default one. The page uses it for **Retry** and **Re-transcribe with…** only.
- **Δ Auto-transcription (no Transcribe button, 2026-11-07):** `GET /api/projects/:id` on a project
  whose `transcript.status` is `none` starts the transcription with the default engine, and that
  same answer already carries `status: 'queued'` and `engine`. If no engine can run, it answers
  `status: 'failed'` with `error` (the page shows it inline with Retry). A `failed` transcript is
  never restarted by itself. `none` stays only while the recording is missing (`source_missing`).
  So on load the page only polls; it never POSTs to start.
- `GET /api/engines` → `{ engines: Engine[] }`:
  ```ts
  type Engine = { id: string; name: string; local: boolean; available: boolean; why?: string; default: boolean }
  // today: { id: 'voxtral-mini-transcribe-3', name: 'Voxtral 3 (Mistral API)', local: false, why?: 'Add your Mistral API key.' }
  //        { id: 'apple-local', name: 'On this Mac', local: true }
  // default: true on exactly one: Voxtral when a key is found, else apple-local.
  ```
  The default engine is the one auto-transcription uses; "Re-transcribe with…" (in the transcript
  panel's menu) lists the others. When an engine's `local` is false, the page says that the audio
  is sent to Mistral (next to the progress state, and in that menu). Local engine: one speaker (`S1`, "Speaker 1").
- `Word.approximate?: true`: the word's time was estimated (spread by letters inside its segment),
  not measured. The page may show it more softly; editing works the same.
- Mistral key (the key goes page → server only, **never** server → page, never logged):
  - `GET /api/settings` → `{ mistralKey: 'keychain' | 'environment' | 'none' }`
  - `PUT /api/settings/mistral-key` body `{ key }` → Bubble checks it with one request to Mistral
    (no audio) → `200 { engines }`, or `422 { error: 'invalid_key', message }`, or
    `502 { error: 'unreachable', message }` when Mistral can't be reached. Stored in the Keychain.
  - `DELETE /api/settings/mistral-key` → `200 { engines }` (the Keychain item is removed;
    `MISTRAL_API_KEY` in Bubble's environment, if set, still counts).
- Progress: poll `GET /api/projects/:id` every 1 s while `transcript.status` is `queued` or `running`.

## 6. Export

- `POST /api/projects/:id/export` body `{}` → `202 ExportJob`.
- `GET /api/exports/:jobId` → `ExportJob`; poll every 1 s while `queued` or `running`.
- `DELETE /api/exports/:jobId` cancels.

```ts
type ExportJob = {
  id: string
  status: 'queued' | 'running' | 'done' | 'failed' | 'canceled'
  progress: number           // 0..1
  revision: number           // the edits revision it renders
  duration: number           // seconds of the edited video
  url?: string               // when done: "/api/exports/:jobId/file": Content-Disposition attachment,
                             // filename "<title> (edited).mp4"
  bytes?: number
  error?: string
}
```

The export renders `revision`; editing during an export does not change it (the page shows
"Export is out of date" when `project.edits.revision > export.revision`). The source is never written.

## 7. Status codes

`200` ok · `202` accepted / not ready yet · `401` no or bad token · `403` bad Host header ·
`404` unknown project or job · `405 method_not_allowed` wrong method on a known route ·
`409` stale revision · `413` body over 1 MB · `416` Range out of bounds · `422` invalid body ·
`431` headers too large · `500` the server failed (message for the user) ·
connection refused = Bubble is not running.

**Recording file gone** (moved off the disk, deleted): `GET /api/projects/:id` still answers `200`
(the page shows the transcript and edits and says the video is missing); `/media/:id/source`,
waveform and poster when not cached, `POST .../transcription` and `POST .../export` answer
`404 { error: "source_missing" }`.

**Bubble quit during a job:** a transcript left `queued`/`running` loads as `failed` with
`error: "Stopped when Bubble quit."`; the page offers to start it again.

`video.duration` is the longest track of the file (what `<video>.duration` reports), not
AVAsset's duration (a few ms shorter).

## 8. Opening any video (Δ 2026-11-09, `docs/editor-open-video.md`)

Rule: **the page never sends a file path.** Paths enter only through Bubble's own UI (its open
panel, the Dock, Finder's Open With). The drop flow proves the page holds the file's bytes instead.

```ts
type ProjectSummary = {
  id: string
  title: string
  duration: number            // source seconds
  editedDuration: number      // after cuts and speed ranges (= duration when no edits)
  posterUrl: string | null    // null while not made yet or when the file is unreachable
  updatedAt: string           // ISO 8601, last edit
  file: SourceFile            // §2
}

type OpenState = {
  state: 'pending' | 'opened' | 'canceled' | 'failed'
  projectId?: string          // with 'opened'
  sameBytes?: boolean         // with 'opened' after a locate: false = same length, other bytes (relinked)
  error?: 'unsupported_format' | 'no_video' | 'different_video'   // with 'failed'
  message?: string            // with 'failed': the sentence to show (editor-open-video.md §4)
}
```

| Request | Answer |
|---|---|
| `GET /api/projects` | `200 { projects: ProjectSummary[] }`, last edited first |
| `POST /api/open` (no body) | Bubble shows its open panel. `202 { openId }`; `409 { error: 'busy', message }` when a panel is already up (Bubble brings it to the front) |
| `GET /api/open/:openId` | `200 OpenState`. Poll every 500 ms while `pending`. `404` for an unknown or expired id (kept 10 min after it ends) |
| `POST /api/open/dropped` body `{ name, size, lastModified, head, tail }` | `200 { projectId }` · `404 { error: 'not_found', message }` · `422 { error: 'unsupported_format' \| 'no_video', message }` |
| `POST /api/projects/:id/locate` (no body) | The panel to find a missing file: `202 { openId }` + polling as above; `failed` with `different_video` when the length differs by more than 0.1 s; `opened` with `sameBytes: false` when the length matches but not the fingerprint |
| `POST /api/projects/:id/reveal` | Show in Finder. `204`; `404 { error: 'source_missing' }` |
| `DELETE /api/projects/:id` | `204`. Deletes the project (edits, transcript, waveform, poster, exports), **never the video** |

Drop body: `name` (File.name), `size` (bytes), `lastModified` (File.lastModified, ms since 1970),
`head` / `tail`: lowercase hex SHA-256 of the first and the last 1 MiB (1 048 576 bytes) of the
file; under 2 MiB, both are the SHA-256 of the whole file. Bubble only opens a file on this Mac
whose name, size and both hashes match; ties: the copy whose modification date equals
`lastModified`, else the newest.

`/media/:id/source` sends `Content-Type` by extension: `video/mp4` (`.mp4`, `.m4v`),
`video/quicktime` (`.mov`).

`Project.source.state` other than `ok`: the editor shows the missing / offline state; media
routes answer `404 { error: 'source_missing' }` (missing) or `404 { error: 'source_offline' }`
(on a volume that isn't connected).
