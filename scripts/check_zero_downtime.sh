#!/usr/bin/env bash
# Send requests in a tight loop through nginx and count non-200 responses.
# Run it in the background during a deploy:
#   scripts/check_zero_downtime.sh <env> <seconds> [result_file]
# Exit 1 if any request failed.
set -euo pipefail

ENV_NAME="${1:?usage: check_zero_downtime.sh <env> <seconds> [result_file]}"
SECONDS_TO_RUN="${2:?seconds required}"
RESULT="${3:-/dev/stdout}"
case "$ENV_NAME" in
  staging) url="http://127.0.0.1:8081" ;;
  prod)    url="http://127.0.0.1:8080" ;;
  *) echo "unknown env" >&2; exit 2 ;;
esac

total=0 failed=0
declare -A codes=()
end=$(( $(date +%s) + SECONDS_TO_RUN ))
while (( $(date +%s) < end )); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url/v1/ad?category=tech&segment=student" || true)"
  total=$((total + 1))
  codes[$code]=$(( ${codes[$code]:-0} + 1 ))
  [[ "$code" == 200 ]] || failed=$((failed + 1))
done

summary=""
for c in "${!codes[@]}"; do summary+="$c=${codes[$c]} "; done
printf 'zero-downtime check env=%s duration=%ss requests=%d failed=%d codes: %s\n' \
  "$ENV_NAME" "$SECONDS_TO_RUN" "$total" "$failed" "$summary" > "$RESULT"
[[ "$RESULT" == /dev/stdout ]] || cat "$RESULT"
(( failed == 0 ))
