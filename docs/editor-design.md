# Bubble editor — UX spec

Edit a recording by editing its words. A web page served by Bubble's local server, opened
in the user's browser, that cuts and speeds up parts of a recording without touching the
source file, then downloads the edited video.

Reference: Loom's editor, as a UX comparison.
Code: `web/editor/` (plain HTML/CSS/JS modules, no CDN, no build step, works offline):
`index.html`, `editor.css`, `model.js` (the pure edit model), `api.js` (the only module that
knows the server), `app.js` (the page). Tests: `node --test web/editor/test/model.test.mjs`
and, with `node web/mock-server.mjs` running, `node web/editor/test/e2e.mjs <out-dir>`
(headless Chrome over CDP, no window: 19 checks + screenshots).
API: the architect's contract, `docs/editor-api.md` (§8).

---

## 1. What Loom does (from the reference video)

| Loom | What we keep |
|---|---|
| Video on the left, transcript on the right, timeline across the bottom | Same layout |
| Transcript in paragraphs, a timestamp in the margin of each (`0:24`) | Same, plus the speaker's name (diarization) |
| The word being played: white text on a solid red-orange block | Same, in Bubble's red |
| Removed words: grey text, struck through, on a light grey block; still readable, still selectable | Same |
| Selecting words paints the same range on the timeline (blue fill on the waveform, light blue band on the ruler) | Same |
| Dragging on the timeline selects the words under it | Same |
| Hovering a word shows a thin marker on the timeline at that word | Same, with the time |
| Timeline: kept parts as rounded blue clips over the waveform, removed parts as flat grey waveform in the gaps; red playhead with a head on the ruler | Same |
| "Delete selection" in the timeline bar; "Edits will be saved automatically" / "Saving…" / "Edits saved" next to undo / redo; "Finish" | Delete / Restore / Speed on the selection; the same save status; **Download** instead of Finish |
| Remove filler words, remove silences, overlays, backgrounds, split, insert video, search, version history | Left out of v1 (§9) |

## 2. Principles

1. **The words are the handles.** Everything you can do on the timeline you can do on the
   text, and the two always show the same selection.
2. **Nothing is lost.** Removed parts stay visible (struck through, grey on the timeline)
   and can be restored. The source file is never changed. Undo goes back step by step.
3. **What you see plays.** The player plays the edit: it skips removed parts and speeds
   up or slows down the parts you changed.
4. **No save button.** Every change is saved at once; close the tab, come back, it's there.
5. **One way out.** **Download** makes the edited `.mp4`.

## 3. Layout

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│ ◉◦ Bubble   Demo for Camille ✎          ✓ Edits saved    ↶  ↷    [ ↓ Download ]        │ 56
├──────────────────────────────────────────────────┬────────────────────────────────────┤
│                                                  │ ● Gabriel  0:00                     │
│                                                  │ Hey everybody, uhm, I'm Gabriel,    │
│                    video                         │ I just came back from ~~the~~ ...  │
│                                                  │                                    │
│                                                  │ ● Camille  0:24                     │
│                                                  │ I think there's a few things ...   │
│ ▶  0:24 / 3:12   (4:29 before edits)      1× ⛶  │                                    │
├──────────────────────────────────────────────────┴────────────────────────────────────┤
│ 0:12 selected   [Delete] [Restore] [Speed ▾]                       −  Fit  +          │ 40
│ 0:00      0:50       1:40       2:30       3:20       4:10                             │ 20
│ ╭──────╮ ┄┄┄ ╭───────────╮ ╭──1.5×──╮ ┄┄┄┄ ╭──────────────────────╮                   │ 64
│ ╰──────╯     ╰───────────╯ ╰────────╯      ╰──────────────────────╯                    │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

- **Header** (56 px): Bubble's two-bubble glyph + "Bubble"; the recording's title, editable
  in place (click, type, Return); on the right the save status, Undo, Redo, **Download**.
- **Player** (left, fills the space, video letterboxed on black): controls bar under the
  video: play/pause, `current / edited duration`, the original duration in secondary text
  when it differs ("4:29 before edits"), playback speed (1×, 1.5×, 2×: viewing only, not an
  edit), fullscreen.
- **Transcript** (right, 440 px, its own scroll): paragraphs with the speaker and the start
  time; follows the playhead (auto-scroll) unless the user scrolled it in the last 4 s.
- **Timeline** (bottom, 128 px): the selection bar, the ruler, the clip track with the
  waveform. Zoom: Fit (default, the whole recording) and − / + (⌘− / ⌘+ when the timeline
  has focus); scrolls horizontally when zoomed and follows the playhead.
- Width under 960 px: the transcript goes under the player (stacked), timeline stays at the
  bottom.

## 4. The model the user sees

The recording is one strip of time (source time). Any range of it is in one of three states:

| State | Transcript | Timeline | Plays |
|---|---|---|---|
| **Kept** (normal) | normal text | blue clip, blue waveform | at 1× |
| **Removed** | grey, struck through, light grey block | gap: no clip outline, flat grey waveform | skipped |
| **Sped** (0.5×, 1.25×, 1.5×, 2×) | normal text, a violet dotted underline, a small `1.5×` chip before the first word | violet clip with the rate in a chip on its top edge | at that rate (pitch kept) |

Edits are ranges of source time: removing words removes their time span (and the silence
between two removed words); restoring brings it back; speed sets a rate on it. A newer edit
on a range replaces what was there. Ranges always snap to word edges when made from text,
and to 0.1 s when made on the timeline.

## 5. Interactions

### 5.1 Play and seek
- Space: play / pause (anywhere except while typing the title or a speaker name).
- Click a word: the playhead jumps to its start (playing goes on if it was playing).
- Click on the ruler or an empty spot of the track: the playhead jumps there.
- Drag the playhead's head: scrub.
- ← / →: back / forward 5 s (edited time). Playing skips removed ranges and changes rate in
  sped ranges with no visible stall.
- Joins sound natural (the user's ask, 2026-11-07): the preview fades the sound out over
  30 ms just before a cut and back in over 30 ms after the jump (a Web Audio gain ramp), and
  dips it for 12 ms at a speed change. The downloaded file gets a real crossfade
  (editor-media, export side).
- The current word: white text on a red block (removed words are never current).

### 5.2 Hover
- Hovering a word: a thin vertical marker on the timeline at its start, with its time in a
  small label on the ruler. Hovering the track: the same marker under the pointer.

### 5.3 Select
- **In the text:** press on a word and drag; the selection grows by whole words. Shift-click
  extends. Double-click selects a word, triple-click the paragraph.
- **On the timeline:** press on the track and drag to select a range; drag the selection's
  edges to adjust it.
- **Both ways:** a selection made in one place shows in the other at once: blue block behind
  the words, blue fill over the clips, a light blue band on the ruler.
- Esc, or a click without dragging, clears it (and seeks, per 5.1).

### 5.4 Act on the selection
With a selection, the timeline's left bar shows `0:12 selected` and the actions; a small
floating bar with the same actions sits above the selection in the transcript.

| Action | Key | Does |
|---|---|---|
| **Delete** | ⌫ / Delete | the range becomes Removed |
| **Restore** | ⇧⌫ | the range becomes Kept (shown only if the selection holds a removed or sped part) |
| **Speed ▾** | | menu: 0.5× · 1× (normal) · 1.25× · 1.5× · 2×; the current rate checked |

After an action the selection stays, so a second action (e.g. Speed after Restore) needs no
reselect. Clicking a removed block alone (no drag) seeks to it and offers **Restore** in
the floating bar.

### 5.5 Undo / redo
- ⌘Z / ⇧⌘Z and the header buttons. Every action is one step (title and speaker renames too).
  The history lives as long as the tab; the edits themselves are saved.

### 5.6 Speakers
- Each paragraph starts with the speaker's colored dot and name. Click the name to rename:
  it renames that speaker everywhere. Names default to "Speaker 1", "Speaker 2".
- A new paragraph starts at a speaker change or a pause over 1.5 s.

### 5.7 Download
- **Download** asks Bubble to render the edit, the button shows progress
  ("Exporting 42%"), then the browser downloads `<title> (edited).mp4`. Edits made during
  the export go into the next one. Nothing to edit yet: it downloads the original.

## 6. Save, states, errors

| Case | What shows |
|---|---|
| Saved | `✓ Edits saved` (secondary) |
| Saving (debounced 600 ms after the last change) | `Saving…` |
| Bubble not reachable | `Offline · kept in this browser` (amber); edits are kept in localStorage and sent when Bubble is back; Download disabled with the tooltip "Open Bubble to download" |
| Edits changed elsewhere (another tab saved first: 409) | the page takes the other tab's edits and says "This recording was edited in another tab. You're now seeing the latest version." [OK] |
| Opening a recording with no transcript | **No Transcribe button** (the user's call, 2026-11-07): the server starts it on open with the default engine (Voxtral 3 when a Mistral key is set, else On this Mac). The page only polls (1 s). |
| Transcript queued / running | in the transcript panel: "Getting ready to transcribe…" / "Transcribing…", the engine and where the audio goes from the first answer ("On this Mac · Nothing leaves your Mac." / "Voxtral 3 (Mistral) · The audio is sent to Mistral."), a thin blue bar (sliding while queued, filling with `NN%` while running), the engine's caveat if any ("First time: macOS downloads its speech model…"), "Meanwhile, you can cut and speed up on the timeline.", three shimmering placeholder paragraphs (no motion with reduced motion). The timeline works throughout. |
| Transcript failed | inline: "The transcript didn't work." + the reason, **Retry** (same engine, or the default), and **Use On this Mac instead** / **Add a Mistral API key…** for the other engine; "You can still cut and speed up on the timeline." |
| Transcript panel head | "Transcript", the engine used in secondary text (tooltip: where the audio went), and a ⋯ menu (when ready or failed): **Re-transcribe with Voxtral 3 (Mistral)**, **Re-transcribe with On this Mac** (the current one checked; "needs a key" when Voxtral has none), **Mistral API key…**, and the note "Re-transcribing replaces the words and speaker names. Your cuts and speed changes stay." Adding a key never re-transcribes by itself. |
| Mistral API key popover | a password field + **Save**, "Kept in your macOS Keychain, only sent to Mistral. Re-transcribing with Voxtral sends the audio to Mistral."; "Checking…"; refused: "This key didn't work." (red); unreachable: "Mistral can't be reached. Check your connection and try again."; saved: "Key saved in your Keychain · Remove"; from the environment: "Using MISTRAL_API_KEY from your environment." Opened from Re-transcribe with Voxtral without a key, it re-transcribes once the key is saved. |
| No transcript (only when the video file is missing) | "No transcript" / "The video file is missing, so Bubble can't transcribe it." |
| Many approximate word times (over 20% of words) | one quiet line above the transcript: "Word times are approximate: a cut may be off by a word." |
| Waveform not ready yet (202) | flat placeholder bars; retried every 1 s |
| Video can't load | the player area says "Bubble can't open this recording." |
| Video file gone (404 `source_missing`) | the player area says "The video file is missing." / "It was moved or deleted. Put it back where it was to play and download it; your edits are kept."; transcript and edits stay; Download greyed ("The video file is missing") |
| Transcript stopped because Bubble quit | shown as failed with "Stopped when Bubble quit." and **Retry** |
| Export fails | the button goes back to Download, a line under it: "Export failed. Try again." |

## 7. Look

- Bubble's look: system font (`-apple-system`), light and dark (follows the system), one
  4 px grid, 8 px radii, hairline separators, no heavy shadows.
- Colors: current word **red** (Bubble's record red), selection **blue** (system blue at 22%
  behind text; solid fill at 35% over clips), removed **grey** (`text 45%`, strike, block
  `fill 8%`), speed **violet**, kept clips **blue** outline 1.5 px, playhead **red** 2 px
  with a 10 px head.
- Download is the one filled button (ink on light, white on dark).
- Every icon button has a tooltip with its name and shortcut.

## 8. Data the page needs (now `docs/editor-api.md`, which wins over this summary)

Speed never un-cuts: setting a speed on a range that holds cut parts keeps them cut
(Restore is the only way back).

- `GET /api/projects/:id` → title, video url + duration, waveform peaks, transcript
  (speakers; words with start, end, text, speaker), edits `{ revision, segments: [{start,
  end, rate}] }` (rate 0 = removed; only ranges that differ from 1×).
- `PUT /api/projects/:id/edits` (autosave), `PATCH /api/projects/:id` (title, speakers),
  `POST /api/projects/:id/export` + polling + download url.

## 9. Left out of v1, and why

| Left out | Why |
|---|---|
| Remove filler words / silences in one click | Great follow-up: it's a "select these ranges + Delete"; v1 first nails manual edits |
| Split, insert another video, overlays, backgrounds, captions burn-in | Beyond "cut and speed up my recording" |
| Editing the words themselves (fix a transcript typo) | The text is a handle on the video, not a document |
| Version history | Undo covers the session; the source is never touched, so "restore all" is a select-all + Restore |
| Search in the transcript | ⌘F in the browser finds words already |
