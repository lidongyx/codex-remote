#!/usr/bin/env bash

set -euo pipefail

MAC_DEVICE_ID="${1:-}"
RELAY_HTTP_URL="${RELAY_HTTP_URL:-http://127.0.0.1:9910}"
DAEMON_HEALTH_URL="${DAEMON_HEALTH_URL:-http://127.0.0.1:9911/health}"

wait_for_json() {
  local url="$1"
  local attempt
  for attempt in {1..20}; do
    if curl --silent --fail "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

wait_for_json "${DAEMON_HEALTH_URL}"
wait_for_json "${RELAY_HTTP_URL}/health"

if [[ -z "${MAC_DEVICE_ID}" ]]; then
  MAC_DEVICE_ID="$(curl --silent --fail "${DAEMON_HEALTH_URL}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["macDeviceId"])')"
fi

echo "[v2] daemon health"
curl --silent --fail "${DAEMON_HEALTH_URL}"
echo
echo "[v2] relay health"
curl --silent --fail "${RELAY_HTTP_URL}/health"
echo
echo "[v2] session resolve for mac=${MAC_DEVICE_ID}"
curl --silent --fail \
  -X POST "${RELAY_HTTP_URL}/v2/session/resolve" \
  -H 'content-type: application/json' \
  -d "{\"mac_device_id\":\"${MAC_DEVICE_ID}\",\"phone_device_id\":\"phone-smoke-1\"}"
echo

echo "[v2] protobuf application probe"
cargo run -p codex-phone-probe-rs --quiet -- "${MAC_DEVICE_ID}"
