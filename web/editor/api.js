// Page <-> Bubble's local server (docs/editor-api.md). The only module that knows URLs and
// payloads. Auth is a cookie the server sets on /edit/:id?t=…; nothing to do here.

async function json(res) {
  const body = res.status === 204 ? null : await res.json().catch(() => null);
  if (!res.ok) {
    const err = new Error(body?.message || `HTTP ${res.status}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

export function projectIdFromLocation(loc = window.location) {
  const m = loc.pathname.match(/\/edit\/([^/]+)/);
  return m ? decodeURIComponent(m[1]) : "demo";
}

const send = (method, url, body, extra = {}) =>
  fetch(url, { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body), ...extra }).then(json);

export function createApi(id) {
  const p = `/api/projects/${encodeURIComponent(id)}`;
  return {
    load: () => fetch(p).then(json),
    /** -> { peaksPerSecond, peaks: Uint8Array 0..255 }, or null while the server computes them. */
    async waveform() {
      const res = await fetch(`${p}/waveform`);
      if (res.status === 202) return null;
      const w = await json(res);
      const bytes = Uint8Array.from(atob(w.peaks), (c) => c.charCodeAt(0));
      return { peaksPerSecond: w.peaksPerSecond, peaks: bytes };
    },
    saveEdits: (revision, segments, keepalive = false) => send("PUT", `${p}/edits`, { revision, segments }, { keepalive }),
    patch: (fields) => send("PATCH", p, fields),
    engines: () => fetch("/api/engines").then(json),
    /** -> { mistralKey: 'keychain' | 'environment' | 'none' } (never the key itself) */
    settings: () => fetch("/api/settings").then(json),
    /** -> { engines } once Bubble checked the key with Mistral; 422 invalid_key, 502 unreachable */
    saveKey: (key) => send("PUT", "/api/settings/mistral-key", { key }),
    deleteKey: () => fetch("/api/settings/mistral-key", { method: "DELETE" }).then(json),
    transcribe: (engine) => send("POST", `${p}/transcription`, engine ? { engine } : {}),
    startExport: () => send("POST", `${p}/export`, {}),
    exportStatus: (jobId) => fetch(`/api/exports/${encodeURIComponent(jobId)}`).then(json),
    cancelExport: (jobId) => fetch(`/api/exports/${encodeURIComponent(jobId)}`, { method: "DELETE" }),
  };
}
