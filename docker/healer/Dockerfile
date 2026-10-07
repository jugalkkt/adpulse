# AdPulse healer: FastAPI webhook + ansible-core + community.docker + docker CLI.
# Talks to Docker only through the docker-socket-proxy (DOCKER_HOST).
# Build from the repo root: make build-healer
ARG BASE_IMAGE=adpulse-base:dev

FROM ${BASE_IMAGE} AS runtime

ARG GIT_SHA=dev
ARG DOCKER_CLI_VERSION=5:29.8.2-1~ubuntu.24.04~noble
ARG DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
ARG COMMUNITY_DOCKER_VERSION=5.4.0

LABEL com.adpulse.project="adpulse" \
      com.adpulse.role="healer" \
      org.opencontainers.image.title="adpulse-healer" \
      org.opencontainers.image.revision="${GIT_SHA}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root

# Docker CLI from Docker's signed apt repo (key fingerprint checked), used by
# heal playbooks for docker stats/exec/restart through the socket proxy.
# hadolint ignore=DL3008
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends gnupg; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
    GNUPGHOME="$(mktemp -d)" gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '$1=="fpr"{print $10}' | grep -qx "${DOCKER_KEY_FPR}"; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "docker-ce-cli=${DOCKER_CLI_VERSION}"; \
    apt-get purge -y gnupg; apt-get autoremove -y --purge; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /root/.gnupg /tmp/*

ENV PATH="/opt/adpulse/venv/bin:${PATH}" \
    PYTHONPATH="/opt/adpulse/healer" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    ANSIBLE_CONFIG=/opt/adpulse/heal/ansible.cfg \
    ANSIBLE_COLLECTIONS_PATH=/opt/adpulse/collections \
    ANSIBLE_HOME=/tmp/.ansible \
    ANSIBLE_LOCAL_TEMP=/tmp/.ansible/tmp \
    HEALER_RULES=/opt/adpulse/healer/healing.yml \
    HEALER_PLAYBOOK_DIR=/opt/adpulse/heal \
    HEALER_DATA_DIR=/data

COPY healer/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/adpulse/venv \
 && /opt/adpulse/venv/bin/pip install --no-cache-dir --no-deps --require-hashes -r /tmp/requirements.txt \
 && /opt/adpulse/venv/bin/ansible-galaxy collection install -p /opt/adpulse/collections \
      "community.docker:==${COMMUNITY_DOCKER_VERSION}" \
 && /opt/adpulse/venv/bin/pip uninstall -y -q pip \
 && rm -rf /tmp/requirements.txt /tmp/.ansible /root/.ansible

COPY healer/healer /opt/adpulse/healer/healer
COPY healer/healing.yml /opt/adpulse/healer/healing.yml
COPY ansible/playbooks/heal /opt/adpulse/heal
RUN python3 -m compileall -q /opt/adpulse/healer

USER adpulse
WORKDIR /opt/adpulse/healer
EXPOSE 9100

HEALTHCHECK --interval=10s --timeout=3s --retries=3 --start-period=10s \
  CMD ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:9100/healthz"]

CMD ["uvicorn", "healer.app:app", "--host", "0.0.0.0", "--port", "9100", "--workers", "1", "--no-access-log"]


# Test image: runtime + pytest/ruff + tests (make test-healer).
FROM runtime AS test
USER root
COPY healer/requirements-dev.txt /tmp/requirements-dev.txt
RUN python3 -m ensurepip \
 && python3 -m pip install --no-cache-dir --no-deps --require-hashes -r /tmp/requirements-dev.txt \
 && rm -f /tmp/requirements-dev.txt
COPY healer/pyproject.toml /opt/adpulse/healer/pyproject.toml
COPY healer/tests /opt/adpulse/healer/tests
USER adpulse
ENV RUFF_CACHE_DIR=/tmp/ruff PYTHONPYCACHEPREFIX=/tmp/pycache HEALER_NO_AUTOAPP=1
CMD ["bash", "-c", "ruff check . && ruff format --check . && python -m pytest -q -p no:cacheprovider tests"]
