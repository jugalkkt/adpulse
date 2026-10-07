#!/usr/bin/env bash
# Smoke test one environment through nginx. Exit non-zero on any failure.
#   scripts/smoke_test.sh <staging|prod|aws-prod> [base_url]
# Checks: /readyz 200; 20x /v1/ad valid JSON with ad.id; p95 < 300 ms;
#         /metrics reachable on a replica (docker exec; honours DOCKER_HOST).
set -euo pipefail

ENV_NAME="${1:?usage: smoke_test.sh <env> [base_url]}"
case "$ENV_NAME" in
  staging) default_url="http://127.0.0.1:8081" ;;
  prod)    default_url="http://127.0.0.1:8080" ;;
  *)       default_url="" ;;
esac
BASE_URL="${2:-$default_url}"
[[ -n "$BASE_URL" ]] || { echo "base_url required for $ENV_NAME" >&2; exit 2; }
JQ=/usr/bin/jq
P95_LIMIT_MS="${P95_LIMIT_MS:-300}"
fail=0
pass() { echo "PASS  $*"; }
bad()  { echo "FAIL  $*"; fail=1; }

echo "smoke test: env=$ENV_NAME url=$BASE_URL"

# 1. readiness (allow up to 30s for a fresh deploy to settle)
code=000
for _ in $(seq 1 15); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE_URL/readyz" || true)"
  [[ "$code" == 200 ]] && break
  sleep 2
done
if [[ "$code" == 200 ]]; then pass "/readyz 200"; else bad "/readyz returned $code"; fi

# 2. 20 ad requests
cats=(sports tech fashion travel finance food)
segs=(student young_professional parent retiree all)
times=()
ok=0
for i in $(seq 1 20); do
  c="${cats[$((i % ${#cats[@]}))]}"; s="${segs[$((i % ${#segs[@]}))]}"
  out="$(curl -s --max-time 3 -w '\n%{http_code} %{time_total}' "$BASE_URL/v1/ad?category=$c&segment=$s" || true)"
  body="$(head -n -1 <<<"$out")"; meta="$(tail -n 1 <<<"$out")"
  status="${meta%% *}"; t="${meta##* }"
  times+=("$t")
  if [[ "$status" == 200 ]] && $JQ -e '.ad.id != null and .request_id != null and (.source | IN("cache","db","fallback"))' >/dev/null 2>&1 <<<"$body"; then
    ok=$((ok + 1))
  else
    echo "      request $i ($c/$s): status=$status body=${body:0:120}"
  fi
done
if [[ "$ok" -eq 20 ]]; then pass "20/20 /v1/ad valid (JSON with ad.id)"; else bad "$ok/20 /v1/ad valid"; fi

# 3. p95 latency of those 20 calls
p95_ms="$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {i=int(0.95*NR); if (i<1) i=1; printf "%d", a[i]*1000}')"
if [[ "$p95_ms" -lt "$P95_LIMIT_MS" ]]; then pass "p95 ${p95_ms} ms < ${P95_LIMIT_MS} ms"; else bad "p95 ${p95_ms} ms >= ${P95_LIMIT_MS} ms"; fi

# 4. /metrics on a replica (not exposed through nginx)
replica="$(docker ps --filter "label=com.adpulse.env=$ENV_NAME" --filter label=com.adpulse.role=api \
  --filter status=running --format '{{.Names}}' | grep -E "^api-$ENV_NAME-[0-9]+$" | sort | head -n1 || true)"
if [[ -n "$replica" ]] && docker exec "$replica" curl -fsS --max-time 3 http://127.0.0.1:8000/metrics | grep -q '^adpulse_build_info'; then
  pass "/metrics reachable on $replica"
else
  bad "/metrics not reachable on a replica (${replica:-none running})"
fi

echo
if ((fail)); then echo "SMOKE: FAIL"; exit 1; fi
echo "SMOKE: PASS"
