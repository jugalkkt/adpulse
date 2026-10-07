#!/usr/bin/env bash
# Print the image tag Terraform last applied in a root (else the env's deployed release), so `make down` destroys what is
# running instead of looking up images for HEAD (which may never have been built).
#   scripts/applied_tag.sh env <staging|prod> <fallback>
#   scripts/applied_tag.sh monitoring <fallback>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
  env)        dir="$ROOT/infra/terraform/envs/local"; ws="${2:?env required}"; fallback="${3:?fallback required}" ;;
  monitoring) dir="$ROOT/infra/terraform/monitoring/local"; ws=""; fallback="${2:?fallback required}" ;;
  *) echo "usage: applied_tag.sh env <env> <fallback> | monitoring <fallback>" >&2; exit 2 ;;
esac

tag=""
if [[ -d "$dir/.terraform" ]]; then
  [[ -z "$ws" ]] || terraform -chdir="$dir" workspace select "$ws" >/dev/null 2>&1 || true
  # Every adpulse image data source carries the same tag (adpulse-<name>:<tag>).
  tag="$(terraform -chdir="$dir" show -json 2>/dev/null \
    | /usr/bin/jq -r 'first(.. | objects | select(.mode? == "data" and .type? == "docker_image") | .values.name | select(startswith("adpulse-")) | split(":")[1]) // empty' || true)"
fi
# After a partial destroy the data sources are gone from state: use the deployed release.
if [[ -z "$tag" && -n "$ws" && -f "$ROOT/deploy/state/$ws.json" ]]; then
  tag="$(/usr/bin/jq -r '.current // empty' "$ROOT/deploy/state/$ws.json")"
fi
printf '%s\n' "${tag:-$fallback}"
