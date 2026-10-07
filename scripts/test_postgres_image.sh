#!/usr/bin/env bash
# Behavioural checks for the adpulse-postgres image (Phase 4 DoD):
#   1. Chef-rendered settings are live (SHOW shared_buffers, ...)
#   2. scram-sha-256 auth: right password works, wrong password fails
#   3. pg_hba: a client from a network outside the allowed CIDRs is rejected
#   4. backup-agent produces a .dump and a valid Prometheus textfile (promtool)
# Everything it creates carries the adpulse labels and is removed on exit.
set -euo pipefail

IMAGE="${1:-adpulse-postgres:dev}"
PROMETHEUS_IMAGE="prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e"
P="adpulse-pgtest"
LABELS=(--label com.adpulse.project=adpulse --label com.adpulse.env=test)
ADMIN_PW="$(openssl rand -hex 16)"
APP_PW="$(openssl rand -hex 16)"
MON_PW="$(openssl rand -hex 16)"
fail=0

cleanup() {
  docker rm -f "$P-db" "$P-backup" >/dev/null 2>&1 || true
  docker network rm "$P-net" "$P-outside" >/dev/null 2>&1 || true
  docker volume rm "$P-backups" "$P-textfile" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

check() {  # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}

# An allowed subnet that is unused locally (aws-prod's), and one outside the allow-list.
docker network create "${LABELS[@]}" --subnet 172.28.30.0/24 "$P-net" >/dev/null
docker network create "${LABELS[@]}" --subnet 172.28.99.0/24 "$P-outside" >/dev/null
docker volume create "${LABELS[@]}" "$P-backups" >/dev/null
docker volume create "${LABELS[@]}" "$P-textfile" >/dev/null

docker run -d --name "$P-db" "${LABELS[@]}" --network "$P-net" --user 999:999 \
  -e POSTGRES_PASSWORD="$ADMIN_PW" -e ADPULSE_APP_PASSWORD="$APP_PW" -e ADPULSE_MONITOR_PASSWORD="$MON_PW" \
  --tmpfs /var/lib/postgresql "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$P-db" pg_isready -q -U postgres 2>/dev/null \
     && docker logs "$P-db" 2>&1 | grep -q 'database system is ready to accept connections' \
     && docker logs "$P-db" 2>&1 | grep -q 'adpulse roles created'; then
    break
  fi
  sleep 1
done
# The entrypoint restarts postgres after init; wait for the final server.
sleep 2
docker exec "$P-db" pg_isready -q -U postgres || { docker logs "$P-db" | tail -20; echo "FAIL  postgres did not start"; exit 1; }

psql_as() {  # psql_as <network> <user> <password> <sql>
  docker run --rm --network "$1" -e PGPASSWORD="$3" --entrypoint psql "$IMAGE" \
    -h "$P-db" -U "$2" -d adpulse -tAc "$4"
}

echo "--- settings rendered by Chef"
sb="$(psql_as "$P-net" adpulse "$APP_PW" 'SHOW shared_buffers;')"
mc="$(psql_as "$P-net" adpulse "$APP_PW" 'SHOW max_connections;')"
pe="$(psql_as "$P-net" adpulse "$APP_PW" 'SHOW password_encryption;')"
st="$(psql_as "$P-net" adpulse "$APP_PW" 'SHOW statement_timeout;')"
echo "shared_buffers=$sb max_connections=$mc password_encryption=$pe statement_timeout=$st"
check "shared_buffers = 128MB (attribute)" test "$sb" = "128MB"
check "max_connections = 50 (attribute)" test "$mc" = "50"
check "password_encryption = scram-sha-256" test "$pe" = "scram-sha-256"
check "statement_timeout = 5s" test "$st" = "5s"

echo "--- authentication"
check "app user with correct password connects" test "$(psql_as "$P-net" adpulse "$APP_PW" 'SELECT 1;')" = "1"
check "monitor role can read pg_stat_activity" \
  test -n "$(psql_as "$P-net" adpulse_monitor "$MON_PW" 'SELECT count(*) FROM pg_stat_activity;')"
check "wrong password is rejected" bash -c "! psql_out=\$(docker run --rm --network $P-net -e PGPASSWORD=wrong --entrypoint psql $IMAGE -h $P-db -U adpulse -d adpulse -tAc 'SELECT 1' 2>&1) && grep -q 'password authentication failed' <<<\"\$psql_out\""
docker network connect "$P-outside" "$P-db"
outside_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$P-outside\").IPAddress}}" "$P-db")"
check "client from a non-allowed subnet is rejected by pg_hba" bash -c "! out=\$(docker run --rm --network $P-outside -e PGPASSWORD=$APP_PW --entrypoint psql $IMAGE -h $outside_ip -U adpulse -d adpulse -tAc 'SELECT 1' 2>&1) && grep -q 'no pg_hba.conf entry' <<<\"\$out\""
check "no 'trust' entries in pg_hba.conf" bash -c "! docker exec $P-db grep -Ev '^\s*#' /etc/adpulse-db/pg_hba.conf | grep -qw trust"

echo "--- backup agent"
docker run -d --name "$P-backup" "${LABELS[@]}" --network "$P-net" --user postgres \
  -e ADPULSE_ENV=pgtest -e BACKUP_INTERVAL_SECONDS=10 \
  -e PGHOST="$P-db" -e PGUSER=adpulse -e PGPASSWORD="$APP_PW" -e PGDATABASE=adpulse \
  -v "$P-backups:/backups" -v "$P-textfile:/textfile" \
  --entrypoint /usr/local/bin/adpulse-backup-loop.sh "$IMAGE" >/dev/null
for _ in $(seq 1 30); do
  docker exec "$P-backup" bash -c 'ls /backups/pgtest-*.dump >/dev/null 2>&1 && test -f /textfile/backup_pgtest.prom' && break
  sleep 1
done
docker logs "$P-backup" 2>&1 | tail -3
check "a .dump backup file exists" docker exec "$P-backup" bash -c 'ls -l /backups/pgtest-*.dump'
# shellcheck disable=SC2016  # expands inside the container
check "dump is a valid pg_dump custom archive" docker exec "$P-backup" bash -c 'pg_restore --list "$(ls -1t /backups/pgtest-*.dump | head -1)" >/dev/null'
docker exec "$P-backup" cat /textfile/backup_pgtest.prom > /tmp/adpulse-pgtest.prom
grep -v '^#' /tmp/adpulse-pgtest.prom
check "textfile metrics pass promtool check metrics" \
  docker run --rm -i --entrypoint promtool "$PROMETHEUS_IMAGE" check metrics < /tmp/adpulse-pgtest.prom
check "all 5 backup metrics present" test "$(grep -c '^adpulse_backup_' /tmp/adpulse-pgtest.prom)" -eq 5
rm -f /tmp/adpulse-pgtest.prom

echo
if ((fail)); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: all checks passed"
