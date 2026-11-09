// Bubble's home page at / : drop a video, Open Video…, the recent videos
// (docs/editor-open-video.md §3 F). Same look as the editor (editor.css).
import { openApi } from "./api.js";
import { wireOpenButton, wireDrop, notice, closeNotice, relativeTime } from "./open.js";
import { formatTime } from "./model.js";

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};
const ICON_MORE = '<svg viewBox="0 0 20 20" fill="currentColor"><circle cx="5" cy="10" r="1.5"/><circle cx="10" cy="10" r="1.5"/><circle cx="15" cy="10" r="1.5"/></svg>';
const ICON_FILM = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 5v14M17 5v14M3 9h4M3 15h4M17 9h4M17 15h4"/></svg>';
const ICON_WARN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="M12 4 2.8 19.5h18.4Z"/><path d="M12 10v4.5M12 17.2v.3" stroke-linecap="round"/></svg>';

let online = true;
let projects = [];
const goEdit = (id) => { location.href = `/edit/${encodeURIComponent(id)}`; };

const opener = wireOpenButton($("openVideo"), { onOpened: goEdit });
$("openVideo2").onclick = () => opener.go();
wireDrop({ enabled: () => online, onOpened: goEdit, chooseInBubble: () => opener.go() });

let retry = 0; // declared before the first load() runs (it reads it)
load();
addEventListener("focus", () => load()); // back from Finder or Bubble: the list may have changed

async function load() {
  clearTimeout(retry);
  try {
    const r = await openApi.projects();
    projects = r.projects || [];
    setOnline(true);
  } catch (err) {
    if (!err.status) {
      // connection refused: Bubble isn't running. Retry every 3 s (editor-api.md §1), so a tab
      // left open while Bubble relaunches comes back by itself.
      setOnline(false);
      retry = setTimeout(load, 3000);
    }
  }
  render();
}

function setOnline(v) {
  online = v;
  $("offline").hidden = v;
  for (const b of [$("openVideo"), $("openVideo2")]) {
    b.disabled = !v;
    b.title = v ? "Choose a video on your Mac (⌘O)" : "Open Bubble to open a video";
  }
  document.body.classList.toggle("is-offline", !v);
}

function render() {
  $("dropzone").classList.toggle("tall", !projects.length);
  $("recent").hidden = !projects.length;
  $("rows").replaceChildren(...projects.map(row));
}

function where(f) {
  if (f.state === "offline") return { text: `on "${f.volume || "a drive"}", not connected`, warn: true };
  if (f.state === "missing") return { text: "Missing", warn: true };
  return { text: f.folder || "", warn: false };
}

function row(p) {
  const li = el("li", "row");
  li.tabIndex = 0;
  const f = p.file || {};
  const w = where(f);
  const thumb = el("div", "thumb");
  if (w.warn) { thumb.classList.add("warn"); thumb.innerHTML = ICON_WARN; }
  else if (p.posterUrl) { const img = el("img"); img.src = p.posterUrl; img.alt = ""; img.loading = "lazy"; thumb.append(img); }
  else thumb.innerHTML = ICON_FILM;

  const text = el("div", "row-text");
  const title = el("div", "row-title", p.title);
  const meta = el("div", "row-meta");
  const len = Math.abs((p.editedDuration ?? p.duration) - p.duration) > 0.5
    ? `${formatTime(p.editedDuration)} (${formatTime(p.duration)} before edits)` : formatTime(p.duration);
  const parts = [len, `edited ${relativeTime(p.updatedAt)}`];
  meta.append(document.createTextNode(parts.join(" · ") + " · "));
  const place = el("span", w.warn ? "row-warn" : "row-folder", w.text);
  place.title = f.path || f.folder || "";
  meta.append(place);
  text.append(title, meta);

  const more = el("button", "icon-btn row-more");
  more.innerHTML = ICON_MORE;
  more.title = "More";
  more.onclick = (e) => { e.stopPropagation(); openRowMenu(more, p); };

  li.append(thumb, text, more);
  li.onclick = () => goEdit(p.id);
  li.onkeydown = (e) => { if (e.key === "Enter") goEdit(p.id); };
  return li;
}

// ---------- ⋯ menu: Show in Finder, Remove from list… ----------
let menu = null;
function closeMenu() { menu?.remove(); menu = null; }
document.addEventListener("pointerdown", (e) => { if (menu && !menu.contains(e.target)) closeMenu(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeMenu(); closeDialog(); } });

function openRowMenu(anchor, p) {
  closeMenu();
  menu = el("div", "menu");
  const reachable = (p.file?.state || "ok") === "ok";
  const show = el("button", null, "Show in Finder");
  show.disabled = !reachable || !online;
  show.title = reachable ? "" : "The video file isn't reachable";
  show.onclick = async () => {
    closeMenu();
    try { await openApi.reveal(p.id); } catch { notice({ title: "Bubble couldn't show this video in Finder.", tone: "bad" }); }
  };
  const rm = el("button", "danger", "Remove from list…");
  rm.disabled = !online;
  rm.onclick = () => { closeMenu(); confirmRemove(p); };
  menu.append(show, rm);
  document.body.append(menu);
  const r = anchor.getBoundingClientRect();
  menu.style.left = `${Math.max(8, r.right - menu.offsetWidth)}px`;
  menu.style.top = `${r.bottom + 4}px`;
}

let dialog = null;
function closeDialog() { dialog?.remove(); dialog = null; }
function confirmRemove(p) {
  closeDialog();
  dialog = el("div", "dialog-backdrop");
  const d = el("div", "dialog");
  d.setAttribute("role", "alertdialog");
  d.append(el("p", "dialog-title", `Remove “${p.title}” from the list?`));
  d.append(el("p", "dialog-text", "Removes your edits and transcript for this video. The video file stays."));
  const row = el("div", "dialog-buttons");
  const cancel = el("button", "btn", "Cancel");
  cancel.onclick = closeDialog;
  const ok = el("button", "btn primary danger-fill", "Remove");
  ok.onclick = async () => {
    ok.disabled = true;
    try {
      await openApi.remove(p.id);
      projects = projects.filter((x) => x.id !== p.id);
      closeDialog();
      render();
    } catch {
      closeDialog();
      notice({ title: "Bubble couldn't remove it. Try again.", tone: "bad" });
    }
  };
  row.append(cancel, ok);
  d.append(row);
  dialog.append(d);
  dialog.onclick = (e) => { if (e.target === dialog) closeDialog(); };
  document.body.append(dialog);
  ok.focus();
}

export { closeNotice };
