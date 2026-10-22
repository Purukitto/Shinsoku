// Toolbar popup: lists HLS streams the background sniffer found on the active
// tab and hands the chosen one to Shinsoku (with the tab's cookies/referrer/UA).
// Relies on common.js (api/loadSettings/endpoint/streamKey).

const $ = (id) => document.getElementById(id);

function setStatus(msg, ok) {
  const el = $('status');
  el.textContent = msg;
  el.className = ok ? 'ok' : 'err';
}

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function cookieHeader(url) {
  try {
    const cookies = await api.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join('; ');
  } catch {
    return '';
  }
}

async function send(stream, tab, s, btn) {
  btn.disabled = true;
  btn.textContent = 'Sending…';
  const payload = {
    url: stream.url,
    title: tab.title || stream.name || '',
    referrer: tab.url || '',
    cookie: await cookieHeader(stream.url),
    userAgent: navigator.userAgent,
  };
  try {
    const res = await fetch(endpoint(s, '/api/add-stream'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Shinsoku-Token': s.token },
      body: JSON.stringify(payload),
    });
    const body = await res.json().catch(() => ({}));
    if (res.ok) {
      btn.textContent = 'Sent ✓';
      setStatus(body.refreshed ? 'Link refreshed in Shinsoku.' : 'Sent to Shinsoku.', true);
    } else if (res.status === 409) {
      // a download waiting in Shinsoku for a fresh link refused this one
      btn.disabled = false;
      btn.textContent = 'Send';
      setStatus(body.error || 'Not the same stream.', false);
    } else if (res.status === 401) {
      btn.disabled = false;
      btn.textContent = 'Send';
      setStatus('Bad token — re-pair in Options.', false);
    } else {
      btn.disabled = false;
      btn.textContent = 'Send';
      setStatus(`Server returned ${res.status}.`, false);
    }
  } catch {
    btn.disabled = false;
    btn.textContent = 'Send';
    setStatus('Could not reach Shinsoku. Is it running with capture enabled?', false);
  }
}

async function render() {
  const s = await loadSettings();
  if (!s.token) {
    $('hint').textContent = 'Not paired yet — open Options and paste your pairing code.';
    return;
  }
  if (!s.enabled) {
    $('hint').textContent = 'Capture is off — enable it in Options.';
    return;
  }

  const tab = await activeTab();
  const got = tab ? await api.storage.session.get(streamKey(tab.id)) : {};
  let streams = (tab && got[streamKey(tab.id)]) || [];

  // Collapse the per-quality variant playlists that belong to a detected master,
  // so the page's master playlist is the single obvious choice.
  const variantUris = new Set();
  for (const st of streams) (st.variantUris || []).forEach((u) => variantUris.add(u));
  streams = streams.filter((st) => !variantUris.has(st.url));

  if (streams.length === 0) {
    $('hint').textContent = 'No streams detected on this page yet. Start playback, then reopen.';
    return;
  }

  $('hint').textContent = `${streams.length} stream${streams.length > 1 ? 's' : ''} detected:`;
  const list = $('list');
  for (const stream of streams) {
    const row = document.createElement('div');
    row.className = 'row';

    const info = document.createElement('div');
    info.className = 'info';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = streamHeadline(stream, tab);
    const sub = document.createElement('div');
    sub.className = 'sub';
    sub.textContent = streamSubline(stream);
    sub.title = stream.url;
    info.append(name, sub);

    const btn = document.createElement('button');
    btn.className = 'primary';
    btn.textContent = 'Send';
    btn.addEventListener('click', () => send(stream, tab, s, btn));

    row.append(info, btn);
    list.append(row);
  }
}

// Bold line: the most salient distinguisher between entries.
function streamHeadline(s, tab) {
  if (s.kind === 'master') {
    return s.height ? `${s.height}p · HLS` : `HLS · ${s.variants || 0} variants`;
  }
  if (s.kind === 'media') {
    if (s.live) return 'Live · HLS';
    const d = fmtDur(s.duration);
    return d ? `${d} · HLS` : 'HLS stream';
  }
  return (tab && tab.title) || 'HLS stream'; // pending / unparsed
}

// Mono sub-line: filename + extension, count, estimated size, host.
function streamSubline(s) {
  const bits = [s.name || playlistName(s.url)];
  if (s.kind === 'master' && s.variants) bits.push(`${s.variants} variants`);
  if (s.kind === 'media' && s.segments) bits.push(`${s.segments} segments`);
  if (s.bytes) bits.push(`~${fmtBytes(s.bytes)}`);
  if (s.host) bits.push(s.host);
  return bits.join('  ·  ');
}

$('options').addEventListener('click', () => api.runtime.openOptionsPage());
render();
