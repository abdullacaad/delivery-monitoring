#!/usr/bin/env bash
# Verifies the monitoring stack itself is healthy. Run after `docker compose up -d`.
set -uo pipefail
P="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
A="${ALERTMANAGER_URL:-http://127.0.0.1:9093}"
G="${GRAFANA_URL:-http://127.0.0.1:3000}"
fail=0
check() { if curl -fsS "$2" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1 ($2)"; fail=1; fi; }

echo "Endpoints"
check "prometheus"   "$P/-/ready"
check "alertmanager" "$A/-/ready"
check "grafana"      "$G/api/health"

echo "Scrape targets (job: up/total)"
curl -fsS "$P/api/v1/targets?state=active" 2>/dev/null \
 | tr '{' '\n' | grep -o '"job":"[^"]*"\|"health":"[^"]*"' | paste - - 2>/dev/null \
 | sort | uniq -c | sed 's/^/  /'
exit $fail
