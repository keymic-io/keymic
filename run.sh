#!/usr/bin/env bash
set -euo pipefail

pkill -x KeyMic || true
make build
open KeyMic.app
