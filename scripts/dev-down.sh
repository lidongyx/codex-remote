#!/usr/bin/env bash

set -euo pipefail

RELAY_PORT="${RELAY_PORT:-9910}"
DAEMON_PORT="${DAEMON_PORT:-9911}"

kill_listeners() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "${pids}" ]]; then
      echo "[v2] stopping listeners on port ${port}: ${pids}"
      echo "${pids}" | xargs kill
    fi
  fi
}

kill_listeners "${RELAY_PORT}"
kill_listeners "${DAEMON_PORT}"
