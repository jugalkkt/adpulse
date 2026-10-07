#!/usr/bin/env bash
# AdPulse machine report: read-only preflight check (Phase 0.1).
# Prints OS, CPU, memory, disk, tool versions, Docker status and port listeners.
# It changes nothing on the system.
set -uo pipefail

section() { printf '\n=== %s ===\n' "$1"; }

section "OS"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "NAME=${NAME:-?}"
  echo "VERSION=${VERSION:-?}"
  echo "UBUNTU_CODENAME=${UBUNTU_CODENAME:-?}"
else
  echo "/etc/os-release not readable"
fi

section "CPU / memory / disk"
echo "arch: $(uname -m)"
echo "kernel: $(uname -r)"
echo "cpus: $(nproc)"
free -h
echo
df -h "$HOME"

section "Tools"
check() {
  local name="$1"; shift
  if command -v "$name" >/dev/null 2>&1; then
    printf '%-10s %s\n' "$name" "$("$@" 2>&1 | head -n1)"
  else
    printf '%-10s MISSING\n' "$name"
  fi
}
check docker    docker --version
if command -v docker >/dev/null 2>&1; then
  check docker   docker compose version
fi
check terraform terraform version
check aws       aws --version
check gh        gh --version
check ansible   ansible --version
check python3   python3 --version
check pipx      pipx --version
check git       git --version
check make      make --version
check jq        jq --version
check curl      curl --version
check openssl   openssl version

section "Docker service"
if command -v systemctl >/dev/null 2>&1; then
  echo "docker.service: $(systemctl is-active docker 2>&1)"
fi
echo "user groups: $(id -nG)"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "docker without sudo: OK"
  else
    echo "docker without sudo: NOT working"
  fi
fi

section "Listeners on AdPulse ports (3000 8080 8081 9090 9093)"
out="$(ss -ltn 2>/dev/null | awk 'NR==1 || $4 ~ /:(3000|8080|8081|9090|9093)$/')"
if [[ "$(printf '%s\n' "$out" | wc -l)" -le 1 ]]; then
  echo "none (all free)"
else
  printf '%s\n' "$out"
fi
