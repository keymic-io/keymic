# Observability stack — follow-ups

Tracks remaining work after PR #35 (child-1: TelemetryDeck anonymous diagnostics +
analytics). Full plans live in the Trellis tasks under
`.trellis/tasks/07-18-observability-stack/` (parent) and its two children.

## ⬜ child-2 — Sentry crash/error (NOT YET STARTED)

Task: `.trellis/tasks/07-18-sentry-crash-error/` (prd + design + implement written,
status `planning`). Scope v1 (locked during grilling):

- **Crashes** (automatic via `sentry-cocoa`) + **selective async-error capture** at
  curated `catch` sites (`LLMClient`, model downloads, `ConfigSync`, engine start).
- **Deferred**: performance tracing and log/`os.Logger` forwarding (highest content-leak
  risk — needs a per-call-site audit first).
- New file `CrashReportingService` = the sole `import Sentry` site (mirrors
  `TelemetryDeckSink`'s single-import boundary). `sendDefaultPii=false`, IP off,
  `beforeSend` allowlist scrub, no content in breadcrumbs, no userId.
- Second (and final) new SPM dependency: `getsentry/sentry-cocoa`.
- Sentry DSN goes in `Info.plist` (like `TelemetryDeckAppID` / `SUFeedURL`).

**Shared-toggle wiring (the one integration point with child-1):** the Settings ›
General toggle "Share anonymous diagnostics & crash reports" and the `telemetryEnabled`
flag already exist (this PR). child-2 only needs to add **one line** in that toggle's
onChange handler:
`CrashReportingService.shared.setEnabled(newValue)` — so one consent controls both
tools. Copy already mentions crash reporting, so no UI/first-run-notice change needed.

Recommended: start child-2 **after** PR #35 merges, to avoid two PRs editing the same
toggle handler.

## ⬜ child-1 post-merge verification (this PR)

- **E2E dashboard confirmation** — TelemetryDeck free tier is non-realtime (signals batch
  every few hours). After merge + `make run`, confirm `engine_selected`,
  `permission_state`, `feature_used`, etc. appear in the TelemetryDeck dashboard.
  App ID is already wired in `Info.plist`.

## 🔮 Later (explicitly out of scope for v1)

- Sentry performance tracing / transactions.
- Sentry log / `os.Logger` forwarding (after a log-content audit).
- Onboarding-funnel analytics (no onboarding flow exists yet).
- Per-tool consent granularity (currently one shared toggle).
