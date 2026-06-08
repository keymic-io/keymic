#!/bin/sh
# Dev run: rebuild, install, launch, then tail the app's logs at DEBUG level.
#
# os.Logger levels and capture:
#   - debug          : ephemeral, NOT persisted to the on-disk archive. Only visible via a
#                      live `log stream` (this script) — that is the "dev" verbosity.
#   - info           : in-memory buffer; visible while streaming, evicted quickly otherwise.
#   - notice/warning : persisted to the archive (the default capture level).
#   - error/fault    : persisted.
# A release build needs no special handling: with no live stream, the system persists
# notice/warning/error/fault and surfaces info+ in Console — debug stays silent ("info 以上").
set -e

pkill -x KeyMic || true
make build && make install && open /Applications/KeyMic.app

# Foreground stream at debug so the developer sees every log line until Ctrl-C.
#exec log stream --predicate 'subsystem == "io.keymic.app"' --level debug --style compact
