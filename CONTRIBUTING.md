# Contributing to KeyMic

## Build

```bash
make build   # requires Xcode Command Line Tools
make run     # build + launch
```

macOS 14+ required. No third-party dependencies.

After `make build`, re-grant **Accessibility** access in System Settings — ad-hoc codesigning means every build is a new identity.

## Tests

```bash
make test                     # KeyMappingManager
make test-clipboard-store     # ClipboardStore
make test-clipboard-monitor   # ClipboardMonitor
```

Do not use `swift test` — it will fail. Tests are standalone `swiftc` runners declared in the Makefile.

## Reporting Bugs

Open a GitHub issue. Include:

- macOS version
- steps to reproduce
- what you expected vs. what happened
- relevant logs from `~/Library/Logs/KeyMic.log` (LLM path) or Console.app filtered by `io.keymic.app`

## Pull Requests

PRs welcome for:

- bug fixes
- keyboard/voice/clipboard feature improvements
- test coverage

Before opening a large PR, file an issue first to align on scope. Keep changes focused — one concern per PR.

Read `CLAUDE.md` for architecture overview and `AGENTS.md` for macOS HID / event-tap gotchas before touching `KeyMonitor.swift`.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.
