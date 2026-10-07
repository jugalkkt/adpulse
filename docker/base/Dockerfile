# AdPulse base image: Ubuntu 24.04 hardened by Puppet (OpenVox) class adpulse::base.
# Build from the repo root: make build-base
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

ARG OPENVOX_RELEASE=8
ARG OPENVOX_AGENT_VERSION=8.29.0-1+ubuntu24.04

# No git-SHA label: the base only changes when its content does, so the API
# build cache (pip layer) survives commits (docs/DECISIONS.md D029).
LABEL com.adpulse.project="adpulse" \
      com.adpulse.role="base" \
      org.opencontainers.image.title="adpulse-base"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# One layer: install the agent, apply twice (the second run must change
# nothing), then purge the agent so it never ships in the image.
# hadolint ignore=DL3008
RUN --mount=type=bind,source=config/puppet,target=/puppet,readonly \
    set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    curl -fsSL -o /tmp/openvox-release.deb "https://apt.voxpupuli.org/openvox${OPENVOX_RELEASE}-release-ubuntu24.04.deb"; \
    dpkg -i /tmp/openvox-release.deb; \
    apt-get update; \
    apt-get install -y --no-install-recommends "openvox-agent=${OPENVOX_AGENT_VERSION}"; \
    apply() { /opt/puppetlabs/bin/puppet apply --detailed-exitcodes --color=false \
                --modulepath=/puppet/modules /puppet/manifests/site.pp; }; \
    rc=0; apply || rc=$?; \
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then echo "puppet apply #1 failed (exit $rc)"; exit 1; fi; \
    rc=0; apply 2>&1 | tee /etc/adpulse/puppet-idempotency.log || rc=$?; \
    if [ "$rc" -ne 0 ]; then echo "puppet apply #2 NOT idempotent (exit $rc)"; exit 1; fi; \
    echo "puppet apply #2: 0 changes (exit 0)" >> /etc/adpulse/puppet-idempotency.log; \
    apt-get purge -y openvox-agent "openvox${OPENVOX_RELEASE}-release"; \
    apt-get autoremove -y --purge; \
    rm -rf /opt/puppetlabs /etc/puppetlabs /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /root/.cache; \
    /usr/local/sbin/adpulse-fs-hardening check

WORKDIR /opt/adpulse
# Non-root by default (Trivy DS-0002); derived images switch to root only for install steps.
USER adpulse
