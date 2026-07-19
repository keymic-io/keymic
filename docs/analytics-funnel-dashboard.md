# Activation funnel — baseline dashboard recipe

Ties the funnel in KEY-2 (download → install → activation → day-7 retained) to
concrete signals already flowing through the existing TelemetryDeck integration
(`Sources/KeyMic/Telemetry/`, see CLAUDE.md § Telemetry). No new telemetry provider,
no PII, no self-hosted backend — this only wires up dashboard views on top of what
the app already emits (plus one public, non-PII source outside the app: GitHub
release asset counts).

## Funnel legs → data source

| Funnel leg | Signal | Where it comes from |
|---|---|---|
| **Download** | GitHub release asset `download_count` | Not app-instrumented (pre-install, nothing to instrument). Public GitHub API, per-asset, no PII. |
| **Install** | TelemetryDeck's automatic session/launch signal | Already sent by the SDK itself on first app launch — no manual `app_launch` signal exists or is needed (see CLAUDE.md). One signal per anonymous install id. |
| **Activation** | `activation_first_remap`, `activation_first_transcription`, `activation_first_clipboard_use` | Fired once ever, first time each core loop (remap / voice / clipboard) is used. Any one of the three counts as "activated" per the issue's definition ("first remap / voice / clipboard use"). |
| **Retained (day-7)** | Recurrence of the same session signal from the same anonymous id, 7 days after install | TelemetryDeck computes this natively from signal timestamps grouped by anonymous user id — no extra event needed, as long as the app keeps sending at least one signal per session (it already does). |

All four legs are content-free: no transcript text, clipboard content, keys, or
identity — consistent with the existing telemetry red-line in CLAUDE.md.

## Downloads — pull command (no dashboard login needed)

```bash
gh api repos/keymic-io/keymic/releases --paginate \
  --jq '.[] | {tag: .tag_name, published: .published_at, assets: [.assets[] | {name, download_count}]}'
```

Run this weekly (or wire into a scheduled job) and log the total across assets per
release. This is the only funnel leg that lives outside TelemetryDeck.

## TelemetryDeck dashboard setup (manual — requires TelemetryDeck org login)

This part cannot be scripted headlessly: TelemetryDeck's Insights/Funnels are
built in their web UI and the account credentials are not available in this
environment. **Whoever holds the TelemetryDeck org login (CEO or Growth) needs to
do this one-time setup:**

1. **Funnel insight** — Insights → New Insight → Funnel.
   - Step 1: any signal (this is every session/launch — TelemetryDeck's default
     "any signal" step approximates install).
   - Step 2: signal name matches `activation_first_*` (use the "starts with"
     matcher, or three OR'd insights if the UI needs exact names) — this is
     activation.
   - Group by: nothing (aggregate counts only — no per-user breakdown needed for
     a company-wide baseline).
2. **Retention insight** — Insights → New Insight → Retention, based on any
   signal, Day 7 cohort. TelemetryDeck computes this from anonymous id recurrence
   automatically.
3. **Adoption breakdown** (optional but cheap) — a bar chart of `feature_used`
   grouped by the `feature` parameter, to see which of keymap/hotkey/voice/
   persona/clipboard/screenshot/vault is pulling weight.
4. Pin all of the above to a dashboard named e.g. "Growth funnel" and share the
   read-only dashboard link with the CEO and Growth — TelemetryDeck supports
   read-only share links per dashboard.

## Verification

End-to-end verification requires an actual fresh macOS install (this repo has no
Swift toolchain in the Linux dev sandbox used to write this code, and there is no
macOS CI runner in this repo's GitHub Actions — only `ocr-review.yml` and Pages
deployment). To verify after merge:

1. `make build` on a Mac, install fresh, grant permissions.
2. Do one remap toggle, one voice loop, one clipboard-panel open.
3. Confirm three `activation_first_*` signals + the install-implying session
   signal land in the TelemetryDeck Test Mode view (`DEBUG` builds set
   `config.testMode = true`, per `TelemetryDeckSink.makeIfConfigured()`).
4. Wait for the TelemetryDeck free-tier batch window (non-realtime, batches every
   few hours per `docs/observability-followups.md`) and confirm the same
   signals appear in the funnel/retention Insights built above.
