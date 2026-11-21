#!/usr/bin/env bash
# Post-deploy gate for your pipeline: fail the job if the app is not healthy
# in Prometheus shortly after the deploy. Turns monitoring into a release check.
#
# Usage: PROMETHEUS_URL=http://deploy-host:9090 verify-deploy.sh <app> [timeout_seconds]
set -euo pipefail

APP="${1:?usage: verify-deploy.sh <app> [timeout_seconds]}"
TIMEOUT="${2:-120}"
: "${PROMETHEUS_URL:?PROMETHEUS_URL is required}"

query() { curl -fsS -G "${PROMETHEUS_URL%/}/api/v1/query" --data-urlencode "query=$1"; }
value() { sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p' | head -n1; }

deadline=$(( $(date +%s) + TIMEOUT ))
echo "Waiting up to ${TIMEOUT}s for '${APP}' to be up in Prometheus..."
while :; do
  UP="$(query "min(up{job=\"deployed-apps\",app=\"${APP}\"})" | value || true)"
  if [[ "${UP:-}" == "1" ]]; then break; fi
  if (( $(date +%s) >= deadline )); then
    echo "FAIL: ${APP} did not become healthy within ${TIMEOUT}s" >&2; exit 1
  fi
  sleep 5
done
echo "OK: ${APP} is up"

# Give it a short soak, then make sure it did not crash-loop
sleep 30
RESTARTS="$(query "sum(changes(container_start_time_seconds{container_label_monitoring_app=\"${APP}\"}[3m]))" | value || true)"
if [[ "${RESTARTS:-0}" != "0" ]]; then
  echo "FAIL: ${APP} restarted ${RESTARTS} time(s) right after deploy" >&2; exit 1
fi

ERR="$(query "sum(rate(http_requests_total{app=\"${APP}\",code=~\"5..\"}[2m])) / sum(rate(http_requests_total{app=\"${APP}\"}[2m]))" | value || true)"
if [[ -n "${ERR:-}" && "${ERR}" != "NaN" ]] && awk "BEGIN{exit !(${ERR} > 0.05)}"; then
  echo "FAIL: 5xx error ratio ${ERR} exceeds 5%" >&2; exit 1
fi
echo "PASS: ${APP} is healthy after deploy"
