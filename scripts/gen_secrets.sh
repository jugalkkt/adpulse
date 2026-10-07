#!/usr/bin/env bash
# Create or complete .env from .env.example (Phase 1).
#   GENERATE values become random hex; empty values stay empty.
#   Values already present in .env are never changed.
#   Secret values are never printed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/.env.example"
ENV_FILE="$ROOT/.env"

[[ -f "$EXAMPLE" ]] || { echo "missing $EXAMPLE" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

umask 077
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

added=0 generated=0 kept=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
  name="${BASH_REMATCH[1]}" default="${BASH_REMATCH[2]}"
  if grep -q "^${name}=" "$ENV_FILE"; then
    # Fill a GENERATE var that exists but is still empty; otherwise keep it.
    if [[ "$default" == "GENERATE" ]] && grep -qx "${name}=" "$ENV_FILE"; then
      value="$(openssl rand -hex 24)"
      sed -i "s|^${name}=\$|${name}=${value}|" "$ENV_FILE"
      generated=$((generated + 1))
    else
      kept=$((kept + 1))
    fi
    continue
  fi
  if [[ "$default" == "GENERATE" ]]; then
    printf '%s=%s\n' "$name" "$(openssl rand -hex 24)" >> "$ENV_FILE"
    generated=$((generated + 1))
  else
    printf '%s=%s\n' "$name" "$default" >> "$ENV_FILE"
    added=$((added + 1))
  fi
done < "$EXAMPLE"

echo ".env ready (mode $(stat -c %a "$ENV_FILE")): generated=$generated empty-added=$added kept=$kept"
