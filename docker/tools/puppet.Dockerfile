# Lint container for Puppet code: puppet parser validate + puppet-lint.
# Usage: make lint-puppet
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

ARG OPENVOX_RELEASE=8
ARG OPENVOX_AGENT_VERSION=8.29.0-1+ubuntu24.04
ARG PUPPET_LINT_VERSION=5.1.1

LABEL com.adpulse.project="adpulse" com.adpulse.role="tools"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    curl -fsSL -o /tmp/openvox-release.deb "https://apt.voxpupuli.org/openvox${OPENVOX_RELEASE}-release-ubuntu24.04.deb"; \
    dpkg -i /tmp/openvox-release.deb; \
    apt-get update; \
    apt-get install -y --no-install-recommends "openvox-agent=${OPENVOX_AGENT_VERSION}"; \
    /opt/puppetlabs/puppet/bin/gem install --no-document puppet-lint -v "${PUPPET_LINT_VERSION}"; \
    rm -rf /var/lib/apt/lists/* /tmp/*

ENV PATH="/opt/puppetlabs/puppet/bin:/opt/puppetlabs/bin:${PATH}"
WORKDIR /work
