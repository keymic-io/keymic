# Anonymous diagnostics telemetry via TelemetryDeck

## Goal

Give KeyMic a way to see failures that only happen on other people's machines —
speech-engine selection, model downloads, and permission / event-tap failures —
without collecting any user content. Diagnostics-first, not product analytics.

At the current stage (spike / single developer, small user base) the highest-value
signal is compatibility and permission failure across the long tail of machines,
OS versions, locales, and networks — data that cannot be reproduced on one Mac.

## Constraints

- **Privacy is a core product value.** KeyMic reads keyboard, clipboard, voice, and
  OCR. Telemetry must never carry any content (no transcripts, clipboard text, key
  sequences, OCR results, secrets). Only event counts, enum values, durations, and
  error kinds.
- **Minimize self-development.** No self-hosted backend, no HMAC, no on-disk queue.
  Use a third-party SDK that batches/transports on its own.
- **Match KeyMic's minimalism.** At most one new lightweight SPM dependency (KeyMic
  today has only Sparkle 2). No vendored native libraries.
- macOS 14 target; the app is not sandboxed.

## Decisions (locked during grilling)

- **Provider: TelemetryDeck** (Swift SDK `TelemetryDeck/SwiftSDK`, stable 2.14.x).
  Chosen over PostHog (heavier platform + vendored crash deps + US-cloud/non-privacy
  brand), Aptabase (SDK maintenance stalled), and Sentry (error-monitoring tool, wrong
  fit — reserved for future crash reporting). Free tier 50k signals/month is ample for
  current scale; privacy posture (double-hashed anonymous ID, no PII, GDPR "truly
  anonymous") matches the KeyMic brand.
- **Identity: fully anonymous.** No userId is attached even when signed in. Rely on
  TelemetryDeck's built-in stable per-install anonymous ID.
- **Consent: opt-out.** Enabled by default; a toggle in Settings › General turns it
  off (when off, the SDK is not initialized and no signal is sent). A one-time
  first-run notification informs the user.
- **Transport cadence is ceded to the SDK** (no daily-flush control). Accepted trade-off
  of using a third-party SDK.

## Requirements

### Functional

1. On launch (when telemetry is enabled), initialize the TelemetryDeck SDK with the
   app ID read from `Info.plist`.
2. Emit the following **diagnostic** signals (payload values are strings; no content):
   - `engine_selected` — `{model, engine, osMajor, locale}` (result of `SpeechEngineFactory.choose`).
   - `model_download` — `{model, result, durationMs, source, errorKind?}`.
   - `engine_cold_start` — `{engine, firstBufferMs, scoWatchdogFired}`.
   - `transcribe_error` — `{engine, errorKind}`.
   - `permission_state` — launch snapshot `{mic, speech, accessibility, screenCapture}`.
   - `event_tap_failed` — emitted when `CGEvent.tapCreate` returns nil.
2b. Emit the following **adoption/analytics** signals (low-cardinality enums; no content):
   - `feature_used` — `{feature}`, `feature ∈ {voice, clipboard, persona, keymap, hotkey, screenshot, vault}`; emitted at each feature entrypoint.
   - `persona_invoked` — `{persona, injectionStrategy}` (`persona` = built-in name or stable id, never the user's custom prompt text); at `PersonaEngine.run`.
   - `hotkey_action` — `{action}` (HotkeyAction case name); at `HotkeyActionRunner`.
   - `activation_first_transcription` — fired once ever, on the user's first successful voice transcription (activation milestone; replaces the non-existent onboarding funnel).
   - No onboarding-funnel events (no onboarding flow exists on this branch).
3. Do NOT hand-roll an `app_launch` signal — rely on TelemetryDeck's automatic
   session/launch signal (carries appVersion/OS/arch). Verify this during
   implementation; only add a manual one if the SDK does not send it.
4. A single `TelemetryService` wrapper gates every emission on the opt-out preference,
   so no call site can bypass the toggle.
5. Settings › General shows the **shared** consent toggle "Share anonymous diagnostics
   & crash reports" (default on). This task builds that toggle and its backing shared
   flag; the Sentry child (`07-18-sentry-crash-error`) reuses the same flag. Turning it
   off stops all TelemetryDeck emission immediately (no init, no signals) — and, once
   the Sentry child ships, suppresses Sentry too.
6. First-run: show a one-time notice that anonymous diagnostics **and crash reporting**
   are on, carry no content, and can be disabled in Settings. (Copy already covers
   crash reporting so it need not change when the Sentry child ships.)

### Non-functional

- Debug builds must be able to self-test emission (handle TelemetryDeck's default
  "test signal" flag / Test Mode).
- Telemetry code paths must never crash or block the main thread; failures to send are
  silent.

## Acceptance Criteria

- [ ] With telemetry ON, launching the app and using voice produces `engine_selected`,
      `permission_state`, and (on a fresh model) `model_download` signals visible in the
      TelemetryDeck dashboard (Test Mode during dev).
- [ ] Using each feature emits `feature_used`; invoking a persona emits
      `persona_invoked`; a hotkey action emits `hotkey_action`; the first ever successful
      transcription emits `activation_first_transcription` exactly once (persists across
      launches).
- [ ] With the Settings toggle OFF, no signals are emitted and the SDK is not
      initialized (verified: no network calls to TelemetryDeck).
- [ ] No signal payload contains any transcript, clipboard, key, OCR, or secret data —
      only the enumerated fields.
- [ ] `event_tap_failed` is emitted on the `CGEvent.tapCreate == nil` path before the
      app shows its accessibility alert and quits.
- [ ] First-run notice appears exactly once; the toggle persists across launches.
- [ ] Exactly one new SPM dependency added (TelemetryDeck), no vendored native libs;
      release build still codesigns and runs.

## Parent / sibling

- Parent: `07-18-observability-stack` (shared consent, privacy red-lines, dependency
  budget). Sibling: `07-18-sentry-crash-error` (crash/error via Sentry, reuses this
  task's shared consent flag & toggle).

## Explicitly out of scope (YAGNI)

- Onboarding-funnel events (no onboarding flow exists; `activation_first_transcription`
  is the single milestone instead).
- Sparkle update-funnel events.
- Crash reporting / error / performance / logs — that is the Sentry sibling task.
- `single_instance_conflict` event.
- Any self-hosted backend, keymic-web endpoint, Prisma table, HMAC, or on-disk queue.
- Attaching account userId to signals.
