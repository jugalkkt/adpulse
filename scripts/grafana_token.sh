#!/usr/bin/env bash
# Create (once) a Grafana service account "adpulse-healer" (role Editor, needed
# to write annotations) and store its token in .env as GRAFANA_SA_TOKEN.
# Idempotent; never prints the token or the admin password.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
JQ=/usr/bin/jq

admin_pw="$(grep -E '^GRAFANA_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
token="$(grep -E '^GRAFANA_SA_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)"

if ! curl -fsS -o /dev/null --max-time 3 "$URL/api/health"; then
  echo "grafana-token: Grafana not reachable at $URL; skipping (re-run after 'make monitoring')."
  exit 0
fi

if [[ -n "$token" ]] && [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "$URL/api/annotations?limit=1")" == 200 ]]; then
  echo "grafana-token: existing GRAFANA_SA_TOKEN is valid."
  exit 0
fi

api() {  # api <method> <path> [json]
  curl -fsS -u "admin:$admin_pw" -H 'Content-Type: application/json' -X "$1" "$URL$2" ${3:+--data "$3"}
}

sa_id="$(api GET '/api/serviceaccounts/search?query=adpulse-healer' | $JQ -r '.serviceAccounts[] | select(.name=="adpulse-healer") | .id' | head -n1)"
if [[ -z "$sa_id" ]]; then
  sa_id="$(api POST /api/serviceaccounts '{"name":"adpulse-healer","role":"Editor","isDisabled":false}' | $JQ -r .id)"
  echo "grafana-token: created service account adpulse-healer (id $sa_id)."
fi
new="$(api POST "/api/serviceaccounts/$sa_id/tokens" "{\"name\":\"healer-$(date -u +%Y%m%dT%H%M%SZ)\"}" | $JQ -r .key)"
[[ -n "$new" && "$new" != null ]] || { echo "grafana-token: token creation failed" >&2; exit 1; }

if grep -qE '^GRAFANA_SA_TOKEN=' "$ENV_FILE"; then
  tmp="$(mktemp "$ROOT/.env.XXXXXX")"
  chmod 600 "$tmp"
  awk -v t="$new" 'BEGIN{FS=OFS="="} /^GRAFANA_SA_TOKEN=/{print "GRAFANA_SA_TOKEN=" t; next} {print}' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
else
  printf 'GRAFANA_SA_TOKEN=%s\n' "$new" >> "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"
echo "grafana-token: new token stored in .env (not printed)."
