# Sentry crash/error

## Goal

Capture the technical failures TelemetryDeck cannot see — **crash stacks and
async/await errors** — via the Sentry `sentry-cocoa` SDK, gated by the same shared
consent flag as the analytics child, and hardened so no user content ever leaves the
device.

Scope v1 is deliberately narrow (Q3): **crashes (automatic) + selective async-error
capture**. Performance tracing and log/`os.Logger` forwarding are **deferred** to a
future task after a log-content audit.

## Parent / sibling

- Parent: `07-18-observability-stack` (owns shared consent, privacy red-lines,
  dependency budget). Sibling: `07-18-telemetry-telemetrydeck` — builds and owns the
  shared consent flag `telemetryEnabled`, the Settings toggle, and the first-run notice.
  **This task ships after child-1** and reuses that flag.

## Confirmed facts (from research, 2026-07-18)

- `sentry-cocoa` supports macOS (min macOS 11; KeyMic targets 14). SPM is the
  recommended integration; CocoaPods dropped. Actively maintained (9.x).
- Free Developer tier: 5k errors/month, hard-capped, no PAYG (over-quota events
  dropped, no bill). Adequate for current scale; crashes+selective errors stay well
  under 5k.
- Sentry supports `sendDefaultPii=false`, IP disable, server-side data scrubbing, and a
  `beforeSend` hook for full client-side control of the payload.
- Sentry DSN is a client-embedded identifier (semi-public), safe to place in
  `Info.plist` alongside `SUFeedURL` / `TelemetryDeckAppID`.

## Requirements

### Functional

1. Initialize `SentrySDK` at launch **only when** the shared `telemetryEnabled` flag is
   true, reading the DSN from `Info.plist`. When the flag is false, Sentry is never
   started.
2. Enable **automatic crash capture** (the SDK's default) — no per-crash code.
3. **Selective async-error capture**: at a curated set of `catch` sites where failures
   are otherwise silent (e.g. `LLMClient`, model downloads, config sync, speech engine
   start), call `SentrySDK.capture(error:)` with a coarse, content-free context. Not a
   blanket capture of every error.
4. Runtime gate: when the user turns the shared toggle off, stop sending
   (`SentrySDK.close()` / gate at the wrapper). No re-init until toggled on + relaunch
   if `close()` is terminal.
5. No new Settings UI and no new first-run notice — both are provided by child-1 and
   already mention crash reporting.

### Privacy hardening (non-negotiable, from parent red-lines)

6. `sendDefaultPii = false`; IP capture disabled.
7. A `beforeSend` hook that: strips/scrubs any event whose payload could carry content,
   and drops breadcrumbs that are not known-safe. **No transcript / clipboard / key /
   OCR / secret text is ever attached** to an event, breadcrumb, tag, or context.
8. Error captures attach only coarse error kinds / enum labels / file-level context —
   never message text derived from user data.
9. Fully anonymous — no account `userId` set on the Sentry scope.

### Non-functional

10. A thin `CrashReportingService` wrapper is the sole `import Sentry` site (mirrors
    child-1's `TelemetryService` boundary), so gating + `beforeSend` live in one place.
11. Debug builds distinguishable from release via Sentry `environment`; Debug events
    must not pollute the production issue stream (use a `debug` environment or disable
    in Debug as chosen at implementation).
12. Telemetry paths never crash or block the main thread.

## Acceptance criteria

- [ ] With the shared toggle ON, a forced test crash appears in the Sentry dashboard
      with a symbolicated stack; a forced captured async error appears as an issue.
- [ ] With the shared toggle OFF, `SentrySDK` is not initialized and no network call is
      made to Sentry (Charles/Console).
- [ ] No event, breadcrumb, tag, or context carries transcript/clipboard/key/OCR/secret
      content (verified: `beforeSend` review + manual dashboard inspection of a real
      captured error).
- [ ] `import Sentry` appears in exactly one file (`CrashReportingService`).
- [ ] Debug crashes/errors do not land in the production environment/issue stream.
- [ ] Sentry added as the second new SPM dependency; release build codesigns and runs;
      DSN in `Info.plist` keeps `plutil -lint` clean.

## Out of scope (YAGNI, deferred)

- Performance tracing / transactions / spans.
- Log / `os.Logger` forwarding (highest content-leak risk; needs a per-call-site audit
  first — separate future task).
- Blanket capture of all thrown errors.
- Any Settings UI / first-run notice (owned by child-1).
- Account/userId correlation, self-hosted Sentry, session replay.
