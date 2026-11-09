# Bubble editor — open any video (v1)

Owner: ux-flows. Builds on `docs/editor-design.md` (the page), `docs/editor-architecture.md`
(server, projects) and `docs/editor-api.md` (the contract; the API changes below go there through
the architect). The user's ask (2026-11-09): "a file selector to open a video from any folder in
the web editor, so Bubble's editor works on other videos easily".

Status: v1 set picked by ux-flows with architect (m_699), editor-server (m_705) and
editor-media (m_704), 2026-11-09. Not verified yet: whether a file opened once from a protected
folder reopens from Recent after a relaunch without a new macOS prompt; iPhone spatial audio
tracks; AVFoundation's HDR tone mapping on a real iPhone clip.

---

## 1. Rules

1. **The video is never copied.** Bubble edits the file where it is, whatever its size. No
   upload into Application Support, no duplicate on disk.
2. **The video is never written.** Not its bytes, and for files outside `~/Movies/Bubble` not
   even an extended attribute (read-only drives, shares, iCloud Drive would sync it). The
   project remembers the file with a macOS bookmark and a fingerprint.
3. **The page never sends a path.** Paths enter only through Bubble's own UI (its open panel,
   the Dock, Finder's Open With). Otherwise any page holding the cookie could read any file
   through `/media/:id/source`.
4. **Same video, same project.** Opening a video again, from any entry point, opens its edits.
5. **One sentence when it can't.** Every refusal says why and what to do, in place.

## 2. Ways in (v1)

| # | Where the user is | Gesture | What happens |
|---|---|---|---|
| A | The editor's home page (`/`) or any editor page | **Open Video…** button | Bubble comes forward with the macOS open panel; pick a video → the page goes to it. Cancel → Bubble gives the browser back, nothing changes. |
| B | The home page, or an editor page | **Drop a video on the page** | The page proves it holds the file (hash of its first and last 1 MB, read locally, nothing uploaded), Bubble finds it on the Mac (Spotlight, by name + size, checked by the hashes) and opens it in place. Not found → "Choose it in Bubble…" (= A). |
| C | Bubble (Dock icon, menu bar menu, Recordings window) | **File > Open Video… ⌘O**, menu bar **Open Video…** | The open panel, then the editor opens in the browser (a new tab). |
| D | Finder | **Drop on Bubble's Dock icon**, **Open With > Bubble** | The editor opens in the browser on that file. Several files: one tab each. Bubble is never the default app for videos (rank Alternate). |
| E | Bubble | **File > Open Recent** (and the Dock icon's right-click list) | The last videos opened in the editor, recordings included. |
| F | The home page | **Recent videos** list | Every project: poster, title, length, folder, last edit. Click → its editor. A missing one says so. |

Unchanged: **Edit** in the Recordings window (⌘E), **Edit Last Recording** in the menu bar menu.
The Recordings window keeps listing only Bubble's own recordings. The Recordings window's
**Open** (plays the file in its default app) becomes **Play**, ⌘↓, so ⌘O means "open a video" everywhere.

### Why not the others

| Option | Verdict |
|---|---|
| `<input type=file>` upload | No: GBs copied through localhost, a duplicate on disk, the original path lost. |
| Copy into Bubble's library on drop | No: the same, by surprise. |
| The page sends a path it typed or remembered | No: rule 3. |
| A browser file picker + Spotlight lookup | Not needed: A gives an exact path every time; B covers the browser gesture. |

## 3. Flows

### A. Open Video… from the page

```
page  [Open Video…] ──POST /api/open──▶ Bubble remembers the front app (the browser),
                                          activates, shows NSOpenPanel (movies)
        "Choose a video in Bubble…"              │
        (button busy, Esc-able)       picked ◀───┴───▶ canceled
                                        │                 │
           Bubble re-activates the browser          canceled: button back, nothing else
           opened { projectId } → page goes to /edit/:id
```

- The request does not wait for the panel (it can stay up for minutes; a reload or sleep would
  lose the pick): `POST /api/open` → `202 { openId }`, the page polls `GET /api/open/:openId`
  every 500 ms. A reloaded tab picks a pending open up again.
- While the panel is up the button reads "Choose a video in Bubble…" and the page shows a quiet
  line "The file panel is open in Bubble." (it may be behind the browser on another Space).
  Pressing the button again brings the panel back to the front (409 busy, Bubble re-fronts it).
- The panel starts in the folder of the last video picked (Movies the first time). It shows
  movie files; an unreadable one is refused after the pick with its reason (§4), the panel
  doesn't grey files without saying why.

### B. Drop on the page

```
drag over the page ──▶ overlay "Drop to edit this video" (one file) /
                       "Drop one video at a time" (several) / "This isn't a video" (other type)
drop ──▶ "Finding <name> on your Mac…" (reads 2 × 1 MB, hashes them)
      ──POST /api/open/dropped { name, size, lastModified, head, tail }──▶
          found (one, or the newest of identical copies) ─▶ 200 { projectId } → /edit/:id
          not found ─▶ 404 not_found → card: "Bubble couldn't find <name> on your Mac."
                       "It may be on a drive Spotlight doesn't index, or in an app's
                        library (Photos). Choose it in Bubble instead."  [Choose it in Bubble…] (= A)
```

- On an editor page, dropping opens the other video in the same tab (edits are already saved).
- A drag from Photos, Mail or a website gives a file that is not on disk: it falls in "not found".
  So do files Spotlight hasn't indexed yet (a download from seconds ago), network shares and
  folders excluded from Spotlight. Ties between identical copies: the one whose modification
  date matches `lastModified`, else the newest.
- **macOS privacy prompt.** Desktop, Documents, Downloads, iCloud Drive and removable drives are
  protected: a file Bubble finds there by itself (not picked in its panel) makes macOS ask once
  per folder "Bubble would like to access files in your Downloads folder". While Bubble waits,
  the page says "If macOS asks, allow Bubble to read your Downloads folder." Denied → the "not
  found" card with **Choose it in Bubble…** (a panel pick never prompts).
- Lookup: `mdfind` run by Bubble (50-300 ms warm); the page hashes with `crypto.subtle`
  (127.0.0.1 is a secure context).

### C / D / E. From Bubble or Finder

All go through `editRecording(url)` (the existing path for recordings): "Opening the editor…" toast
after 1 s, the browser opens `/edit/:id`. A refused file: a Bubble alert with the same sentence
as the page (§4). The video is added to File > Open Recent.

### F. The home page

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ◉◦ Bubble                                               [ Open Video… ]   │
├────────────────────────────────────────────────────────────────────────────┤
│   ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐       │
│     Drop a video here to edit it, or Open Video…                           │
│     MP4, MOV or M4V · it stays where it is, nothing is copied              │
│   └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘       │
│   Recent                                                                   │
│   [poster] Demo for Camille        3:12 · edited 2 h ago · Movies/Bubble  ⋯│
│   [poster] Interview raw           48:05 · edited yesterday · Desktop      ⋯│
│   [  ⚠  ] Keynote rehearsal        1:02:11 · on "T7", not connected        ⋯│
└────────────────────────────────────────────────────────────────────────────┘
```

- `/` is the home; the editor's header glyph "◉◦ Bubble" links to it (tooltip "All videos").
- Each row: poster (or a placeholder), title, length (edited length when it differs), last
  edit, the folder's name (tooltip: the full path). ⋯ menu: **Show in Finder** (asks Bubble),
  **Remove from list…** ("Removes your edits and transcript for this video. The video file
  stays." [Remove] [Cancel]).
- Missing file: the row says "Missing" or `on "<volume>", not connected`; clicking still opens
  the editor (transcript and edits are there) in its missing state, with **Locate…**.
- Empty (no project yet): only the drop zone, a bit taller.

## 4. Edge cases

| Case | What the user gets |
|---|---|
| **Big file** (20 GB, 3 h) | Same flow: nothing copied, the page opens at once; the waveform fills in (202 retries), the transcript runs as for any recording (Voxtral sends the audio, about 2 MB per minute, and says so). Dropping reads 2 MB of it, whatever its size. |
| **Unsupported container** (mkv, webm, avi, flv, wmv) | Refused at open: "Bubble can't open .mkv files. It edits MP4, MOV and M4V videos. Convert it to MP4 first." |
| **A codec Bubble can't decode** (VP9; AV1 on Macs without an AV1 decoder) | Refused at open: "Bubble can't read this video's format (VP9). Convert it to H.264 or HEVC MP4 first." The test is AVFoundation's own (`isPlayable`, a video track, `isDecodable`), not a list. |
| **Bubble can decode it, the browser can't play it** (ProRes in Chrome, AV1 in Safari before M3) | Opens. The page tries the `<video>`; on its error (or no metadata after 10 s) the player area says "Your browser can't play this video's format (ProRes). Try Safari, or convert it to H.264." Transcript, timeline and **Download** still work (the export reads it). A preview copy is v2. |
| **No video track** (an audio file) | "This file has no video." |
| **No sound track** | Opens; the transcript panel says "This video has no sound, so there's no transcript." with no Retry (`Transcript.errorCode: 'no_sound'`). The timeline works (flat waveform). |
| **HDR** (iPhone HLG / PQ HEVC) | Previews as the browser shows it; the download is tone-mapped to SDR BT.709 and tagged (without it, it comes out washed out). |
| **Not 30 fps** (24, 25, 50, 60, variable phone videos) | The download keeps the source's rate snapped to 24/25/30/50/60, at most 60; a source measured under 20 fps (a mostly still screen recording) exports at 30. Longest side above 3840 px is scaled down; rotation kept. |
| **Several audio tracks** | The download keeps the first one (not verified with iPhone spatial audio). |
| **Moved or renamed** on the same drive | Found again by its bookmark; same project, the new place is remembered. |
| **Moved to another drive / copied back** | Found by its fingerprint (size + length + hash of first and last 1 MB) when the old file is gone: same project, silently. |
| **On an external drive that is unplugged** | Editor: "This video is on "T7", which isn't connected. Connect it to play and download; your edits are kept." Home row: `on "T7", not connected`. |
| **Deleted / can't be found** | Editor: the existing missing state, plus **Locate…** (Bubble's panel). A file of the same length (±0.1 s) is linked; another one: "This video is a different length, so your edits wouldn't line up." |
| **Same file opened twice** | Same project, same URL. Two tabs on it already work (409 → "edited in another tab"). |
| **A copy of an opened video** (Finder Duplicate) while the original exists | A new project (it's another file to edit), even when the copy carries the xattr of a Bubble recording. |
| **Several files dropped / opened** | Page: "Drop one video at a time". Dock / Open With: one tab per file. |
| **Bubble not running** | The page is served by Bubble, so a fresh load fails in the browser. An open tab keeps the existing offline state ("Open Bubble to keep editing", edits kept in the browser). Open Video… and drop need Bubble: their buttons are disabled with "Open Bubble to open a video". |
| **The panel is behind the browser** | The page's line "The file panel is open in Bubble."; clicking the button again re-fronts it. |
| **iCloud Drive file not downloaded** | Not verified in v1; it should open after macOS downloads it (reads block until then). |

## 5. Left out of v1

| Left out | Why |
|---|---|
| Preview proxy for ProRes and other codecs browsers don't play | A transcode step with its own progress and disk use; v1 says so clearly instead. |
| mkv / webm support | AVFoundation can't read them; needs a demuxer. |
| `bubble://` link to launch Bubble from an offline tab | Small, but not needed to open videos. |
| Editing several videos as one | Beyond "edit this video". |
| Sorting / searching the recent list | Few videos at first. |

## 6. API changes (now in `docs/editor-api.md` §1, §2, §8, which wins over this summary)

- `GET /` → the home page (same `?t=` token exchange as `/edit/:id`).
- `GET /api/projects` → `{ projects: ProjectSummary[] }`, last edited first:
  `{ id, title, duration, editedDuration, posterUrl, updatedAt, file: { name, folder, state: 'ok' | 'missing' | 'offline', volume? } }`.
- `POST /api/open` → Bubble shows its panel → `202 { openId }` · `409 { error: 'busy' }` (a panel is
  already up; Bubble re-fronts it). `GET /api/open/:openId` → `{ state: 'pending' | 'opened' | 'canceled' | 'failed', projectId?, error?, message? }`
  (`error`: `unsupported_format` | `no_video`).
- `POST /api/open/dropped` body `{ name, size, lastModified, head, tail }` (sha256 hex of the first and
  last 1 MB, or of the whole file under 2 MB) → `200 { projectId }` · `404 { error: 'not_found' }` · `422` as above.
- `POST /api/projects/:id/locate` → panel, same `202 { openId }` + polling; `failed` with
  `different_video` when the length differs by more than 0.1 s; `opened` + `sameBytes: false` when
  the length matches but not the fingerprint (relinked; the page says "Linked. It isn't the exact
  same file, check your cuts.").
- `/media/:id/source` serves `.mov` as `video/quicktime`.
- `POST /api/projects/:id/reveal` → Show in Finder.
- `DELETE /api/projects/:id` → `204`; deletes the project folder, never the video.
- `Project.source`: `{ name, folder, state: 'ok' | 'missing' | 'offline', volume? }` so the editor
  can say where the file was.
- `Transcript.errorCode?: 'no_sound'` (status `failed`, `error` "This video has no sound, so
  there's no transcript."): the page shows no Retry and no engine switch.

## 7. Who builds what

| Who | What |
|---|---|
| editor-server | Routes of §6, the panel seam (a closure the app injects into `EditorService`, a fake in tests), `mdfind` lookup + hash check, identity (bookmark + fingerprint; xattr only inside the recordings folder; fix: an xattr whose project points to another existing file → new project), calling `MediaCheck` at open, source state (missing / offline volume). |
| app-ui | The app side: the `NSOpenPanel` behind the seam (save the front app, activate, re-activate it after; starts in the last folder), `CFBundleDocumentTypes` (rank Alternate) + `application(_:open:)` (queued until launch is done), File > Open Video… ⌘O, File > Open Recent (`NSDocumentController`), menu bar Open Video…, Recordings' Open → Play ⌘↓, refusal alerts. |
| editor-media | `MediaCheck.inspect(url)` (readable, video track, decodable, codec, size, fps, HDR, has audio), export of other videos (fps snapped ≤ 60, ≤ 3840 px, HDR → SDR 709 tagged), the no-sound message + code. |
| designer | Home page `/`, header link, drop overlay and states, Open Video… states, missing/offline + Locate…, refusals. |
| qa | Mock server routes, headless e2e of A, B, F and every §4 state (fake panel, fake Spotlight), Swift tests of identity and routes, `scripts/check.sh` green. |
| architect | `docs/editor-api.md` §6 changes; reviews this doc and the code. |
