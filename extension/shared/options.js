// Options page logic. Relies on common.js (loaded first) for api/loadSettings/
// saveSettings/endpoint.

const $ = (id) => document.getElementById(id);

function setStatus(msg, ok) {
  const el = $('status');
  el.textContent = msg;
  el.className = ok ? 'ok' : 'err';
}

async function restore() {
  const s = await loadSettings();
  $('enabled').checked = s.enabled;
  $('host').value = s.host;
  $('port').value = s.port;
  $('token').value = s.token;
  $('minSizeMb').value = s.minSizeMb;
  $('blocklist').value = s.blocklist;
}

function readForm() {
  return {
    enabled: $('enabled').checked,
    host: $('host').value.trim() || '127.0.0.1',
    port: parseInt($('port').value, 10) || 7878,
    token: $('token').value.trim(),
    minSizeMb: parseFloat($('minSizeMb').value) || 0,
    blocklist: $('blocklist').value.trim(),
  };
}

async function testConnection(s) {
  if (!s.token) {
    setStatus('Enter a token, or paste a pairing code above.', false);
    return;
  }
  setStatus('Testing…', true);
  try {
    const res = await fetch(endpoint(s, '/api/ping'), {
      headers: { 'X-Shinsoku-Token': s.token },
    });
    if (res.ok) {
      const j = await res.json();
      setStatus(`Connected to ${j.app} v${j.version}.`, true);
    } else if (res.status === 401) {
      setStatus('Bad token — copy it again from Shinsoku.', false);
    } else {
      setStatus(`Server returned ${res.status}.`, false);
    }
  } catch {
    setStatus('Could not reach Shinsoku. Is it running with capture enabled?', false);
  }
}

// Decode a `shnsk_<base64(JSON)>` pairing code into {host, port, token}.
function decodePairingCode(code) {
  const m = /^shnsk_(.+)$/.exec((code || '').trim());
  if (!m) return null;
  try {
    const obj = JSON.parse(atob(m[1]));
    const host = String(obj.h || '').trim();
    const port = parseInt(obj.p, 10);
    const token = String(obj.t || '').trim();
    if (!host || !port || !token) return null;
    return { host, port, token };
  } catch {
    return null;
  }
}

$('apply').addEventListener('click', async () => {
  const parsed = decodePairingCode($('pairCode').value);
  if (!parsed) {
    setStatus('That doesn’t look like a Shinsoku pairing code.', false);
    return;
  }
  $('host').value = parsed.host;
  $('port').value = parsed.port;
  $('token').value = parsed.token;
  $('enabled').checked = true;
  $('pairCode').value = '';
  const s = readForm();
  await saveSettings(s);
  await testConnection(s);
});

$('save').addEventListener('click', async () => {
  await saveSettings(readForm());
  setStatus('Saved.', true);
});

$('test').addEventListener('click', () => testConnection(readForm()));

restore();
