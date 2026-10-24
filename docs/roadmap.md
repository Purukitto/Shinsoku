# Roadmap to 1.0

Everything on this page ships in Shinsoku 1.0, on **both Android and desktop** (Windows,
then Linux). The page tracks how far along that is. It describes the code as it stands;
when a row changes, change it in the same pull request.

**Done** works on Windows today. **Partial** exists but falls short of what the row
describes. **Not started** is not built yet. Everything in the engine (`core/`) is shared, so it reaches
Android once the Android build is wired. Rows marked *Android* need Android-specific work
beyond that.

## Platforms

| Feature | Status | Notes |
| --- | --- | --- |
| Windows app | Done | Portable zip, no installer yet |
| Android app | Partial | Android 11 and later, in a phone layout, saving to `Download/Shinsoku`. APKs on each GitHub release; not on Google Play yet |
| Linux app | Done | A tarball on each release, no distribution package yet |

## Downloading

| Feature | Status | Notes |
| --- | --- | --- |
| Multi-part downloads, up to 32 parts | Partial | The engine takes up to 32; the UI stops at 16 |
| Pause and resume, across restarts | Done | |
| Automatic retry that never corrupts the file | Done | |
| Refresh an expired link | Done | Paste a new link, or catch it from the browser |
| Resume on its own after the app is killed | Partial | Interrupted downloads come back paused; scheduled ones wait for off-peak hours again |
| Simultaneous downloads, up to 30 | Partial | 1–8 in Settings; the engine takes 16 |
| Speed limiter | Done | One global limit |
| Scheduler: start and stop at set times | Done | Scheduled downloads run during off-peak hours, on the days you pick |
| Daily download or data limit | Not started | |
| Wi-Fi only, pause on mobile data | Not started | *Android* |
| Large files | Done | |
| Keep downloading in the background | Done | The tray on desktop; a foreground service on Android, which Android 15 and later allow six hours a day |
| Progress and completion notifications | Partial | Progress in a silent Android notification and in the tray (on hover on Windows, atop the menu on Linux). Nothing says when a download finishes yet |
| After-download actions (move file, turn off Wi-Fi, exit) | Not started | |
| Name and folder per download before it starts | Not started | |
| When a name is taken: rename, overwrite or skip | Partial | Rename only |
| Downloads that need a login (basic auth) | Partial | Through a custom `Authorization` header |
| Custom User-Agent | Partial | Through a custom header |
| Checksums: MD5, SHA-1, SHA-256, compare with clipboard | Partial | MD5 and SHA-256, verified against a digest given at add time |
| Start all, pause all, stop all | Not started | |
| Hidden download folder | Not started | *Android* |
| Sort files into folders by type | Done | |
| Search, sort and filter the list | Not started | The search box is a placeholder |

## Catching links

| Feature | Status | Notes |
| --- | --- | --- |
| Offer to download a copied link | Partial | Desktop only. *Android* |
| Take downloads from the browser | Partial | Desktop, through the extension. *Android*: the share menu and opening links |
| Import links from a text file or the clipboard | Not started | |
| Batch download by pattern (`file[1-20].jpg`) | Not started | |
| Grab every file on a page | Not started | |

## Video and streams

| Feature | Status | Notes |
| --- | --- | --- |
| HLS (`.m3u8`) | Partial | Video on demand; AES-128. No live streams, no `SAMPLE-AES` |
| `.m3u` playlists | Not started | |
| MPEG-DASH | Not started | |
| Convert `.ts` to `.mp4` when done | Not started | |
| Join separate audio and video streams | Not started | |
| Spot videos on a page | Partial | The extension spots HLS on desktop. *Android* needs the built-in browser |
| Built-in player: play while downloading, picture-in-picture | Not started | |

## Torrents

| Feature | Status | Notes |
| --- | --- | --- |
| Magnet links, torrent URLs, `.torrent` files | Not started | |
| Pick files and priorities, trackers, peer exchange, recheck | Not started | |
| Seeding and the upload cap | Not started | The **Cap upload / seeding** setting is saved but does nothing |

## Built-in browser

On Android, a built-in browser is how people find and catch downloads.

| Feature | Status | Notes |
| --- | --- | --- |
| Tabs, history, bookmarks | Not started | |
| Ad, tracker and pop-up blocking with filter lists | Not started | |
| Incognito mode, clearing history, cache and cookies | Not started | |
| Userscripts, page translation, hiding page elements | Not started | |
| Custom DNS (DNS over HTTPS or TLS) | Not started | |
| Password manager with autofill | Not started | |

## The app

| Feature | Status | Notes |
| --- | --- | --- |
| Themes, following the system light or dark mode | Done | System, light or dark in Settings, with a true-black dark mode for OLED screens |
| Other languages | Not started | English only |
| Backup and restore of the list and settings | Not started | |
| Lock the app with a PIN or fingerprint | Not started | |
| Start with the system | Partial | Windows at sign-in, hidden in the tray; Linux writes an XDG autostart entry. *Android*: starting on boot needs only the install-time `RECEIVE_BOOT_COMPLETED` permission, but Android 15 won't let it start the download service directly |

## Out of scope

- **YouTube.** Downloading from it is not planned.

## Open questions

- **A built-in browser on desktop.** On Windows and Linux the extension already catches
  downloads in the browser people use. Bringing the built-in browser there as well is a
  choice still to make.
- **Torrent engine.** Which library, or whether to write one, is not decided.
