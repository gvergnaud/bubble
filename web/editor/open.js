// Opening a video in the editor from the page (docs/editor-open-video.md §3 A, B):
// Open Video… asks Bubble for its open panel; a dropped file is proven by hashes and found on
// the Mac by Bubble. The page never sends a path. Shared by the home page and the editor.
import { openApi } from "./api.js";

const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};

export const PLAYABLE = /\.(mp4|mov|m4v)$/i;
const VIDEO_TYPES = /^video\//;
const MB = 1024 * 1024;

/** The sentence for a refusal (§4). */
export function refusalText(err) {
  const code = err?.error || err?.body?.error;
  const message = err?.message || err?.body?.message;
  if (code === "no_video") return "This file has no video.";
  if (code === "different_video") return "This video is a different length, so your edits wouldn't line up.";
  if (code === "unsupported_format") return message || "Bubble can't open this video. It edits MP4, MOV and M4V videos.";
  return message || "Bubble couldn't open this video.";
}

/** What a dropped file is, from its name and type, before anything is read. */
export function classify(file) {
  if (PLAYABLE.test(file.name)) return { ok: true };
  const ext = (file.name.match(/\.([a-z0-9]+)$/i) || [])[1];
  if (VIDEO_TYPES.test(file.type) || /^(mkv|webm|avi|flv|wmv|mpg|mpeg|3gp)$/i.test(ext || "")) {
    return { ok: false, text: `Bubble can't open .${(ext || "this").toLowerCase()} files. It edits MP4, MOV and M4V videos. Convert it to MP4 first.` };
  }
  return { ok: false, text: "This isn't a video." };
}

async function sha256(blob) {
  const buf = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer());
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** { name, size, lastModified, head, tail }: sha256 of the first and last 1 MB (whole file under 2 MB). */
export async function fingerprint(file) {
  if (file.size < 2 * MB) {
    const whole = await sha256(file);
    return { name: file.name, size: file.size, lastModified: file.lastModified, head: whole, tail: whole };
  }
  const [head, tail] = await Promise.all([sha256(file.slice(0, MB)), sha256(file.slice(file.size - MB))]);
  return { name: file.name, size: file.size, lastModified: file.lastModified, head, tail };
}

// ---------- the notice card (one at a time, top center) ----------
let card = null;
export function closeNotice() { card?.remove(); card = null; }
/** A small card: a title, lines, buttons [{ label, primary, onClick }]. `quiet` = no close button. */
export function notice({ title, lines = [], buttons = [], tone = "", quiet = false }) {
  closeNotice();
  card = el("div", `notice ${tone}`);
  card.setAttribute("role", "status");
  const body = el("div", "notice-body");
  if (title) body.append(el("p", "notice-title", title));
  for (const l of lines) body.append(el("p", "notice-line", l));
  card.append(body);
  if (buttons.length) {
    const row = el("div", "notice-buttons");
    for (const b of buttons) {
      const btn = el("button", `btn small${b.primary ? " primary" : ""}`, b.label);
      btn.onclick = b.onClick;
      row.append(btn);
    }
    card.append(row);
  }
  if (!quiet) {
    const x = el("button", "icon-btn notice-x");
    x.title = "Close";
    x.innerHTML = '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="m6 6 8 8M14 6l-8 8"/></svg>';
    x.onclick = closeNotice;
    card.append(x);
  }
  document.body.append(card);
  return card;
}

// ---------- A. Open Video… (and Locate…: same panel, same polling) ----------
const PENDING_KEY = "bubble-open-pending";

/**
 * Drives a "Bubble shows its panel" request: start() POSTs, then polls every 500 ms.
 * onState(state, detail): 'waiting' | 'idle' | 'failed' (detail: sentence) | 'opened' (detail: status).
 */
export function createPanelRequest({ start, onState, key = PENDING_KEY }) {
  let openId = null, timer = 0;
  const stop = () => { clearTimeout(timer); timer = 0; openId = null; sessionStorage.removeItem(key); };
  async function poll() {
    if (!openId) return;
    let st;
    try { st = await openApi.openStatus(openId); }
    catch (err) {
      if (err.status === 404) { stop(); onState("idle"); return; }
      timer = setTimeout(poll, 1500); return; // Bubble busy or offline: keep trying
    }
    if (st.state === "pending") { timer = setTimeout(poll, 500); return; }
    stop();
    if (st.state === "opened") onState("opened", st);
    else if (st.state === "failed") onState("failed", refusalText(st));
    else onState("idle");
  }
  return {
    get waiting() { return !!openId; },
    async go() {
      try {
        const r = await start();
        openId = r.openId;
        sessionStorage.setItem(key, openId);
        onState("waiting");
        poll();
      } catch (err) {
        if (err.status === 409) { onState("waiting"); return; } // Bubble brought its panel back to the front
        onState("failed", err.status ? refusalText(err) : "Open Bubble to open a video.");
      }
    },
    /** A reloaded tab picks a pending request up again. */
    resume() {
      const id = sessionStorage.getItem(key);
      if (!id || openId) return;
      openId = id;
      onState("waiting");
      poll();
    },
    /** Esc: stop waiting in the page (Bubble's panel stays up; Cancel it there). */
    forget() { if (openId) { stop(); onState("idle"); } },
  };
}

/** Wires an Open Video… button: busy label, the quiet line, then go to the opened project. */
export function wireOpenButton(button, { onOpened }) {
  const label = button.querySelector("span") || button;
  const idle = label.textContent;
  const req = createPanelRequest({
    start: openApi.open,
    onState(state, detail) {
      button.classList.toggle("busy", state === "waiting");
      label.textContent = state === "waiting" ? "Choose a video in Bubble…" : idle;
      if (state === "waiting") notice({ lines: ["The file panel is open in Bubble."], tone: "quiet", quiet: true });
      else if (state === "failed") notice({ title: detail, tone: "bad" });
      else closeNotice();
      if (state === "opened") onOpened(detail.projectId);
    },
  });
  button.addEventListener("click", () => req.go()); // again while waiting: Bubble re-fronts its panel
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && req.waiting) req.forget(); });
  req.resume();
  return req;
}

// ---------- B. Drop a video on the page ----------
/**
 * The drop overlay on `root` and the drop flow. `enabled()` false (Bubble offline): the overlay
 * says so and a drop does nothing. `chooseInBubble()` runs Open Video… (the not-found card).
 */
export function wireDrop({ enabled = () => true, onOpened, chooseInBubble }) {
  const overlay = el("div", "drop-overlay");
  const box = el("div", "drop-box");
  const text = el("p", "drop-text");
  const sub = el("p", "drop-sub");
  box.append(text, sub);
  overlay.append(box);
  document.body.append(overlay);
  let depth = 0;

  const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes("Files");
  function describe(e) {
    const items = [...(e.dataTransfer?.items || [])].filter((i) => i.kind === "file");
    if (!enabled()) return { text: "Open Bubble to open a video", sub: "", ok: false };
    if (items.length > 1) return { text: "Drop one video at a time", sub: "", ok: false };
    const type = items[0]?.type || "";
    // While dragging, browsers give the type but not the name; an empty type is decided on drop.
    if (type && !VIDEO_TYPES.test(type)) return { text: "This isn't a video", sub: "", ok: false };
    return { text: "Drop to edit this video", sub: "It stays where it is, nothing is copied.", ok: true };
  }
  function show(e) {
    const d = describe(e);
    text.textContent = d.text;
    sub.textContent = d.sub;
    overlay.classList.toggle("no", !d.ok);
    overlay.classList.add("on");
  }
  addEventListener("dragenter", (e) => { if (!hasFiles(e)) return; e.preventDefault(); depth++; show(e); });
  addEventListener("dragover", (e) => { if (!hasFiles(e)) return; e.preventDefault(); e.dataTransfer.dropEffect = describe(e).ok ? "copy" : "none"; });
  addEventListener("dragleave", (e) => { if (!hasFiles(e)) return; depth = Math.max(0, depth - 1); if (!depth) overlay.classList.remove("on"); });
  addEventListener("drop", (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    depth = 0;
    overlay.classList.remove("on");
    if (!enabled()) return;
    const files = [...e.dataTransfer.files];
    if (files.length > 1) { notice({ title: "Drop one video at a time." }); return; }
    if (files.length === 1) openDropped(files[0], { onOpened, chooseInBubble });
  });
}

/** The drop flow for one file: classify, hash 2 × 1 MB, ask Bubble to find it. */
export async function openDropped(file, { onOpened, chooseInBubble }) {
  const kind = classify(file);
  if (!kind.ok) { notice({ title: kind.text, tone: "bad" }); return; }
  notice({ title: `Finding ${file.name} on your Mac…`, lines: [], tone: "quiet", quiet: true });
  // macOS may ask once per protected folder (Desktop, Documents, Downloads…) while Bubble looks.
  const hint = setTimeout(() => {
    if (card) card.querySelector(".notice-body").append(el("p", "notice-line", "If macOS asks, allow Bubble to read that folder."));
  }, 900);
  try {
    const body = await fingerprint(file);
    const r = await openApi.dropped(body);
    clearTimeout(hint);
    closeNotice();
    onOpened(r.projectId);
  } catch (err) {
    clearTimeout(hint);
    if (err.status === 404) {
      notice({
        title: `Bubble couldn't find ${file.name} on your Mac.`,
        lines: ["It may be on a drive Spotlight doesn't index, or in an app's library (Photos). Choose it in Bubble instead."],
        buttons: [{ label: "Choose it in Bubble…", primary: true, onClick: () => { closeNotice(); chooseInBubble(); } }],
      });
    } else if (err.status === 422) notice({ title: refusalText(err), tone: "bad" });
    else notice({ title: err.status ? refusalText(err) : "Open Bubble to open a video.", tone: "bad" });
  }
}

export function relativeTime(iso, now = Date.now()) {
  const t = new Date(iso).getTime();
  if (!t) return "";
  const s = Math.max(0, (now - t) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  const d = new Date(t), today = new Date(now);
  const days = Math.round((new Date(today.toDateString()) - new Date(d.toDateString())) / 86400000);
  if (days === 0) return `${Math.floor(s / 3600)} h ago`;
  if (days === 1) return "yesterday";
  if (days < 7) return d.toLocaleDateString("en", { weekday: "long" });
  return d.toLocaleDateString("en", { day: "numeric", month: "short", year: d.getFullYear() === today.getFullYear() ? undefined : "numeric" });
}
