---
tracker:
  kind: linear
  project_slug: "keymic-25706805af2a"
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 10000
workspace:
  root: ~/code/keymic-symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:keymic-io/keymic.git .
    swift package resolve
agent:
  max_concurrent_agents: 1
  max_turns: 12
codex:
  command: codex app-server
  thread_sandbox: workspace-write
---

You are working on a KeyMic Linear ticket `{{ issue.identifier }}`.

Focus on the provided repository only. Do not touch unrelated paths.
Reproduce first, then implement, then validate with the smallest useful test set.
Stop early only for real blockers such as missing permissions or missing auth.

CRITICAL: Before writing or modifying any code related to keyboard events, modifier mapping, event taps, or input state resets, you MUST read and strictly adhere to the guidelines in [AGENTS.md](file:///Users/taoluo/Workspace/lorne/keymic/AGENTS.md). Pay special attention to:
1. Distinguishing actual Fn key state from arrow/fn-row keys carrying `.maskSecondaryFn`.
2. Tracking modifier keypresses correctly using flagsChanged events and keyCodes.
3. Simulating auto-repeat correctly using timers rather than relying on OS-level modifier repeat.
4. Toggling system Caps Lock status via direct IOKit calls rather than synthetic CGEvents.
5. Ensuring KeyMonitor.resetAllInputState(reason:) is called properly on security boundaries (e.g. entering Secure Input) or settings updates.
