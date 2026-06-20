// Shared settings + helpers for both the background worker and the options page.
// Loaded first (Chromium: via importScripts in background.js / <script> in
// options.html; Firefox: as the first entry in background.scripts).

const api = globalThis.browser ?? globalThis.chrome;

const DEFAULTS = {
  enabled: true,
  host: '127.0.0.1',
  port: 7878,
  token: '',
  minSizeMb: 0,
  blocklist: '',
};

async function loadSettings() {
  const got = await api.storage.local.get(DEFAULTS);
  return { ...DEFAULTS, ...got };
}

async function saveSettings(s) {
  await api.storage.local.set(s);
}

function endpoint(s, path) {
  return `http://${s.host}:${s.port}${path}`;
}

// Per-tab session-storage key for detected HLS streams (background ↔ popup).
function streamKey(tabId) {
  return `streams_${tabId}`;
}

// ── shared formatting / HLS helpers (background fills metadata, popup renders) ──

function hostOf(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}

// Last path segment, extension kept — e.g. "master.m3u8".
function playlistName(url) {
  try {
    return new URL(url).pathname.split('/').filter(Boolean).pop() || 'playlist.m3u8';
  } catch {
    return 'playlist.m3u8';
  }
}

function fmtBytes(n) {
  if (!n || n < 1024) return n ? `${n} B` : '';
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n;
  let i = -1;
  do {
    v /= 1024;
    i++;
  } while (v >= 1024 && i < units.length - 1);
  return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
}

function fmtDur(sec) {
  const s = Math.round(sec || 0);
  if (s <= 0) return '';
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${s % 60}s`;
  return `${s}s`;
}
