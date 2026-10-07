# AdPulse API image (also runs loadgen and migrations with other entrypoints).
# Build from the repo root: make build-api
ARG BASE_IMAGE=adpulse-base:dev

FROM ${BASE_IMAGE} AS runtime

ARG GIT_SHA=dev
# Phase 10 rollback demo bakes BROKEN_RELEASE=true into a deliberately bad image.
ARG BROKEN_RELEASE=false

LABEL com.adpulse.project="adpulse" \
      com.adpulse.role="api" \
      org.opencontainers.image.title="adpulse-api" \
      org.opencontainers.image.revision="${GIT_SHA}"

ENV PATH="/opt/adpulse/venv/bin:${PATH}" \
    PYTHONPATH="/opt/adpulse/app" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    GIT_SHA="${GIT_SHA}" \
    BROKEN_RELEASE="${BROKEN_RELEASE}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY app/requirements.txt /tmp/requirements.txt
# Hash-checked install; pip is removed afterwards (not needed at runtime).
RUN python3 -m venv /opt/adpulse/venv \
 && /opt/adpulse/venv/bin/pip install --no-cache-dir --no-deps --require-hashes -r /tmp/requirements.txt \
 && /opt/adpulse/venv/bin/pip uninstall -y -q pip \
 && rm -f /tmp/requirements.txt

COPY app/adpulse /opt/adpulse/app/adpulse
COPY app/loadgen /opt/adpulse/app/loadgen
COPY app/migrations /opt/adpulse/app/migrations
RUN python3 -m compileall -q /opt/adpulse/app

USER adpulse
WORKDIR /opt/adpulse/app
EXPOSE 8000

HEALTHCHECK --interval=5s --timeout=2s --retries=3 --start-period=10s \
  CMD ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8000/healthz"]

CMD ["uvicorn", "adpulse.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log"]


# Test image: runtime + dev tools + tests (used by `make test` and CI only).
FROM runtime AS test
USER root
COPY app/requirements-dev.txt /tmp/requirements-dev.txt
RUN python3 -m ensurepip \
 && python3 -m pip install --no-cache-dir --no-deps --require-hashes -r /tmp/requirements-dev.txt \
 && rm -f /tmp/requirements-dev.txt
COPY app/pyproject.toml /opt/adpulse/app/pyproject.toml
COPY app/tests /opt/adpulse/app/tests
USER adpulse
# Tests control their own settings: a release baked with BROKEN_RELEASE=true
# (the Phase 10 rollback demo) must not leak into unit tests.
ENV RUFF_CACHE_DIR=/tmp/ruff PYTHONPYCACHEPREFIX=/tmp/pycache BROKEN_RELEASE=false
CMD ["bash", "-c", "ruff check . && ruff format --check . && pytest -q -p no:cacheprovider"]
