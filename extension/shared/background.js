// Intercepts browser downloads and hands them to the running Shinsoku app with
// the cookies/referrer/UA the browser would have used. POSTs first and only
// cancels the browser download once Shinsoku accepts it, so nothing is lost if
// the app isn't running.

// Chromium service worker: pull in shared helpers. Firefox loads common.js via
// the manifest's background.scripts, where importScripts doesn't exist.
if (typeof importScripts === 'function') {
  importScripts('common.js');
}

const log = (...a) => console.log('[Shinsoku]', ...a);

log('background loaded; downloads API:', typeof api?.downloads,
  'onCreated:', typeof api?.downloads?.onCreated);

api.downloads.onCreated.addListener((item) => {
  log('onCreated', { id: item.id, url: item.url, finalUrl: item.finalUrl, size: item.fileSize });
  handleDownload(item).catch((e) => console.error('[Shinsoku] capture error', e));
});

// ── HLS stream detection ────────────────────────────────────────────────────
// Streams play inline (no downloads.onCreated), so sniff responses for M3U8
// playlists and surface them per-tab via the toolbar popup. Observation only —
// nothing is blocked or cancelled here.
api.webRequest.onHeadersReceived.addListener(
  onHeaders,
  { urls: ['<all_urls>'], types: ['xmlhttprequest', 'media', 'other', 'sub_frame'] },
  ['responseHeaders'],
);

function onHeaders(details) {
  if (details.tabId < 0 || !/^https?:/i.test(details.url)) return;
  const ct = headerValue(details.responseHeaders, 'content-type').toLowerCase();
  if (ct.includes('mpegurl') || isM3u8(details.url)) {
    recordStream(details.tabId, details.url).catch(() => {});
  }
}

function headerValue(headers, name) {
  const h = (headers || []).find((x) => x.name.toLowerCase() === name);
  return h && h.value ? h.value : '';
}

function isM3u8(url) {
  try {
    return new URL(url).pathname.toLowerCase().endsWith('.m3u8');
  } catch {
    return false;
  }
}

async function recordStream(tabId, url) {
  const key = streamKey(tabId);
  const got = await api.storage.session.get(key);
  const list = got[key] || [];
  if (list.some((s) => s.url === url)) return;
  // Store a basic entry immediately so the badge/popup respond fast…
  list.push({ url, name: playlistName(url), host: hostOf(url), kind: 'pending', ts: Date.now() });
  if (list.length > 20) list.shift();
  await api.storage.session.set({ [key]: list });
  setBadge(tabId, list.length);
  // …then fetch + parse the playlist so the popup can show quality/size.
  enrichStream(tabId, url).catch(() => {});
}

async function enrichStream(tabId, url) {
  const meta = await probePlaylist(url);
  const key = streamKey(tabId);
  const got = await api.storage.session.get(key);
  const list = got[key] || [];
  const i = list.findIndex((s) => s.url === url);
  if (i < 0) return; // tab navigated away
  list[i] = { ...list[i], kind: 'plain', ...(meta || {}) };
  await api.storage.session.set({ [key]: list });
}

// Fetch a playlist and classify it: master (variants + best quality/size) vs a
// single media playlist (VOD duration / live). Degrades to null on any failure.
async function probePlaylist(url) {
  const text = await fetchText(url);
  if (!text || !text.includes('#EXTM3U')) return null;
  if (!text.includes('#EXT-X-STREAM-INF')) return probeMedia(text);

  const meta = probeMaster(url, text);
  // Estimate size from the top variant: bandwidth (bits/s) × duration / 8.
  if (meta.bestUri && meta.bandwidth) {
    const media = await fetchText(meta.bestUri);
    if (media) {
      const dur = mediaDuration(media);
      if (dur > 0) meta.bytes = Math.round((meta.bandwidth / 8) * dur);
      if (!media.includes('#EXT-X-ENDLIST')) meta.live = true;
    }
  }
  delete meta.bestUri;
  delete meta.bandwidth;
  return meta;
}

function probeMaster(url, text) {
  const lines = text.split(/\r?\n/);
  const variants = [];
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    const attrs = parseAttrs(lines[i].slice(lines[i].indexOf(':') + 1));
    const uri = (lines[i + 1] || '').trim();
    if (!uri || uri.startsWith('#')) continue;
    variants.push({
      bandwidth: parseInt(attrs.BANDWIDTH || attrs['AVERAGE-BANDWIDTH'] || '0', 10),
      height: (attrs.RESOLUTION || '').split('x')[1] || '',
      uri: absUrl(url, uri),
    });
  }
  if (variants.length === 0) return { kind: 'master', variants: 0 };
  variants.sort((a, b) => b.bandwidth - a.bandwidth);
  const best = variants[0];
  return {
    kind: 'master',
    height: best.height,
    variants: variants.length,
    variantUris: variants.map((v) => v.uri), // popup collapses these child entries
    bandwidth: best.bandwidth,
    bestUri: best.uri,
  };
}

function probeMedia(text) {
  return {
    kind: 'media',
    live: !text.includes('#EXT-X-ENDLIST'),
    duration: mediaDuration(text),
    segments: (text.match(/#EXTINF:/g) || []).length,
  };
}

// `KEY=VALUE,KEY="QUOTED VALUE",…` → object.
function parseAttrs(s) {
  const out = {};
  const re = /([A-Z0-9-]+)=("[^"]*"|[^,]*)/g;
  let m;
  while ((m = re.exec(s))) out[m[1]] = m[2].replace(/^"|"$/g, '');
  return out;
}

function mediaDuration(text) {
  let dur = 0;
  const re = /#EXTINF:\s*([\d.]+)/g;
  let m;
  while ((m = re.exec(text))) dur += parseFloat(m[1]) || 0;
  return dur;
}

function absUrl(base, uri) {
  try {
    return new URL(uri, base).href;
  } catch {
    return uri;
  }
}

async function fetchText(url) {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 6000);
    const res = await fetch(url, { credentials: 'include', signal: ctrl.signal });
    clearTimeout(t);
    return res.ok ? await res.text() : null;
  } catch {
    return null;
  }
}

function setBadge(tabId, n) {
  try {
    api.action.setBadgeText({ tabId, text: n > 0 ? String(n) : '' });
    api.action.setBadgeBackgroundColor({ color: '#FF63B6' });
  } catch {}
}

// Drop a tab's detected streams when it navigates to a new page or closes.
api.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.url) {
    api.storage.session.remove(streamKey(tabId)).catch(() => {});
    setBadge(tabId, 0);
  }
});
api.tabs.onRemoved.addListener((tabId) => {
  api.storage.session.remove(streamKey(tabId)).catch(() => {});
});

async function handleDownload(item) {
  const s = await loadSettings();
  if (!s.enabled) return log('skip: capture is OFF (enable it and Save/Apply in options)');
  if (!s.token) return log('skip: no token saved (paste pairing code, then Apply)');

  const url = item.finalUrl && item.finalUrl !== 'about:blank' ? item.finalUrl : item.url;
  if (!url || !/^https?:\/\//i.test(url)) return log('skip: non-http url', url);

  let host = '';
  try {
    host = new URL(url).hostname;
  } catch {
    return log('skip: unparseable url', url);
  }
  // never bounce our own loopback endpoint back to the app
  if (host === s.host || host === 'localhost' || host === '127.0.0.1') return log('skip: loopback host');
  if (isBlocked(host, s.blocklist)) return log('skip: blocklisted', host);

  // fileSize is -1 when unknown → allow it through
  const size = typeof item.fileSize === 'number' ? item.fileSize : -1;
  if (s.minSizeMb > 0 && size > 0 && size < s.minSizeMb * 1024 * 1024) {
    return log('skip: below min size', size);
  }

  const payload = {
    url,
    filename: baseName(item.filename),
    referrer: item.referrer || '',
    cookie: await cookieHeader(url),
    userAgent: navigator.userAgent,
    mime: item.mime || '',
    size: size > 0 ? size : 0,
  };

  let ok = false;
  let body = {};
  try {
    const res = await fetch(endpoint(s, '/api/add'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Shinsoku-Token': s.token },
      body: JSON.stringify(payload),
    });
    ok = res.ok;
    body = await res.json().catch(() => ({}));
    if (!ok) log('POST rejected', res.status, body.error || '');
    // 409: a download waiting in Shinsoku for a fresh link refused this one
    if (res.status === 409) {
      return notify('Shinsoku kept its old link', `${body.error || 'Not the same file.'} Downloading in the browser instead.`);
    }
  } catch (e) {
    log('POST failed (app unreachable?)', String(e));
    ok = false;
  }

  if (ok) {
    try { await api.downloads.cancel(item.id); } catch (e) { log('cancel failed (already finished?)', String(e)); }
    try { await api.downloads.erase({ id: item.id }); } catch {}
    log('handed off to Shinsoku', url, body.refreshed ? '(refreshed link)' : '');
    notify(body.refreshed ? 'Link refreshed in Shinsoku' : 'Sent to Shinsoku', payload.filename || url);
  } else {
    notify('Shinsoku not reachable', 'Downloading in the browser instead.');
  }
}

async function cookieHeader(url) {
  try {
    const cookies = await api.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join('; ');
  } catch {
    return '';
  }
}

function isBlocked(host, blocklist) {
  const list = (blocklist || '')
    .split(/[\s,]+/)
    .map((d) => d.trim().toLowerCase())
    .filter(Boolean);
  return list.some((d) => host === d || host.endsWith('.' + d));
}

function baseName(name) {
  if (!name) return '';
  const parts = name.replace(/\\/g, '/').split('/');
  return parts[parts.length - 1] || '';
}

function notify(title, message) {
  try {
    api.notifications.create({
      type: 'basic',
      iconUrl: api.runtime.getURL('icons/icon-48.png'),
      title,
      message: String(message).slice(0, 200),
    });
  } catch {}
}
