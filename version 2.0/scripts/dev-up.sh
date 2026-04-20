#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RELAY_BIND_ADDR="${RELAY_BIND_ADDR:-127.0.0.1:9910}"
DAEMON_HEALTH_BIND_ADDR="${DAEMON_HEALTH_BIND_ADDR:-127.0.0.1:9911}"
RELAY_HTTP_URL="${RELAY_HTTP_URL:-http://127.0.0.1:9910}"
RELAY_WS_BASE_URL="${RELAY_WS_BASE_URL:-ws://127.0.0.1:9910}"

cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
}

trap cleanup EXIT INT TERM

echo "[v2] starting codex-relay-rs on ${RELAY_BIND_ADDR}"
(
  cd "${ROOT_DIR}"
  CODEX_RELAY_BIND_ADDR="${RELAY_BIND_ADDR}" cargo run -p codex-relay-rs --quiet
) &

sleep 1

echo "[v2] starting codexd on ${DAEMON_HEALTH_BIND_ADDR}"
(
  cd "${ROOT_DIR}"
  CODEXD_HEALTH_BIND_ADDR="${DAEMON_HEALTH_BIND_ADDR}" \
  CODEXD_RELAY_HTTP_URL="${RELAY_HTTP_URL}" \
  CODEXD_RELAY_WS_BASE_URL="${RELAY_WS_BASE_URL}" \
  cargo run -p codexd --quiet
) &

echo "[v2] relay health:  ${RELAY_HTTP_URL}/health"
echo "[v2] daemon health: http://${DAEMON_HEALTH_BIND_ADDR}/health"
echo "[v2] press Ctrl+C to stop"

wait
