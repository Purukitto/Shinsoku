# Security policy

## Supported versions

Shinsoku is pre-1.0. Only the latest release gets fixes.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No |

A fix ships as a patch release, with an entry under `### Security` in
[CHANGELOG.md](CHANGELOG.md). Running copies see it through the in-app update notice
at their next launch.

## Reporting a vulnerability

Please do not open a public issue.

Use GitHub's private reporting form —
[**Report a vulnerability**](https://github.com/Purukitto/Shinsoku/security/advisories/new)
— or email <purukitto@gmail.com> with `Shinsoku security` in the subject.

Include what you did, what happened, and the version or commit. Say which part is
involved: the engine, the app, the browser extension or the capture server. A proof of
concept helps but is not required to file.

This is a personal project maintained in spare time, so expect an acknowledgement
within about a week rather than within hours. Once a fix is out, the advisory is
published with credit to you unless you would rather not be named.

## What is in scope

Shinsoku runs with the privileges of the user who started it, fetches whatever URLs it
is given, and writes files to disk. The interesting surface is what it accepts and
where it writes:

- **The capture server.** A loopback HTTP server on `127.0.0.1`, guarded by a pairing
  token and off until enabled. A way for a web page, another local user or a request
  without the token to add downloads, read state or reach anything else is in scope,
  as is binding beyond loopback.
- **Where files land.** A server-supplied filename, a playlist URI or a capture payload
  that writes outside the chosen download folder — path traversal, overwriting an
  existing file, a reserved device name — is in scope.
- **Parsing remote input.** HLS playlists, AES-128 keys and IVs, and HTTP responses
  are untrusted. A crash, hang or unbounded allocation driven by a malicious server is
  in scope.
- **Integrity checks.** A way to get **VERIFIED** shown for a file that does not match
  the expected digest.
- **Credentials.** Cookies and headers forwarded by the extension being sent to a host
  other than the one the download was for, or exposed beyond the local data file.
- **The update check.** It reads GitHub's release feed and opens the release page. A
  way to make it open anything else, or to make Shinsoku fetch or run code from it, is
  in scope.
- **Release integrity.** Anything that lets a build, a release asset or
  `SHA256SUMS.txt` carry code that was not in the tagged source.

## What is not in scope

- The binaries are unsigned, so SmartScreen warns on first launch. This is known and
  listed in the README.
- The download store keeps request headers, including cookies the extension forwarded,
  in plain text under `%APPDATA%`, readable by your Windows account. That is the
  documented design; a way for *another* account to read it is in scope.
- Shinsoku downloads what you ask it to. That a URL served malware is not a Shinsoku
  vulnerability.
- Anything requiring an attacker who already has code execution as your user account.
- Vulnerabilities in Flutter, `reqwest`, `tokio`, `axum` or another dependency —
  report those upstream. If a Shinsoku setting or default makes one meaningfully worse,
  that part is in scope.
