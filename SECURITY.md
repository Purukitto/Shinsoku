# Security Policy

## Supported versions

Shinsoku is pre-1.0 and under active development. Security fixes are applied to the latest
`main` branch.

| Version | Supported |
|---|---|
| `main` (latest) | ✅ |
| older builds | ❌ |

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, report privately using one of:

1. **GitHub Security Advisories** — preferred. Go to the repository's
   **Security → Report a vulnerability** tab
   ([Privately reporting a vulnerability](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).
2. **Email** — `purukitto@gmail.com` with the subject line `Shinsoku security`.

Please include:

- A description of the issue and its impact.
- Steps to reproduce (proof-of-concept if possible).
- Affected component (engine, UI, or browser extension) and your environment.

You can expect an initial acknowledgement within a few days. We'll keep you updated on the
fix and coordinate a disclosure timeline with you.

## Scope & threat model notes

Shinsoku has a couple of locally-exposed surfaces worth understanding:

- **Loopback capture server.** The browser-extension integration runs a small HTTP server
  bound to `127.0.0.1` and guarded by a **pairing token**. It is not intended to be exposed
  beyond the local machine. Reports about token handling, request authentication, or
  binding scope are in scope.
- **Downloaded content.** Shinsoku downloads and assembles files (including AES-128
  decryption of HLS segments). Issues such as path traversal in suggested filenames,
  integrity-check bypass, or unsafe parsing of remote playlists/manifests are in scope.
- **Custom headers / cookies.** The extension forwards cookies, referrer and User-Agent to
  the engine. Reports about leaking or mishandling these are in scope.

Thank you for helping keep Shinsoku and its users safe. 🙏
