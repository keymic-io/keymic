# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✓         |

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email: www@keymic.io

Include:

- description of the vulnerability
- steps to reproduce
- potential impact
- macOS version and KeyMic version

You will receive a response within 7 days. If the issue is confirmed, a fix will be prioritised for the next release.

## Scope

KeyMic runs a session-level `CGEvent` tap (keyboard/mouse events), reads the system clipboard, and optionally calls an LLM endpoint you configure. No data leaves the machine except to that endpoint.

Known privacy characteristics:

- LLM endpoint is optional and user-configured — disabled by default
- Clipboard history is stored locally via SwiftData
- Microphone access is used only while the trigger key is held
