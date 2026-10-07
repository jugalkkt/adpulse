#!/usr/bin/env bash
# AdPulse machine bootstrap (Phase 0.2). Needs root, so Jugal runs it himself:
#   sudo bash scripts/bootstrap.sh
#
# What it does (safe to re-run; each step skips itself when already done):
#   1. Removes the old Docker installs (snap "docker" and Ubuntu "docker.io") and
#      ALL their data, after you type "yes". Skipped once they are gone.
#   2. Replaces the Terraform snap and the Ubuntu "awscli" package.
#   3. Adds the official apt repos for Docker, HashiCorp and GitHub CLI, with
#      pinned signing-key fingerprints.
#   4. Installs: base apt packages, docker-ce + compose + buildx, terraform, gh.
#   5. Installs AWS CLI v2 from the official zip after verifying its signature.
#   6. Adds you to the "docker" group and enables the Docker service.
#
# Repo codename is "noble" (24.04 LTS) on purpose: see docs/DECISIONS.md.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REPO_CODENAME="noble"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"  # gitleaks:allow (public key fingerprint)
HASHICORP_KEY_URL="https://apt.releases.hashicorp.com/gpg"
HASHICORP_KEY_FPR="D55C0D1AC78A8D8126CB631CFC9CA96ACA026560"  # gitleaks:allow (public key fingerprint)
GH_KEY_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
GH_KEY_FPR="2C6106201985B60E6C7AC87323F3D4EA75716059"  # gitleaks:allow (public key fingerprint)
AWS_KEY_FILE="$SCRIPT_DIR/keys/aws-cli.asc"
AWS_KEY_FPR="FB5DB77FD5C118B80511ADA8A6310ACC4672475C"  # gitleaks:allow (public key fingerprint)

APT_BASE=(git make curl jq unzip ca-certificates gnupg python3 python3-venv pipx shellcheck)
APT_DOCKER=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
# Packages that conflict with docker-ce (from Docker's install docs).
DOCKER_CONFLICTS=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)

log()  { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
has_snap()     { command -v snap >/dev/null 2>&1 && snap list "$1" >/dev/null 2>&1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GNUPGHOME="$TMP/gnupg"
mkdir -m 700 "$GNUPGHOME"

# Download a signing key to $2 and fail unless it contains fingerprint $3.
fetch_key() {
  local url="$1" dest="$2" fpr="$3"
  curl -fsSL "$url" -o "$TMP/key"
  if ! gpg --show-keys --with-colons "$TMP/key" 2>/dev/null | awk -F: '$1=="fpr"{print $10}' | grep -qx "$fpr"; then
    die "key from $url does not contain expected fingerprint $fpr"
  fi
  install -m 0644 "$TMP/key" "$dest"
  info "key OK ($fpr) -> $dest"
}

# ---------------------------------------------------------------- preflight
log "Preflight"
[[ $EUID -eq 0 ]] || die "run with sudo: sudo bash scripts/bootstrap.sh"
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || die "run via sudo from your normal user, not as root"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "this script expects amd64"
info "user=$TARGET_USER codename-for-vendor-repos=$REPO_CODENAME"

# ---------------------------------------------------------------- 1. old Docker
log "Step 1: remove old Docker installs"
old_pkgs=()
for p in "${DOCKER_CONFLICTS[@]}"; do is_installed "$p" && old_pkgs+=("$p"); done
if has_snap docker || is_installed docker.io; then
  echo
  echo "  The following will be PERMANENTLY DELETED:"
  has_snap docker && echo "   - snap 'docker' and all its images/containers/volumes ($(du -sh /var/snap/docker 2>/dev/null | cut -f1) in /var/snap/docker)"
  ((${#old_pkgs[@]})) && echo "   - apt packages: ${old_pkgs[*]}"
  [[ -d /var/lib/docker ]] && echo "   - /var/lib/docker ($(du -sh /var/lib/docker 2>/dev/null | cut -f1))"
  [[ -d /var/lib/containerd ]] && echo "   - /var/lib/containerd ($(du -sh /var/lib/containerd 2>/dev/null | cut -f1))"
  echo
  read -r -p "  Type yes to delete all of the above: " answer
  [[ "$answer" == "yes" ]] || die "aborted by user; nothing was removed"

  systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
  if has_snap docker; then
    info "snap remove --purge docker (no backup snapshot)"
    snap remove --purge docker
  fi
  if ((${#old_pkgs[@]})); then
    info "apt-get purge ${old_pkgs[*]}"
    apt-get purge -y "${old_pkgs[@]}"
  fi
  info "rm -rf /var/lib/docker /var/lib/containerd"
  rm -rf /var/lib/docker /var/lib/containerd
else
  info "no snap docker or docker.io found; skipping"
fi

# ---------------------------------------------------------------- 2. other replaced installs
log "Step 2: remove Terraform snap and Ubuntu awscli package"
if has_snap terraform; then
  info "snap remove terraform"
  snap remove --purge terraform
else
  info "no terraform snap; skipping"
fi
if is_installed awscli; then
  info "apt-get purge awscli"
  apt-get purge -y awscli
else
  info "no awscli deb; skipping"
fi

# ---------------------------------------------------------------- 3. vendor repos
log "Step 3: official apt repositories (suite: $REPO_CODENAME / stable)"
install -m 0755 -d /etc/apt/keyrings

for old in /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/hashicorp.list; do
  if [[ -f "$old" ]]; then
    info "replacing $old (was: $(grep -v '^#' "$old" | tr -s ' ' | head -n1))"
    rm -f "$old"
  fi
done

fetch_key "$DOCKER_KEY_URL" /etc/apt/keyrings/docker.asc "$DOCKER_KEY_FPR"
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $REPO_CODENAME
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

fetch_key "$HASHICORP_KEY_URL" /etc/apt/keyrings/hashicorp.asc "$HASHICORP_KEY_FPR"
cat > /etc/apt/sources.list.d/hashicorp.sources <<EOF
Types: deb
URIs: https://apt.releases.hashicorp.com
Suites: $REPO_CODENAME
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/hashicorp.asc
EOF

fetch_key "$GH_KEY_URL" /etc/apt/keyrings/githubcli-archive-keyring.gpg "$GH_KEY_FPR"
cat > /etc/apt/sources.list.d/github-cli.sources <<EOF
Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/githubcli-archive-keyring.gpg
EOF

# ---------------------------------------------------------------- 4. packages
log "Step 4: apt-get update and install packages"
apt-get update
apt-get install -y "${APT_BASE[@]}" "${APT_DOCKER[@]}" terraform gh

# ---------------------------------------------------------------- 5. AWS CLI
log "Step 5: AWS CLI v2 (official zip, signature verified)"
[[ -f "$AWS_KEY_FILE" ]] || die "missing $AWS_KEY_FILE"
gpg -q --import "$AWS_KEY_FILE"
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o "$TMP/awscliv2.zip"
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip.sig -o "$TMP/awscliv2.sig"
if ! gpg --status-fd 1 --verify "$TMP/awscliv2.sig" "$TMP/awscliv2.zip" 2>/dev/null | grep -q "VALIDSIG $AWS_KEY_FPR"; then
  die "AWS CLI zip signature check FAILED"
fi
info "signature OK ($AWS_KEY_FPR)"
unzip -q "$TMP/awscliv2.zip" -d "$TMP"
"$TMP/aws/install" --update --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli

# ---------------------------------------------------------------- 6. docker group + service
log "Step 6: docker group and service"
getent group docker >/dev/null || groupadd docker
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  info "$TARGET_USER already in docker group"
else
  usermod -aG docker "$TARGET_USER"
  info "added $TARGET_USER to docker group (log out and back in to apply)"
fi
systemctl enable --now containerd.service docker.service

# ---------------------------------------------------------------- summary
log "Done. Installed versions:"
info "$(docker --version)"
info "$(docker compose version)"
info "$(docker buildx version)"
info "$(terraform version | head -n1)"
info "$(/usr/local/bin/aws --version)"
info "$(gh --version | head -n1)"
info "$(shellcheck --version | sed -n 2p)"
echo
echo "Next: log out and log back in (or reboot), then tell Claude 'done'."
