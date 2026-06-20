# Shinsoku Capture (browser extension)

Intercepts downloads in Firefox and Chromium browsers (Chrome/Edge/Brave) and
hands them to the running Shinsoku app — along with the **cookies, referrer and
User-Agent** the browser would have used — so logged-in and referrer-gated
downloads work, not just plain links. It also detects **HLS video streams**
(`.m3u8`) and lets you send them to Shinsoku from the toolbar button.

## How it works

The Shinsoku app runs a tiny loopback HTTP server (`127.0.0.1`, token-guarded).

**File downloads:** when you start one, the extension reads the cookies for that
site, POSTs the request to the app, and **only then** cancels the browser's own
download. If the app isn't running, the browser download just proceeds as normal
— nothing is lost.

**Streams:** HLS plays inline, so there's no download to intercept. The extension
watches network responses for `.m3u8` playlists and tallies them per tab (a count
appears on the toolbar icon). Click the toolbar button to see the detected
streams and **Send to Shinsoku** — the app then fetches the playlist, picks the
highest-quality variant, decrypts (AES-128) and downloads it as one file.

## Build

```powershell
# from this directory
python tool/gen_ext_icons.py   # one-time: generate icons/ (needs Pillow + numpy)
./build.ps1                    # assembles dist/chromium and dist/firefox
```

`build.ps1 -Zip` also produces `dist/chromium.zip` / `dist/firefox.zip`.

## Load it

- **Chrome / Edge / Brave:** `chrome://extensions` → enable *Developer mode* →
  *Load unpacked* → select `dist/chromium`.
- **Firefox:** `about:debugging#/runtime/this-firefox` → *Load Temporary Add-on*
  → select `dist/firefox/manifest.json`.
  Firefox treats host permissions as opt-in: open the add-on's permissions and
  allow access to all sites so cookies can be read for any download domain.

## Pair with the app

1. In Shinsoku: **Settings → Capture → Browser integration** → turn it on.
2. Click **Copy** next to the **Pairing code**.
3. Open the extension's **Options**, paste it into **Pairing code**, and click
   **Apply**. It fills the host/port/token and reports `Connected to shinsoku`.

> Prefer to do it by hand? Use **Manual setup** in both the app (Settings →
> Capture → Manual setup) and the extension options to enter host/port/token
> individually.

## Capture streams

1. Open a page playing an HLS video and start playback.
2. The toolbar icon shows a count once a playlist is detected.
3. Click the icon, then **Send** next to the stream you want. It appears in
   Shinsoku and downloads to completion.

## Options

- **Capture downloads** — master on/off (also gates the stream popup).
- **Host / Port / Token** — must match the app (default host `127.0.0.1`).
- **Minimum size (MB)** — ignore downloads smaller than this (0 = capture all).
- **Blocklist** — domains to never capture (one per line; matches subdomains).

## Limitations (v1)

- Downloads behind one-time URLs or POST request bodies may not capture cleanly
  (use the blocklist or turn capture off for those sites).
- Stream support is HLS VOD only: live streams, DASH (`.mpd`) and SAMPLE-AES
  encryption are not handled yet. The output is a concatenated `.ts`/`.mp4` (no
  ffmpeg remux).
