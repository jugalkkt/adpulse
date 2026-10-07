#!/usr/bin/env bash
# Security scans (Phase 10/11), used by `make scan` and CI.
#   scripts/scan.sh images <tag>   Trivy: FAIL on CRITICAL with a fix; report HIGH
#   scripts/scan.sh config         Trivy misconfiguration scan of Dockerfiles + Terraform (report only)
#   scripts/scan.sh secrets        gitleaks over the full git history
#   scripts/scan.sh sbom <tag>     CycloneDX SBOM per image into sbom/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIVY="aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa"
GITLEAKS="zricethezav/gitleaks:v8.30.0@sha256:691af3c7c5a48b16f187ce3446d5f194838f91238f27270ed36eef6359a574d9"
IMAGES=(adpulse-base adpulse-api adpulse-postgres adpulse-healer adpulse-chaos-stress)
CACHE=(-v adpulse-trivy-cache:/root/.cache)
docker volume create --label com.adpulse.project=adpulse --label com.adpulse.role=tools adpulse-trivy-cache >/dev/null

trivy() { docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro "${CACHE[@]}" -v "$ROOT:/src:ro" "$TRIVY" "$@"; }

case "${1:-}" in
  images)
    tag="${2:?tag required}"; fail=0
    for img in "${IMAGES[@]}"; do
      echo "== $img:$tag"
      # Gate: CRITICAL with an available fix fails the scan.
      if ! trivy image --quiet --scanners vuln,secret --ignore-unfixed --severity CRITICAL --exit-code 1 "$img:$tag"; then
        fail=1
      fi
      # Report only: HIGH with a fix.
      trivy image --quiet --scanners vuln --ignore-unfixed --severity HIGH --format table "$img:$tag" | tail -n +1
    done
    exit $fail ;;
  config)
    trivy config --quiet --severity HIGH,CRITICAL --exit-code 0 /src/docker
    trivy config --quiet --severity HIGH,CRITICAL --exit-code 0 /src/infra/terraform ;;
  secrets)
    docker run --rm -v "$ROOT:/repo:ro" -w /repo "$GITLEAKS" git --redact --no-banner -v /repo ;;
  sbom)
    tag="${2:?tag required}"; mkdir -p "$ROOT/sbom"
    for img in "${IMAGES[@]}"; do
      docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro "${CACHE[@]}" -v "$ROOT/sbom:/out" "$TRIVY" \
        image --quiet --format cyclonedx --output "/out/$img.cdx.json" "$img:$tag"
      echo "sbom/$img.cdx.json"
    done ;;
  *)
    echo "usage: scan.sh images <tag> | config | secrets | sbom <tag>" >&2; exit 2 ;;
esac
