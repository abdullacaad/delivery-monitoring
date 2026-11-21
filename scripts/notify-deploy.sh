#!/usr/bin/env bash
# Call this from your pipeline's deploy step (before and/or after the deploy).
#
# 1. Drops a "deploy" annotation on every Grafana dashboard so you can see
#    exactly when a release landed relative to CPU / error / restart changes.
# 2. Optionally silences alerts for that app for a few minutes, so a normal
#    rolling restart does not page anyone (--silence-minutes).
#
# Required env:  GRAFANA_URL            e.g. http://deploy-host:3000
#                GRAFANA_TOKEN          service-account token (or GRAFANA_USER + GRAFANA_PASSWORD)
# Optional env:  ALERTMANAGER_URL       e.g. http://deploy-host:9093 (needed for --silence-minutes)
#
# Usage:
#   notify-deploy.sh --app shop-api --version v1.4.2 --env production \
#                    [--commit abc123] [--pipeline-url https://ci/run/42] [--silence-minutes 5]
set -euo pipefail

APP="" VERSION="unknown" ENVIRONMENT="production" COMMIT="" URL="" SILENCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --commit) COMMIT="$2"; shift 2 ;;
    --pipeline-url) URL="$2"; shift 2 ;;
    --silence-minutes) SILENCE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$APP" ]] || { echo "--app is required" >&2; exit 2; }
: "${GRAFANA_URL:?GRAFANA_URL is required}"

if [[ -n "${GRAFANA_TOKEN:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${GRAFANA_TOKEN}")
elif [[ -n "${GRAFANA_USER:-}" && -n "${GRAFANA_PASSWORD:-}" ]]; then
  AUTH=(-u "${GRAFANA_USER}:${GRAFANA_PASSWORD}")
else
  echo "set GRAFANA_TOKEN or GRAFANA_USER/GRAFANA_PASSWORD" >&2; exit 2
fi

# Keep the text JSON-safe (strip quotes/backslashes/newlines)
clean() { printf '%s' "$1" | tr -d '"\\\n\r'; }
TEXT="Deploy ${APP} ${VERSION} to ${ENVIRONMENT}"
[[ -n "$COMMIT" ]] && TEXT="${TEXT} (commit $(clean "${COMMIT:0:8}"))"
[[ -n "$URL" ]] && TEXT="${TEXT} - $(clean "$URL")"
NOW_MS="$(date +%s)000"

curl -fsS -X POST "${GRAFANA_URL%/}/api/annotations" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"time\": ${NOW_MS}, \"tags\": [\"deploy\", \"app:$(clean "$APP")\", \"env:$(clean "$ENVIRONMENT")\", \"version:$(clean "$VERSION")\"], \"text\": \"$(clean "$TEXT")\"}" \
  >/dev/null
echo "grafana: annotation added for ${APP} ${VERSION}"

if [[ "$SILENCE" -gt 0 ]]; then
  : "${ALERTMANAGER_URL:?ALERTMANAGER_URL is required with --silence-minutes}"
  START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  END="$(date -u -d "+${SILENCE} minutes" +%Y-%m-%dT%H:%M:%SZ)"
  curl -fsS -X POST "${ALERTMANAGER_URL%/}/api/v2/silences" \
    -H "Content-Type: application/json" \
    -d "{\"matchers\": [{\"name\": \"app\", \"value\": \"$(clean "$APP")\", \"isRegex\": false, \"isEqual\": true}],
         \"startsAt\": \"${START}\", \"endsAt\": \"${END}\",
         \"createdBy\": \"pipeline\", \"comment\": \"Deploy of $(clean "$APP") ${VERSION}\"}" \
    >/dev/null
  echo "alertmanager: silenced app=${APP} for ${SILENCE} min"
fi
