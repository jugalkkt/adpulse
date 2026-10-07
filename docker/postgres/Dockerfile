# AdPulse PostgreSQL image, configured by Chef (Cinc) cookbook adpulse_db.
# The same image runs as backup-agent (entrypoint adpulse-backup-loop.sh).
# Build from the repo root: make build-postgres
FROM postgres:18.6-trixie@sha256:fc973eb97c9fd04bfa1840e0f510719a584ccb3be8debfe6a4144637a9dfe8cf

ARG CINC_VERSION=19.3.14
ARG CINC_DEB_SHA256=a6094f97527371b113acfda7bcceecc4d7113a00f71031d709bbe8367aeefebd

# No git-SHA label on purpose: the image ID must only change when its content
# changes, otherwise every commit would make Terraform restart Postgres (D029).
LABEL com.adpulse.project="adpulse" \
      com.adpulse.role="db" \
      org.opencontainers.image.title="adpulse-postgres"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# One layer: install Cinc from a hash-pinned package, converge twice (the second
# run must update 0 resources), then remove Cinc so it never ships.
# hadolint ignore=DL3008
RUN --mount=type=bind,source=config/chef,target=/chef,readonly \
    set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    curl -fsSL -o /tmp/cinc.deb "https://packages.cinc.sh/files/stable/cinc/${CINC_VERSION}/debian/13/cinc_${CINC_VERSION}-1_amd64.deb"; \
    echo "${CINC_DEB_SHA256}  /tmp/cinc.deb" | sha256sum -c -; \
    dpkg -i /tmp/cinc.deb; \
    cp -r /chef /tmp/chef-repo; \
    converge() { cinc-client --local-mode --chef-license accept-no-persist --no-color \
                   --chef-zero-port 8889 --config-option chef_repo_path=/tmp/chef-repo \
                   --override-runlist 'recipe[adpulse_db]'; }; \
    converge; \
    converge | tee /etc/adpulse-db/cinc-idempotency.log; \
    grep -Eq '(Infra Phase complete|Cinc Client finished), 0/[0-9]+ resources updated' /etc/adpulse-db/cinc-idempotency.log \
      || { echo "cinc converge #2 NOT idempotent"; exit 1; }; \
    dpkg --purge cinc; \
    apt-get purge -y curl; \
    apt-get autoremove -y --purge; \
    rm -rf /opt/cinc /etc/cinc /var/cinc /root/.cinc /root/.chef /tmp/* /var/lib/apt/lists/* /var/cache/apt/*; \
    # gosu only drops root -> postgres in the entrypoint; AdPulse always runs
    # postgres as uid 999, so it is dead code (and carried CVE-2025-68121).
    rm -f /usr/local/bin/gosu

# Non-root by default (Trivy DS-0002); AdPulse always runs it as uid 999 anyway.
USER postgres

CMD ["postgres", "-c", "config_file=/etc/adpulse-db/postgresql.conf", "-c", "hba_file=/etc/adpulse-db/pg_hba.conf"]
