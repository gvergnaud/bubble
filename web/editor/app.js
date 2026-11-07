// Bubble editor: the page. Spec: docs/editor-design.md.
import {
  applyRate, normalize, rateAt, sourceToEdited, editedToSource, editedDuration, playableFrom,
  describeRange, paragraphs, wordsIn, wordAt, formatTime, formatRate, RATES,
} from "./model.js";
import { createApi, projectIdFromLocation } from "./api.js";

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};

const SPEAKER_COLORS = ["#0a84ff", "#ff9f0a", "#30d158", "#ff375f", "#64d2ff", "#bf5af2"];
const ICON_PLAY = '<svg viewBox="0 0 20 20" fill="currentColor"><path d="M6 4.2v11.6c0 .6.6.9 1.1.6l9-5.8c.4-.3.4-.9 0-1.2l-9-5.8C6.6 3.3 6 3.6 6 4.2Z"/></svg>';
const ICON_PAUSE = '<svg viewBox="0 0 20 20" fill="currentColor"><rect x="5" y="4" width="3.5" height="12" rx="1"/><rect x="11.5" y="4" width="3.5" height="12" rx="1"/></svg>';
const ICON_CHECK = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m3.5 8.5 3 3 6-7"/></svg>';
const ICON_CLOUD_OFF = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4.5 12.5h7a3 3 0 0 0 .4-6A4.5 4.5 0 0 0 3.6 7.6 2.5 2.5 0 0 0 4.5 12.5Z"/><path d="m2.5 2.5 11 11"/></svg>';

// ---------- state ----------
const projectId = projectIdFromLocation();
const api = createApi(projectId);
const STORE_KEY = `bubble-editor:${projectId}`;

const S = {
  project: null,
  duration: 0,
  words: [],
  paras: [],
  speakers: [],
  title: "",
  segments: [],
  revision: 0,
  sel: null,            // { start, end } in source seconds
  hoverT: null,
  current: -1,
  history: [],
  future: [],
  viewRate: 1,
  zoom: 1,
  view0: 0,             // left edge of the timeline window, seconds
  save: "saved",        // saved | saving | offline | conflict
  exporting: null,      // null | progress 0..1
  dirty: false,
  userScrollAt: 0,
};

const video = $("video");
const canvas = $("track");
const ctx = canvas.getContext("2d");
let wordSpans = [];
let gapSpans = [];
let colors = {};

// ---------- boot ----------
boot().catch((err) => {
  console.error(err);
  $("title").textContent = "Bubble";
  $("transcript").replaceChildren(el("div", "note", "Bubble isn't reachable. Open Bubble, then reload this page."));
});

async function boot() {
  readColors();
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { readColors(); drawTimeline(); });
  const p = await api.load();
  S.project = p;
  S.duration = p.video?.duration || 0;
  S.title = p.title || "Untitled";
  const t = p.transcript || { status: "none" };
  S.words = (t.words || []).slice().sort((a, b) => a.start - b.start);
  S.speakers = (t.speakers || []).map((s) => ({ ...s }));
  S.paras = paragraphs(S.words);
  S.segments = normalize(p.edits?.segments || []);
  S.revision = p.edits?.revision ?? 0;

  const pending = readLocal();
  if (pending && pending.revision === S.revision) {
    S.segments = normalize(pending.segments);
    S.title = pending.title ?? S.title;
    if (pending.speakers) S.speakers = pending.speakers;
    S.dirty = true;
    scheduleSave(0);
  }

  $("title").textContent = S.title;
  document.title = `${S.title} · Bubble editor`;
  if (p.video.posterUrl) video.poster = p.video.posterUrl;
  video.src = p.video.url;
  video.preservesPitch = true;
  loadWaveform();
  if (t.status === "queued" || t.status === "running") pollTranscript();
  video.addEventListener("loadedmetadata", () => {
    if (!S.duration) S.duration = video.duration;
    paintAll();
  });
  video.addEventListener("error", async () => {
    // A 404 source_missing means the file was moved or deleted (docs/editor-api.md §7).
    let missing = false;
    try {
      const r = await fetch(p.video.url, { headers: { range: "bytes=0-0" } });
      missing = r.status === 404 && (await r.json().catch(() => ({}))).error === "source_missing";
    } catch { /* Bubble not running: the status says so */ }
    const ph = el("div", "placeholder");
    ph.append(el("p", "lead", missing ? "The video file is missing." : "Bubble can't open this recording."));
    if (missing) ph.append(el("p", null, "It was moved or deleted. Put it back where it was to play and download it; your edits are kept."));
    video.replaceWith(ph);
    S.sourceMissing = missing;
    setStatus();
  });
  await loadEngines();
  renderTranscript(t);
  wire();
  applyShot();
  paintAll();
  setStatus();
  requestAnimationFrame(tick);
}

async function loadWaveform() {
  try {
    const w = await api.waveform();
    if (!w) { setTimeout(loadWaveform, 1000); return; }
    S.waveform = w;
    drawTimeline();
  } catch { setTimeout(loadWaveform, 3000); }
}

async function pollTranscript() {
  await new Promise((r) => setTimeout(r, 1000));
  let p;
  try { p = await api.load(); } catch { pollTranscript(); return; }
  const t = p.transcript;
  if (t.status === "queued" || t.status === "running") { renderTranscript(t); pollTranscript(); return; }
  S.words = (t.words || []).slice().sort((a, b) => a.start - b.start);
  S.speakers = (t.speakers || []).map((s) => ({ ...s }));
  S.paras = paragraphs(S.words);
  renderTranscript(t);
  paintAll();
}

// Starts (or restarts) a transcription. The server starts the first one by itself when the
// page loads (docs/editor-api.md §5): the page only calls this for Retry and Re-transcribe.
async function startTranscription(engine) {
  renderTranscript({ status: "queued", progress: 0, engine: engine || null });
  try {
    const res = await api.transcribe(engine);
    renderTranscript(res.transcript || { status: "queued", progress: 0, engine });
    pollTranscript();
  } catch (err) {
    renderTranscript({ status: "failed", engine, error: err.body?.error === "source_missing" ? "The video file is missing." : err.message });
  }
}

let engineList = [];
async function loadEngines() {
  try { engineList = (await api.engines()).engines || []; } catch { /* keep the last list */ }
  return engineList;
}
const engineById = (id) => engineList.find((e) => e.id === id);
const engineLabel = (e) => (!e ? "" : e.local ? "On this Mac" : e.name.replace(/\s*\(Mistral[^)]*\)/, " (Mistral)"));

// Dev and screenshot hook: /edit/demo#sel=10-15&t=12&hover=20&zoom=2&menu=speed
function applyShot() {
  const h = new URLSearchParams(location.hash.slice(1));
  if (h.has("t")) video.currentTime = Number(h.get("t"));
  if (h.has("sel")) { const [a, b] = h.get("sel").split("-").map(Number); S.sel = { start: a, end: b }; }
  if (h.has("words")) { const [a, b] = h.get("words").split("-").map(Number); S.sel = selFromWords(a, b); }
  if (h.has("hover")) S.hoverT = Number(h.get("hover"));
  if (h.has("zoom")) { S.zoom = Number(h.get("zoom")); S.view0 = Math.max(0, (S.sel?.start ?? 0) - 2); clampView(); paintZoom(); }
  if (h.has("menu")) setTimeout(() => { const b = [...document.querySelectorAll(".float .btn")].find((x) => x.textContent.startsWith("Speed")); if (b) openSpeedMenu(b, describeRange(S.segments, S.sel.start, S.sel.end).rate); }, 300);
}

// ---------- history / edits ----------
function snapshot() {
  return { segments: S.segments, title: S.title, speakers: S.speakers.map((s) => ({ ...s })) };
}
function restoreSnapshot(snap) {
  const titleChanged = snap.title !== S.title;
  const speakersChanged = JSON.stringify(snap.speakers) !== JSON.stringify(S.speakers);
  S.segments = snap.segments;
  S.title = snap.title;
  S.speakers = snap.speakers;
  $("title").textContent = S.title;
  if (titleChanged) patchServer({ title: S.title });
  if (speakersChanged) { patchServer({ speakers: S.speakers }); renderSpeakerNames(); }
}
function commit(mutate) {
  S.history.push(snapshot());
  if (S.history.length > 200) S.history.shift();
  S.future = [];
  mutate();
  afterChange();
}
function undo() {
  if (!S.history.length) return;
  S.future.push(snapshot());
  restoreSnapshot(S.history.pop());
  afterChange();
}
function redo() {
  if (!S.future.length) return;
  S.history.push(snapshot());
  restoreSnapshot(S.future.pop());
  afterChange();
}
function afterChange() {
  S.dirty = true;
  writeLocal();
  scheduleSave();
  paintAll();
}

function setRateOnSelection(rate) {
  if (!S.sel) return;
  const { start, end } = S.sel;
  commit(() => { S.segments = applyRate(S.segments, start, end, rate); });
}
const doDelete = () => setRateOnSelection(0);
const doRestore = () => setRateOnSelection(1);

// ---------- save ----------
let saveTimer = 0;
let retryTimer = 0;
function scheduleSave(delay = 600) {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, delay);
  if (S.save !== "offline" && S.save !== "conflict") { S.save = "saving"; setStatus(); }
}
async function save() {
  if (!S.dirty) return;
  const sending = S.segments;
  try {
    const res = await api.saveEdits(S.revision, sending);
    S.revision = res?.revision ?? S.revision + 1;
    if (S.segments === sending) { S.dirty = false; clearLocal(); }
    S.save = S.dirty ? "saving" : "saved";
    if (S.dirty) scheduleSave();
  } catch (err) {
    if (err.status === 409 && err.body?.edits) {
      // another tab saved first: take theirs (docs/editor-api.md §3)
      S.segments = normalize(err.body.edits.segments);
      S.revision = err.body.edits.revision;
      S.dirty = false;
      clearLocal();
      S.save = "saved";
      showConflict();
      paintAll();
    } else if (err.status === 422) {
      S.save = "conflict";
    } else {
      S.save = "offline";
      clearTimeout(retryTimer);
      retryTimer = setTimeout(save, 5000);
    }
  }
  setStatus();
}
function patchServer(fields) {
  api.patch(fields).catch(() => { S.save = "offline"; setStatus(); });
}
function readLocal() {
  try { return JSON.parse(localStorage.getItem(STORE_KEY) || "null"); } catch { return null; }
}
function writeLocal() {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify({ revision: S.revision, segments: S.segments, title: S.title, speakers: S.speakers, at: Date.now() }));
  } catch { /* storage full: the server copy still saves */ }
}
function clearLocal() { try { localStorage.removeItem(STORE_KEY); } catch { /* ignore */ } }

function setStatus() {
  const s = $("status");
  s.classList.toggle("offline", S.save === "offline" || S.save === "conflict");
  if (S.save === "saved") s.innerHTML = `${ICON_CHECK}<span>Edits saved</span>`;
  else if (S.save === "saving") s.innerHTML = `<span>Saving…</span>`;
  else if (S.save === "offline") s.innerHTML = `${ICON_CLOUD_OFF}<span>Offline · kept in this browser</span>`;
  else s.innerHTML = `<span>Not saved</span>`;
  s.title = S.save === "offline" ? "Bubble isn't reachable. Your edits are kept in this browser and sent when Bubble is back." : "";
  $("undo").disabled = !S.history.length;
  $("redo").disabled = !S.future.length;
  const dl = $("download");
  dl.disabled = S.save === "offline" || S.exporting != null || S.sourceMissing;
  dl.title = S.sourceMissing ? "The video file is missing" : S.save === "offline" ? "Open Bubble to download" : "Download the edited video";
  dl.querySelector("span").textContent = S.exporting != null ? `Exporting ${Math.round(S.exporting * 100)}%` : "Download";
}
function showConflict() {
  if (document.querySelector(".banner")) return;
  const b = el("div", "banner");
  b.append(el("span", null, "This recording was edited in another tab. You're now seeing the latest version."));
  const r = el("button", "btn small", "OK");
  r.onclick = () => b.remove();
  b.append(r);
  document.body.append(b);
}

// ---------- export ----------
async function doExport() {
  if (S.exporting != null) return;
  S.exporting = 0;
  setStatus();
  try {
    if (S.dirty) await save();
    const job = await api.startExport();
    for (;;) {
      await new Promise((r) => setTimeout(r, 1000));
      const st = await api.exportStatus(job.id);
      S.exporting = st.progress ?? S.exporting;
      setStatus();
      if (st.status === "done" && st.url) {
        const a = el("a");
        a.href = st.url;
        a.download = `${S.title} (edited).mp4`;
        document.body.append(a);
        a.click();
        a.remove();
        break;
      }
      if (st.status === "failed") throw new Error("export failed");
    }
    S.exporting = null;
    setStatus();
  } catch (err) {
    S.exporting = null;
    setStatus();
    const s = $("status");
    s.classList.add("offline");
    const why = err?.body?.error === "source_missing" ? "The video file is missing." : "Export failed. Try again.";
    s.innerHTML = "";
    s.append(el("span", null, why));
  }
}

// ---------- transcript ----------
function renderTranscript(t) {
  const box = $("transcript");
  box.replaceChildren();
  wordSpans = [];
  gapSpans = [];
  S.transcript = t;
  paintTranscriptHead(t);
  if (t.status === "running" || t.status === "queued") { renderProgress(box, t); return; }
  if (t.status === "failed") { renderFailed(box, t); return; }
  if (t.status === "none" || !S.words.length) {
    const note = el("div", "tstate");
    note.append(el("h3", null, "No transcript"));
    note.append(el("p", null, S.sourceMissing ? "The video file is missing, so Bubble can't transcribe it." : "This recording has no words to show."));
    note.append(el("p", "hint", "You can still cut and speed up on the timeline."));
    box.append(note);
    return;
  }
  const approx = S.words.filter((w) => w.approximate).length;
  if (approx > S.words.length * 0.2) {
    box.append(el("div", "approx", "Word times are approximate: a cut may be off by a word."));
  }
  for (const para of S.paras) {
    const row = el("div", "para");
    const when = el("div", "when", formatTime(para.start));
    when.title = "Play from here";
    when.onclick = () => seek(para.start);
    const body = el("div");
    const who = el("div", "who");
    const dot = el("span", "dot");
    const name = el("span", "name");
    name.contentEditable = "plaintext-only";
    name.spellcheck = false;
    name.dataset.speaker = para.speaker;
    name.title = "Rename this speaker everywhere";
    who.append(dot, name);
    const words = el("div", "words");
    for (let i = para.from; i <= para.to; i++) {
      const w = el("span", "w", S.words[i].text);
      w.dataset.i = i;
      wordSpans[i] = w;
      words.append(w);
      if (i < para.to) {
        const g = el("span", "gap", " ");
        g.dataset.g = i;
        gapSpans[i] = g;
        words.append(g);
      }
    }
    body.append(who, words);
    row.append(when, body);
    box.append(row);
  }
  renderSpeakerNames();
}

// ---------- transcript states (no Transcribe button: the server starts it on open) ----------
const where = (e) => (!e ? "" : e.local ? "Nothing leaves your Mac." : "The audio is sent to Mistral.");

function paintTranscriptHead(t) {
  const e = engineById(t.engine);
  $("engineName").textContent = t.status === "ready" && e ? engineLabel(e) : "";
  $("engineName").title = e ? where(e) : "";
  $("tmenu").hidden = !(t.status === "ready" || t.status === "failed");
}

function renderProgress(box, t) {
  const e = engineById(t.engine);
  const wrap = el("div", "tstate");
  const running = t.status === "running" && t.progress > 0;
  wrap.append(el("h3", null, t.status === "queued" ? "Getting ready to transcribe…" : "Transcribing…"));
  if (e) wrap.append(el("p", "sub", `${engineLabel(e)} · ${where(e)}`));
  const bar = el("div", "bar" + (running ? "" : " busy"));
  const fill = el("div", "fill");
  if (running) fill.style.width = `${Math.max(3, Math.round(t.progress * 100))}%`;
  bar.append(fill);
  wrap.append(bar);
  if (running) wrap.append(el("p", "pct", `${Math.round(t.progress * 100)}%`));
  if (e?.why && e.available) wrap.append(el("p", "sub", e.why));
  wrap.append(el("p", "hint", "Meanwhile, you can cut and speed up on the timeline."));
  box.append(wrap);
  for (let p = 0; p < 3; p++) {
    const g = el("div", "ghost");
    g.append(el("div", "skeleton who-sk"));
    for (let i = 0; i < 3 + (p % 2); i++) { const k = el("div", "skeleton"); k.style.width = `${[92, 84, 96, 58][i]}%`; g.append(k); }
    box.append(g);
  }
  if (!engineList.length) loadEngines().then(() => { if (S.transcript === t) { box.replaceChildren(); renderProgress(box, t); } });
}

function renderFailed(box, t) {
  const wrap = el("div", "tstate fail");
  wrap.append(el("h3", null, "The transcript didn't work."));
  if (t.error) wrap.append(el("p", "sub", t.error));
  const row = el("div", "row");
  const retry = el("button", "btn primary", "Retry");
  retry.onclick = () => startTranscription(t.engine && engineById(t.engine)?.available ? t.engine : undefined);
  row.append(retry);
  wrap.append(row);
  wrap.append(el("p", "hint", "You can still cut and speed up on the timeline."));
  box.append(wrap);
  loadEngines().then((list) => {
    for (const e of list) {
      if (e.id === t.engine) continue;
      const b = el("button", "btn", e.available ? `Use ${engineLabel(e)} instead` : `Add a Mistral API key…`);
      if (!e.available && e.local) continue;
      b.onclick = () => (e.available ? startTranscription(e.id) : openKeyPopover($("tmenu"), e.id));
      row.append(b);
    }
  });
}

// ⋯ menu at the top of the transcript: Re-transcribe with… and the Mistral key.
async function openTranscriptMenu(anchor) {
  closeMenu();
  const list = await loadEngines();
  menu = el("div", "menu");
  const current = S.transcript?.engine;
  for (const e of list) {
    const b = el("button");
    const name = el("span", null, `Re-transcribe with ${engineLabel(e)}`);
    name.style.flex = "1";
    b.append(el("span", "check"), name, el("span", "hint", e.id === current ? "current" : e.available ? "" : "needs a key"));
    if (e.id === current) b.querySelector(".check").innerHTML = ICON_CHECK;
    b.title = e.available ? where(e) + (e.why ? ` ${e.why}` : "") : e.why || "";
    if (!e.available && e.local) b.disabled = true;
    b.onclick = () => { closeMenu(); e.available ? startTranscription(e.id) : openKeyPopover(anchor, e.id); };
    menu.append(b);
  }
  menu.append(el("div", "menu-sep"));
  const key = el("button");
  const kn = el("span", null, "Mistral API key…");
  kn.style.flex = "1";
  key.append(el("span", "check"), kn);
  key.onclick = () => { closeMenu(); openKeyPopover(anchor); };
  menu.append(key);
  menu.append(el("p", "menu-note", "Re-transcribing replaces the words and speaker names. Your cuts and speed changes stay."));
  document.body.append(menu);
  const r = anchor.getBoundingClientRect();
  menu.style.left = `${Math.max(8, r.right - menu.offsetWidth)}px`;
  menu.style.top = `${r.bottom + 4}px`;
}

// The Mistral key in a popover; `thenEngine`: re-transcribe with it once the key is saved.
function openKeyPopover(anchor, thenEngine) {
  closeMenu();
  menu = el("div", "menu pop");
  menu.append(el("h4", null, "Mistral API key"));
  const body = el("div", "keybox");
  menu.append(body);
  document.body.append(menu);
  const place = () => {
    const r = anchor.getBoundingClientRect();
    menu.style.left = `${Math.max(8, r.right - menu.offsetWidth)}px`;
    menu.style.top = `${r.bottom + 4}px`;
  };
  const paint = async () => {
    body.replaceChildren();
    let s = { mistralKey: "none" };
    try { s = await api.settings(); } catch { /* offline: the form still shows */ }
    if (s.mistralKey === "environment") body.append(el("p", "keymsg", "Using MISTRAL_API_KEY from your environment."));
    else if (s.mistralKey === "keychain") {
      const line = el("p", "keyline");
      line.append(document.createTextNode("Key saved in your Keychain · "));
      const rm = el("button", "link", "Remove");
      rm.onclick = async () => { try { await api.deleteKey(); await loadEngines(); paint(); } catch { /* offline */ } };
      line.append(rm);
      body.append(line);
    } else renderKeyForm(body, async () => {
      await loadEngines();
      if (thenEngine && engineById(thenEngine)?.available) { closeMenu(); startTranscription(thenEngine); }
      else paint();
    });
    place();
    body.querySelector("input")?.focus();
  };
  menu.addEventListener("pointerdown", (e) => e.stopPropagation());
  paint();
}

function renderKeyForm(box, onSaved) {
  const form = el("form", "keyform");
  const input = el("input");
  input.type = "password";
  input.placeholder = "Mistral API key";
  input.autocomplete = "off";
  input.spellcheck = false;
  const save = el("button", "btn", "Save");
  save.type = "submit";
  const msg = el("p", "keymsg", "Kept in your macOS Keychain, only sent to Mistral. Re-transcribing with Voxtral sends the audio to Mistral.");
  form.append(input, save);
  box.append(form, msg);
  form.onsubmit = async (e) => {
    e.preventDefault();
    const key = input.value.trim();
    if (!key) return;
    save.disabled = true;
    input.disabled = true;
    msg.className = "keymsg";
    msg.textContent = "Checking…";
    try {
      await api.saveKey(key);
      msg.textContent = "Key saved.";
      onSaved?.();
    } catch (err) {
      save.disabled = false;
      input.disabled = false;
      msg.className = "keymsg bad";
      msg.textContent = err.body?.error === "invalid_key" ? "This key didn't work."
        : err.status === 502 ? "Mistral can't be reached. Check your connection and try again."
        : "Bubble couldn't save the key.";
      input.select();
    }
  };
}

function speakerOf(id) {
  return S.speakers.find((s) => s.id === id) || { id, name: String(id) };
}
function renderSpeakerNames() {
  for (const n of document.querySelectorAll(".who .name")) {
    if (document.activeElement === n) continue;
    const sp = speakerOf(n.dataset.speaker);
    n.textContent = sp.name;
    const idx = Math.max(0, S.speakers.findIndex((s) => s.id === sp.id));
    n.previousElementSibling.style.background = SPEAKER_COLORS[idx % SPEAKER_COLORS.length];
  }
}

function paintWords() {
  const sel = S.sel ? wordsIn(S.words, S.sel.start, S.sel.end) : null;
  for (const c of document.querySelectorAll(".transcript .chip")) c.remove();
  let prevRate = 1;
  for (let i = 0; i < wordSpans.length; i++) {
    const w = S.words[i], span = wordSpans[i];
    if (!span) continue;
    const r = rateAt(S.segments, (w.start + w.end) / 2);
    const inSel = sel && i >= sel.from && i <= sel.to;
    span.className = "w" + (r === 0 ? " removed" : r !== 1 ? " sped" : "") + (inSel ? " sel" : "") + (i === S.current ? " current" : "");
    if (r !== 1 && r !== 0 && r !== prevRate) {
      const chip = el("span", "chip", formatRate(r));
      chip.title = `Plays at ${formatRate(r)}`;
      span.before(chip);
    }
    prevRate = r;
    const g = gapSpans[i];
    if (g) {
      const next = S.words[i + 1];
      const gr = rateAt(S.segments, (w.end + next.start) / 2);
      const bothSel = inSel && sel && i + 1 <= sel.to;
      g.className = "gap" + (gr === 0 && r === 0 ? " removed" : "") + (bothSel ? " sel" : "");
    }
  }
}

function setCurrentWord(i) {
  if (i === S.current) return;
  const old = wordSpans[S.current];
  if (old) old.classList.remove("current");
  S.current = i;
  const span = wordSpans[i];
  if (span) {
    span.classList.add("current");
    if (!video.paused && performance.now() - S.userScrollAt > 4000) {
      const box = $("transcript").getBoundingClientRect();
      const r = span.getBoundingClientRect();
      if (r.top < box.top + 40 || r.bottom > box.bottom - 40) span.scrollIntoView({ block: "center", behavior: "smooth" });
    }
  }
}

// ---------- floating bar + actions ----------
function actionButtons(compact) {
  const frag = [];
  if (!S.sel) return frag;
  const d = describeRange(S.segments, S.sel.start, S.sel.end);
  const del = el("button", "btn small" + (compact ? "" : " danger"), "Delete");
  del.title = "Delete  ⌫";
  del.disabled = d.allRemoved;
  del.onclick = doDelete;
  frag.push(del);
  if (d.hasEdits) {
    const res = el("button", "btn small", "Restore");
    res.title = "Restore  ⇧⌫";
    res.onclick = doRestore;
    frag.push(res);
  }
  const sp = el("button", "btn small", d.rate && d.rate !== 1 && d.rate !== 0 ? `Speed ${formatRate(d.rate)} ▾` : "Speed ▾");
  sp.title = "Play this part faster or slower";
  sp.onclick = (e) => { e.stopPropagation(); openSpeedMenu(sp, d.rate); };
  frag.push(sp);
  return frag;
}

function paintActions() {
  const info = $("selinfo");
  const actions = $("actions");
  if (S.sel) {
    info.textContent = `${formatTime(S.sel.end - S.sel.start) === "0:00" ? `${(S.sel.end - S.sel.start).toFixed(1)} s` : formatTime(S.sel.end - S.sel.start)} selected`;
    actions.replaceChildren(...actionButtons(false));
  } else {
    info.textContent = "";
    const hint = el("span", "hint", S.words.length ? "Select words or drag on the timeline to cut or speed up a part" : "Drag on the timeline to cut or speed up a part");
    actions.replaceChildren(hint);
  }
  placeFloat();
}

let floatBar = null;
function placeFloat() {
  floatBar?.remove();
  floatBar = null;
  if (!S.sel || dragging) return;
  const range = wordsIn(S.words, S.sel.start, S.sel.end);
  if (!range) return;
  const first = wordSpans[range.from];
  if (!first) return;
  const box = $("transcript");
  const b = box.getBoundingClientRect();
  const r = first.getBoundingClientRect();
  floatBar = el("div", "float");
  floatBar.append(...actionButtons(true));
  box.append(floatBar);
  const top = r.top - b.top + box.scrollTop - 40;
  const left = Math.min(Math.max(8, r.left - b.left + box.scrollLeft), box.clientWidth - floatBar.offsetWidth - 8);
  floatBar.style.top = `${Math.max(4 + box.scrollTop, top)}px`;
  floatBar.style.left = `${left}px`;
  floatBar.addEventListener("pointerdown", (e) => e.stopPropagation());
}

let menu = null;
function closeMenu() { menu?.remove(); menu = null; }
function openSpeedMenu(anchor, current) {
  closeMenu();
  menu = el("div", "menu");
  const label = { 0.5: "Slower", 1: "Normal", 2: "Faster" };
  for (const r of RATES) {
    const b = el("button");
    const check = el("span", "check");
    if (current === r) check.innerHTML = ICON_CHECK;
    const name = el("span", null, formatRate(r));
    name.style.flex = "1";
    b.append(check, name, el("span", "hint", label[r] || ""));
    b.onclick = () => { closeMenu(); setRateOnSelection(r); };
    menu.append(b);
  }
  document.body.append(menu);
  const r = anchor.getBoundingClientRect();
  const h = menu.offsetHeight;
  const below = r.bottom + 4 + h < innerHeight;
  menu.style.left = `${Math.min(r.left, innerWidth - menu.offsetWidth - 8)}px`;
  menu.style.top = `${below ? r.bottom + 4 : r.top - h - 4}px`;
}

// ---------- timeline ----------
function readColors() {
  const cs = getComputedStyle(document.documentElement);
  for (const k of ["ink", "dim", "faint", "line", "red", "blue", "blue-sel", "blue-fill", "violet", "violet-tint", "wave", "wave-removed", "track", "bg"]) {
    colors[k] = cs.getPropertyValue(`--${k}`).trim();
  }
}

const RULER = 22;
function span() { return S.duration / S.zoom; }
function clampView() { S.view0 = Math.min(Math.max(0, S.view0), Math.max(0, S.duration - span())); }
function tToX(t, w) { return ((t - S.view0) / span()) * w; }
function xToT(x, w) { return Math.min(S.duration, Math.max(0, S.view0 + (x / w) * span())); }

function niceStep(secondsPerPx) {
  const target = secondsPerPx * 90;
  for (const s of [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]) if (s >= target) return s;
  return 7200;
}

function roundRect(x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** Runs of the timeline with one rate each, covering [0, duration]. */
function runs() {
  const out = [];
  let t = 0;
  for (const s of S.segments) {
    if (s.start > t) out.push({ start: t, end: s.start, rate: 1 });
    out.push({ ...s });
    t = s.end;
  }
  if (t < S.duration) out.push({ start: t, end: S.duration, rate: 1 });
  return out;
}

function drawTimeline() {
  if (!S.duration) return;
  const dpr = devicePixelRatio || 1;
  const cw = canvas.clientWidth, ch = canvas.clientHeight;
  if (canvas.width !== Math.round(cw * dpr) || canvas.height !== Math.round(ch * dpr)) {
    canvas.width = Math.round(cw * dpr);
    canvas.height = Math.round(ch * dpr);
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cw, ch);
  const w = cw;
  const top = RULER + 4, h = ch - top;
  const mid = top + h / 2;

  // ruler
  const step = niceStep(span() / w);
  ctx.font = "11px -apple-system, BlinkMacSystemFont, sans-serif";
  ctx.textBaseline = "middle";
  if (S.sel) {
    ctx.fillStyle = colors["blue-sel"];
    const a = tToX(S.sel.start, w), b = tToX(S.sel.end, w);
    roundRect(a, 3, Math.max(2, b - a), RULER - 6, 4);
    ctx.fill();
  }
  const first = Math.floor(S.view0 / step) * step;
  for (let t = first; t <= S.view0 + span() + step; t += step) {
    const x = tToX(t, w);
    if (x < -40 || x > w + 40) continue;
    ctx.fillStyle = colors.faint;
    ctx.fillRect(Math.round(x), RULER - 5, 1, 5);
    for (let k = 1; k < 4; k++) {
      const xs = tToX(t + (step * k) / 4, w);
      ctx.fillRect(Math.round(xs), RULER - 3, 1, 3);
    }
    ctx.fillStyle = colors.dim;
    if (x + 4 < w - 30) ctx.fillText(formatTime(t), x + 4, RULER / 2 - 1);
  }

  // track background
  ctx.fillStyle = colors.track;
  roundRect(0, top, w, h, 8);
  ctx.fill();

  // waveform
  const peaks = S.waveform?.peaks || [];
  const pps = S.waveform?.peaksPerSecond || 0;
  const colW = 2, gapW = 1;
  for (let x = 0; x < w; x += colW + gapW) {
    const t0 = xToT(x, w), t1 = xToT(x + colW + gapW, w);
    let amp = 0.08;
    if (pps && peaks.length) {
      const i0 = Math.floor(t0 * pps), i1 = Math.max(i0 + 1, Math.ceil(t1 * pps));
      let m = 0;
      for (let i = i0; i < i1 && i < peaks.length; i++) m = Math.max(m, peaks[i]);
      amp = Math.max(0.05, Math.sqrt(m / 255));
    }
    const r = rateAt(S.segments, (t0 + t1) / 2);
    let hh = amp * (h - 16);
    if (r === 0) { ctx.fillStyle = colors["wave-removed"]; hh *= 0.35; }
    else ctx.fillStyle = r === 1 ? colors.wave : colors.violet;
    ctx.globalAlpha = r === 0 ? 1 : 0.85;
    ctx.fillRect(x, mid - hh / 2, colW, Math.max(1, hh));
  }
  ctx.globalAlpha = 1;

  // clips (kept and sped runs)
  ctx.lineWidth = 1.5;
  for (const run of runs()) {
    if (run.rate === 0) continue;
    const a = tToX(run.start, w), b = tToX(run.end, w);
    if (b < 0 || a > w) continue;
    ctx.strokeStyle = run.rate === 1 ? colors.blue : colors.violet;
    roundRect(a + 1, top + 1, Math.max(2, b - a - 2), h - 2, 7);
    ctx.stroke();
    if (run.rate !== 1) {
      const label = formatRate(run.rate);
      ctx.font = "600 10px -apple-system, BlinkMacSystemFont, sans-serif";
      const tw = ctx.measureText(label).width + 10;
      if (b - a > tw + 8) {
        ctx.fillStyle = colors.violet;
        roundRect(a + 6, top + 5, tw, 15, 4);
        ctx.fill();
        ctx.fillStyle = "#fff";
        ctx.fillText(label, a + 11, top + 13);
      }
      ctx.font = "11px -apple-system, BlinkMacSystemFont, sans-serif";
    }
  }

  // selection
  if (S.sel) {
    const a = tToX(S.sel.start, w), b = tToX(S.sel.end, w);
    ctx.fillStyle = colors["blue-fill"];
    roundRect(a, top, Math.max(2, b - a), h, 6);
    ctx.fill();
    ctx.fillStyle = colors.blue;
    roundRect(a - 2, top + h / 2 - 12, 4, 24, 2); ctx.fill();
    roundRect(b - 2, top + h / 2 - 12, 4, 24, 2); ctx.fill();
  }

  // hover marker
  if (S.hoverT != null && !dragging) {
    const x = Math.round(tToX(S.hoverT, w)) + 0.5;
    ctx.strokeStyle = colors.blue;
    ctx.globalAlpha = 0.6;
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(x, 2); ctx.lineTo(x, ch); ctx.stroke();
    ctx.globalAlpha = 1;
  }

  // playhead
  const px = Math.round(tToX(video.currentTime || 0, w));
  if (px >= -6 && px <= w + 6) {
    ctx.fillStyle = colors.red;
    ctx.fillRect(px - 1, 6, 2, ch - 6);
    ctx.beginPath();
    ctx.moveTo(px - 6, 2); ctx.lineTo(px + 6, 2); ctx.lineTo(px + 6, 8); ctx.lineTo(px, 13); ctx.lineTo(px - 6, 8);
    ctx.closePath();
    ctx.fill();
  }
}

// ---------- player ----------
function seek(t) {
  video.currentTime = Math.min(Math.max(0, t), S.duration);
  paintClock();
  drawTimeline();
}
function togglePlay() {
  if (video.paused) {
    const from = playableFrom(S.segments, video.currentTime);
    if (from >= S.duration - 0.05) seek(playableFrom(S.segments, 0));
    video.play().catch(() => {});
  } else video.pause();
}
function paintClock() {
  const t = video.currentTime || 0;
  const total = editedDuration(S.segments, S.duration);
  const time = $("time");
  time.textContent = `${formatTime(sourceToEdited(S.segments, t))} / ${formatTime(total)}`;
  if (Math.abs(total - S.duration) > 0.5) {
    const o = el("span", "orig", `${formatTime(S.duration)} before edits`);
    time.append(o);
  }
  $("play").innerHTML = video.paused ? ICON_PLAY : ICON_PAUSE;
  $("play").title = video.paused ? "Play  Space" : "Pause  Space";
}

// ---------- natural joins: duck the audio around jumps (Web Audio gain ramps) ----------
// Jumping over a cut is a hard splice; a 30 ms fade out before it and a 30 ms fade in after
// hides the click. Speed boundaries get a shorter dip. The export does a real crossfade.
const FADE = 0.03;
const DIP = 0.012;
let actx = null, gainNode = null, jumping = false;

function ensureAudio() {
  if (!actx && window.AudioContext) {
    try {
      actx = new AudioContext();
      gainNode = actx.createGain();
      actx.createMediaElementSource(video).connect(gainNode).connect(actx.destination);
    } catch { actx = null; gainNode = null; }
  }
  actx?.resume?.().catch(() => {});
}
function fadeTo(value, seconds) {
  if (!gainNode) return;
  const g = gainNode.gain, now = actx.currentTime;
  g.cancelScheduledValues(now);
  g.setValueAtTime(g.value, now);
  g.linearRampToValueAtTime(value, now + Math.max(0.004, seconds));
}
function nextCut(t) {
  for (const s of S.segments) if (s.rate === 0 && s.start >= t) return s;
  return null;
}
/** Fade out over `lead` seconds (real time), then jump to the next played time. */
function duckedJump(from, lead) {
  jumping = true;
  video.dataset.ducks = String(Number(video.dataset.ducks || 0) + 1);
  fadeTo(0, lead);
  setTimeout(() => {
    const to = playableFrom(S.segments, from);
    if (to >= S.duration - 0.05) { video.pause(); video.currentTime = S.duration; jumping = false; fadeTo(1, FADE); }
    else video.currentTime = to; // the fade in happens on "seeked"
  }, lead * 1000);
}

let lastFrameT = -1;
function tick() {
  const t = video.currentTime || 0;
  if (!video.paused && !jumping) {
    const r = rateAt(S.segments, t);
    if (r === 0) duckedJump(t, 0.008); // landed inside a cut (seek, slow frame): short duck
    else {
      const want = r * S.viewRate;
      if (video.playbackRate !== want) {
        fadeTo(0.15, DIP);
        setTimeout(() => { video.playbackRate = want; fadeTo(1, DIP); }, DIP * 1000);
      }
      const cut = nextCut(t);
      if (cut) {
        const left = (cut.start - t) / (video.playbackRate || 1);
        if (left <= FADE + 0.017) duckedJump(cut.start, Math.max(0.008, left));
      }
    }
    // follow the playhead when zoomed
    if (S.zoom > 1 && (t > S.view0 + span() * 0.95 || t < S.view0)) { S.view0 = t - span() * 0.1; clampView(); }
  }
  if (t !== lastFrameT || !video.paused) {
    lastFrameT = t;
    setCurrentWord(rateAt(S.segments, t) === 0 ? -1 : wordAt(S.words, t));
    paintClock();
    drawTimeline();
  }
  requestAnimationFrame(tick);
}

function paintAll() {
  paintWords();
  paintActions();
  paintClock();
  drawTimeline();
  setStatus();
}

// ---------- interactions ----------
let dragging = null; // { kind: 'words'|'range'|'edge'|'scrub', ... }

function setSel(sel) {
  if (sel && sel.end - sel.start < 0.05) sel = null;
  S.sel = sel;
  paintWords();
  paintActions();
  drawTimeline();
}
function selFromWords(a, b) {
  const i = Math.min(a, b), j = Math.max(a, b);
  return { start: S.words[i].start, end: S.words[j].end };
}
function wordIndexAt(x, y) {
  const n = document.elementFromPoint(x, y);
  const w = n?.closest?.(".w");
  if (w) return Number(w.dataset.i);
  const g = n?.closest?.(".gap");
  if (g) return Number(g.dataset.g);
  return null;
}

function wire() {
  const box = $("transcript");

  // words: click seeks, drag selects, shift-click extends, double/triple click
  box.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    const w = e.target.closest(".w");
    if (!w) return;
    e.preventDefault();
    closeMenu();
    const i = Number(w.dataset.i);
    if (e.shiftKey && S.sel) {
      const cur = wordsIn(S.words, S.sel.start, S.sel.end);
      const anchor = cur ? (i < cur.from ? cur.to : cur.from) : i;
      setSel(selFromWords(anchor, i));
      return;
    }
    if (e.detail === 2) { setSel(selFromWords(i, i)); return; }
    if (e.detail >= 3) {
      const p = S.paras.find((p) => i >= p.from && i <= p.to);
      if (p) setSel(selFromWords(p.from, p.to));
      return;
    }
    dragging = { kind: "words", anchor: i, focus: i, x: e.clientX, y: e.clientY, moved: false };
    box.setPointerCapture(e.pointerId);
  });
  box.addEventListener("pointermove", (e) => {
    if (dragging?.kind === "words") {
      if (Math.hypot(e.clientX - dragging.x, e.clientY - dragging.y) > 4) dragging.moved = true;
      if (!dragging.moved) return;
      const i = wordIndexAt(e.clientX, e.clientY);
      if (i != null && i !== dragging.focus) dragging.focus = i;
      S.sel = selFromWords(dragging.anchor, dragging.focus);
      paintWords();
      drawTimeline();
      $("selinfo").textContent = `${formatTime(S.sel.end - S.sel.start)} selected`;
      return;
    }
    const w = e.target.closest?.(".w");
    const t = w ? S.words[Number(w.dataset.i)].start : null;
    if (t !== S.hoverT) { S.hoverT = t; drawTimeline(); }
  });
  box.addEventListener("pointerup", () => {
    if (dragging?.kind !== "words") return;
    const d = dragging;
    dragging = null;
    if (!d.moved) {
      setSel(null);
      seek(S.words[d.anchor].start);
    } else setSel(selFromWords(d.anchor, d.focus));
  });
  box.addEventListener("pointerleave", () => { if (!dragging) { S.hoverT = null; drawTimeline(); } });
  box.addEventListener("wheel", () => { S.userScrollAt = performance.now(); }, { passive: true });
  box.addEventListener("scroll", () => { if (floatBar && S.sel) placeFloat(); }, { passive: true });

  // speaker names
  box.addEventListener("focusout", (e) => {
    const n = e.target.closest?.(".name");
    if (!n) return;
    const id = n.dataset.speaker;
    const name = n.textContent.trim();
    const sp = speakerOf(id);
    if (!name || name === sp.name) { n.textContent = sp.name; return; }
    commit(() => {
      const list = S.speakers.some((s) => s.id === id) ? S.speakers : [...S.speakers, { id, name }];
      S.speakers = list.map((s) => (s.id === id ? { ...s, name } : { ...s }));
    });
    patchServer({ speakers: S.speakers });
    renderSpeakerNames();
  });
  box.addEventListener("keydown", (e) => {
    if (e.target.closest?.(".name") && (e.key === "Enter" || e.key === "Escape")) {
      e.preventDefault();
      if (e.key === "Escape") e.target.textContent = speakerOf(e.target.dataset.speaker).name;
      e.target.blur();
    }
  });

  // title
  const title = $("title");
  title.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === "Escape") {
      e.preventDefault();
      if (e.key === "Escape") title.textContent = S.title;
      title.blur();
    }
  });
  title.addEventListener("blur", () => {
    const v = title.textContent.trim();
    if (!v || v === S.title) { title.textContent = S.title; return; }
    commit(() => { S.title = v; });
    document.title = `${S.title} · Bubble editor`;
    patchServer({ title: S.title });
  });

  // timeline
  canvas.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 || !S.duration) return;
    closeMenu();
    canvas.setPointerCapture(e.pointerId);
    const w = canvas.clientWidth;
    const x = e.offsetX, t = xToT(x, w);
    const px = tToX(video.currentTime, w);
    if (e.offsetY < RULER || Math.abs(x - px) < 5 && e.offsetY < RULER + 10) {
      dragging = { kind: "scrub" };
      seek(t);
      return;
    }
    if (S.sel) {
      const a = tToX(S.sel.start, w), b = tToX(S.sel.end, w);
      if (Math.abs(x - a) < 6) { dragging = { kind: "edge", fixed: S.sel.end }; return; }
      if (Math.abs(x - b) < 6) { dragging = { kind: "edge", fixed: S.sel.start }; return; }
    }
    if (e.shiftKey && S.sel) {
      const fixed = Math.abs(t - S.sel.start) < Math.abs(t - S.sel.end) ? S.sel.end : S.sel.start;
      dragging = { kind: "edge", fixed };
      setSel(orderSel(fixed, snap(t)));
      return;
    }
    dragging = { kind: "range", anchor: snap(t), x, moved: false };
  });
  canvas.addEventListener("pointermove", (e) => {
    const w = canvas.clientWidth;
    const t = xToT(e.offsetX, w);
    if (!dragging) {
      S.hoverT = t;
      const px = tToX(video.currentTime, w);
      const near = S.sel && (Math.abs(e.offsetX - tToX(S.sel.start, w)) < 6 || Math.abs(e.offsetX - tToX(S.sel.end, w)) < 6);
      canvas.style.cursor = e.offsetY < RULER || Math.abs(e.offsetX - px) < 5 ? "ew-resize" : near ? "col-resize" : "text";
      drawTimeline();
      return;
    }
    if (dragging.kind === "scrub") { seek(t); return; }
    if (dragging.kind === "edge") { S.sel = orderSel(dragging.fixed, snap(t)); paintWords(); drawTimeline(); return; }
    if (dragging.kind === "range") {
      if (Math.abs(e.offsetX - dragging.x) > 3) dragging.moved = true;
      if (dragging.moved) { S.sel = orderSel(dragging.anchor, snap(t)); paintWords(); drawTimeline(); }
    }
  });
  canvas.addEventListener("pointerup", (e) => {
    const d = dragging;
    dragging = null;
    if (!d) return;
    if (d.kind === "range" && !d.moved) { setSel(null); seek(xToT(e.offsetX, canvas.clientWidth)); return; }
    setSel(S.sel);
  });
  canvas.addEventListener("pointerleave", () => { if (!dragging) { S.hoverT = null; drawTimeline(); } });
  canvas.addEventListener("wheel", (e) => {
    if (e.ctrlKey) { e.preventDefault(); zoomBy(e.deltaY < 0 ? 2 : 0.5, xToT(e.offsetX, canvas.clientWidth)); return; }
    if (S.zoom <= 1) return;
    e.preventDefault();
    const dx = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
    S.view0 += (dx / canvas.clientWidth) * span();
    clampView();
    drawTimeline();
  }, { passive: false });

  $("zoomIn").onclick = () => zoomBy(2);
  $("zoomOut").onclick = () => zoomBy(0.5);
  $("zoomFit").onclick = () => { S.zoom = 1; S.view0 = 0; paintZoom(); drawTimeline(); };

  // header + player
  $("tmenu").onclick = (e) => { e.stopPropagation(); menu ? closeMenu() : openTranscriptMenu($("tmenu")); };
  $("undo").onclick = undo;
  $("redo").onclick = redo;
  $("download").onclick = doExport;
  $("play").onclick = togglePlay;
  video.addEventListener("click", togglePlay);
  video.addEventListener("play", () => { ensureAudio(); if (!jumping) fadeTo(1, 0.01); paintClock(); });
  video.addEventListener("seeked", () => { if (jumping) { jumping = false; fadeTo(1, FADE); } });
  video.addEventListener("pause", paintClock);
  $("viewRate").onclick = () => {
    const list = [1, 1.5, 2];
    S.viewRate = list[(list.indexOf(S.viewRate) + 1) % list.length];
    $("viewRate").textContent = formatRate(S.viewRate);
  };
  $("fullscreen").onclick = () => video.requestFullscreen?.();

  document.addEventListener("pointerdown", (e) => { if (menu && !menu.contains(e.target)) closeMenu(); });
  addEventListener("pagehide", () => {
    if (S.dirty) api.saveEdits(S.revision, S.segments, true).catch(() => {});
  });
  addEventListener("resize", () => { drawTimeline(); placeFloat(); });

  document.addEventListener("keydown", (e) => {
    const editing = e.target.isContentEditable || /INPUT|TEXTAREA/.test(e.target.tagName);
    if (editing) return;
    const mod = e.metaKey || e.ctrlKey;
    if (mod && e.key.toLowerCase() === "z") { e.preventDefault(); e.shiftKey ? redo() : undo(); return; }
    if (mod && (e.key === "=" || e.key === "+") && document.activeElement === canvas) { e.preventDefault(); zoomBy(2); return; }
    if (mod && e.key === "-" && document.activeElement === canvas) { e.preventDefault(); zoomBy(0.5); return; }
    if (mod) return;
    if (e.key === " ") { e.preventDefault(); togglePlay(); return; }
    if ((e.key === "Backspace" || e.key === "Delete") && S.sel) { e.preventDefault(); e.shiftKey ? doRestore() : doDelete(); return; }
    if (e.key === "Escape") { if (menu) closeMenu(); else setSel(null); return; }
    if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
      e.preventDefault();
      const e0 = sourceToEdited(S.segments, video.currentTime) + (e.key === "ArrowLeft" ? -5 : 5);
      seek(editedToSource(S.segments, S.duration, e0));
    }
  });
}

function snap(t) { return Math.round(t * 10) / 10; }
function orderSel(a, b) { return { start: Math.min(a, b), end: Math.max(a, b) }; }

function zoomBy(f, around) {
  const center = around ?? (S.sel ? (S.sel.start + S.sel.end) / 2 : video.currentTime);
  const z = Math.min(64, Math.max(1, S.zoom * f));
  if (z === S.zoom) return;
  const ratio = (center - S.view0) / span();
  S.zoom = z;
  S.view0 = center - ratio * span();
  clampView();
  paintZoom();
  drawTimeline();
}
function paintZoom() {
  $("zoomFit").classList.toggle("on", S.zoom === 1);
  $("zoomOut").disabled = S.zoom === 1;
}
