// Pure edit model: no DOM, no I/O. Times are seconds of the source recording.
// An edit list is sorted, non-overlapping segments { start, end, rate } that differ from 1×:
// rate 0 = removed, any other rate = played at that speed. Everything else plays at 1×.

export const RATES = [0.5, 1, 1.25, 1.5, 2];
const EPS = 1e-6;

/**
 * Sets `rate` on [start, end): the newest edit wins (docs/editor-api.md §3).
 * rate 0 cuts, rate 1 restores, any other rate speeds up or slows down,
 * except that speed never un-cuts: cut parts inside the range stay cut.
 */
export function applyRate(segments, start, end, rate) {
  if (end - start < EPS) return segments;
  const out = [];
  const keptCuts = [];
  for (const s of segments) {
    if (s.end <= start + EPS || s.start >= end - EPS) { out.push(s); continue; }
    if (s.start < start) out.push({ ...s, end: start });
    if (s.end > end) out.push({ ...s, start: end });
    if (s.rate === 0 && rate !== 0 && rate !== 1) keptCuts.push({ start: Math.max(s.start, start), end: Math.min(s.end, end), rate: 0 });
  }
  if (rate !== 1) {
    let t = start;
    for (const c of keptCuts) {
      if (c.start > t) out.push({ start: t, end: c.start, rate });
      out.push(c);
      t = c.end;
    }
    if (end > t) out.push({ start: t, end, rate });
  }
  return normalize(out);
}

const MIN_SEGMENT = 1 / 30;

/** Sorts, drops 1× and sub-frame segments, merges touching segments with the same rate. */
export function normalize(segments) {
  const sorted = segments
    .filter((s) => s.end - s.start >= MIN_SEGMENT - EPS && s.rate !== 1)
    .map((s) => ({ start: s.start, end: s.end, rate: s.rate }))
    .sort((a, b) => a.start - b.start);
  const out = [];
  for (const s of sorted) {
    const last = out[out.length - 1];
    if (last && last.rate === s.rate && s.start <= last.end + EPS) last.end = Math.max(last.end, s.end);
    else out.push(s);
  }
  return out;
}

/** The rate at source time t (1 when untouched). */
export function rateAt(segments, t) {
  for (const s of segments) {
    if (t < s.start) break;
    if (t < s.end) return s.rate;
  }
  return 1;
}

/** The segment containing t, or null. */
export function segmentAt(segments, t) {
  for (const s of segments) {
    if (t < s.start) break;
    if (t < s.end) return s;
  }
  return null;
}

/** Edited (played) time at source time t. */
export function sourceToEdited(segments, t) {
  let removedOrScaled = 0; // how much to subtract from t
  for (const s of segments) {
    if (s.start >= t) break;
    const covered = Math.min(t, s.end) - s.start;
    removedOrScaled += s.rate === 0 ? covered : covered - covered / s.rate;
  }
  return t - removedOrScaled;
}

/** Source time at edited time e (the inverse of sourceToEdited, landing on played time). */
export function editedToSource(segments, duration, e) {
  let src = 0;
  let left = Math.max(0, e);
  for (const s of segments) {
    const plain = s.start - src;
    if (left <= plain) return src + left;
    left -= plain;
    src = s.start;
    if (s.rate !== 0) {
      const played = (s.end - s.start) / s.rate;
      if (left <= played) return src + left * s.rate;
      left -= played;
    }
    src = s.end;
  }
  return Math.min(duration, src + left);
}

export function editedDuration(segments, duration) {
  return sourceToEdited(segments, duration);
}

/** Where playback should be: t itself, or the end of the removed run that holds t. */
export function playableFrom(segments, t) {
  for (const s of segments) {
    if (t < s.start) break;
    if (t < s.end && s.rate === 0) t = s.end;
  }
  return t;
}

/** What a range holds: used to show Restore and check the current speed. */
export function describeRange(segments, start, end) {
  let removed = 0, sped = 0, plain = 0;
  const rates = new Set();
  let cursor = start;
  for (const s of segments) {
    if (s.end <= start || s.start >= end) continue;
    const a = Math.max(start, s.start), b = Math.min(end, s.end);
    if (a > cursor) { plain += a - cursor; rates.add(1); }
    if (s.rate === 0) removed += b - a; else { sped += b - a; rates.add(s.rate); }
    cursor = b;
  }
  if (end > cursor) { plain += end - cursor; rates.add(1); }
  const total = end - start;
  return {
    allRemoved: total > 0 && removed >= total - EPS,
    hasEdits: removed + sped > EPS,
    rate: rates.size === 1 ? [...rates][0] : null,
  };
}

/** Groups words into paragraphs: a new one at a speaker change or a pause over `gap` s. */
export function paragraphs(words, gap = 1.5) {
  const out = [];
  let cur = null;
  words.forEach((w, i) => {
    const prev = words[i - 1];
    if (!cur || w.speaker !== cur.speaker || (prev && w.start - prev.end > gap)) {
      cur = { speaker: w.speaker, start: w.start, from: i, to: i };
      out.push(cur);
    } else cur.to = i;
  });
  return out;
}

/** Word indexes whose middle falls inside [start, end). */
export function wordsIn(words, start, end) {
  let from = -1, to = -1;
  for (let i = 0; i < words.length; i++) {
    const mid = (words[i].start + words[i].end) / 2;
    if (mid >= start && mid < end) { if (from < 0) from = i; to = i; }
  }
  return from < 0 ? null : { from, to };
}

/** The index of the word playing at t, or -1. */
export function wordAt(words, t) {
  let lo = 0, hi = words.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (t < words[mid].start) hi = mid - 1;
    else if (t >= words[mid].end) lo = mid + 1;
    else return mid;
  }
  return -1;
}

export function formatTime(s) {
  s = Math.max(0, Math.floor(s + 1e-6));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const ss = String(sec).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

export function formatRate(r) {
  return `${r}×`;
}
