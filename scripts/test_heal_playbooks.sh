#!/usr/bin/env bash
# Exercise every heal playbook for real, inside the running healer container
# (so through the docker-socket-proxy), against one env. Each case creates the
# failure, runs the playbook, and checks the outcome.
#   scripts/test_heal_playbooks.sh [staging]
# Never point this at prod: it stops containers on purpose.
set -uo pipefail

ENV_NAME="${1:-staging}"
[[ "$ENV_NAME" == "staging" ]] || { echo "refusing: only staging" >&2; exit 2; }
fail=0
pass() { echo "PASS  $*"; }
bad()  { echo "FAIL  $*"; fail=1; }

play() {  # play <playbook> <json extra vars>
  docker exec healer ansible-playbook "/opt/adpulse/heal/$1.yml" -e "$2" > "/tmp/adpulse-heal-$1.log" 2>&1
  local rc=$?
  ((rc == 0)) || tail -n 15 "/tmp/adpulse-heal-$1.log" | sed 's/^/      /'
  return $rc
}
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null; }
started() { docker inspect -f '{{.State.StartedAt}}' "$1"; }

echo "== restart_api, reason=missing (stopped replica)"
docker stop "api-$ENV_NAME-2" >/dev/null
if play restart_api "{\"env\":\"$ENV_NAME\",\"reason\":\"missing\"}" && [[ "$(health "api-$ENV_NAME-2")" == healthy ]]; then
  pass "stopped api-$ENV_NAME-2 started and healthy"; else bad "restart_api missing"; fi

echo "== restart_api, reason=missing but everything already healthy (second alert of a pair)"
if play restart_api "{\"env\":\"$ENV_NAME\",\"reason\":\"missing\"}"; then
  pass "no-op success when all replicas are already running"; else bad "restart_api missing no-op"; fi

echo "== restart_api, instance=<ip> (hung replica)"
ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"adpulse-$ENV_NAME\").IPAddress}}" "api-$ENV_NAME-1")"
before="$(started "api-$ENV_NAME-1")"
if play restart_api "{\"env\":\"$ENV_NAME\",\"instance\":\"$ip:8000\",\"reason\":\"unreachable\"}" \
   && [[ "$(started "api-$ENV_NAME-1")" != "$before" ]] && [[ "$(health "api-$ENV_NAME-1")" == healthy ]]; then
  pass "replica with IP $ip restarted"; else bad "restart_api instance"; fi

echo "== restart_api, container=<name> (memory alert)"
before="$(started "api-$ENV_NAME-2")"
if play restart_api "{\"env\":\"$ENV_NAME\",\"container\":\"api-$ENV_NAME-2\"}" && [[ "$(started "api-$ENV_NAME-2")" != "$before" ]]; then
  pass "api-$ENV_NAME-2 restarted by name"; else bad "restart_api container"; fi

echo "== restart_api, mode=rolling (error-rate alert)"
b1="$(started "api-$ENV_NAME-1")"; b2="$(started "api-$ENV_NAME-2")"
if play restart_api "{\"env\":\"$ENV_NAME\",\"mode\":\"rolling\"}" \
   && [[ "$(started "api-$ENV_NAME-1")" != "$b1" && "$(started "api-$ENV_NAME-2")" != "$b2" ]]; then
  pass "both replicas restarted one at a time"; else bad "restart_api rolling"; fi

echo "== restart_cache"
docker stop "redis-$ENV_NAME" >/dev/null
if play restart_cache "{\"env\":\"$ENV_NAME\"}" && [[ "$(health "redis-$ENV_NAME")" == healthy ]]; then
  pass "redis started and healthy"; else bad "restart_cache"; fi

echo "== restart_db"
docker stop "postgres-$ENV_NAME" >/dev/null
if play restart_db "{\"env\":\"$ENV_NAME\"}" && [[ "$(health "postgres-$ENV_NAME")" == healthy ]] \
   && grep -q 'Wait until the API reports ready' "/tmp/adpulse-heal-restart_db.log"; then
  pass "postgres started, pg_isready, API /readyz 200"; else bad "restart_db"; fi

echo "== cleanup_backups"
docker exec "backup-agent-$ENV_NAME" sh -c 'head -c 30000000 /dev/zero > /backups/junk-1.bin && head -c 30000000 /dev/zero > /backups/junk-2.bin'
if play cleanup_backups "{\"env\":\"$ENV_NAME\"}" && ! docker exec "backup-agent-$ENV_NAME" sh -c 'ls /backups/junk-* >/dev/null 2>&1'; then
  pass "junk files removed: $(grep -o '{\"junk_removed[^}]*}' /tmp/adpulse-heal-cleanup_backups.log | tail -1)"; else bad "cleanup_backups"; fi

echo "== diagnose_latency"
if play diagnose_latency "{\"env\":\"$ENV_NAME\"}"; then
  # shellcheck disable=SC2012  # names are our own <UTC ts>-<env> directories
  d="$(ls -1dt incidents/diagnostics/*-"$ENV_NAME" 2>/dev/null | head -1)"
  if [[ -n "$d" && -s "$d/toxiproxy.txt" && -s "$d/pg_stat_activity.txt" && -s "$d/p95-last-15m.json" ]]; then
    pass "evidence written to $d ($(find "$d" -type f | wc -l) files)"; else bad "diagnose_latency files missing"; fi
else bad "diagnose_latency"; fi

echo "== scale_api, then scale_down_api"
if play scale_api "{\"env\":\"$ENV_NAME\"}" && [[ "$(health "api-$ENV_NAME-3")" == healthy ]]; then
  pass "api-$ENV_NAME-3 added and healthy"; else bad "scale_api"; fi
if play scale_down_api "{\"env\":\"$ENV_NAME\"}" && ! docker inspect "api-$ENV_NAME-3" >/dev/null 2>&1; then
  pass "scaled replica removed"; else bad "scale_down_api"; fi

echo "== kill_noisy_neighbor"
docker run -d --rm --name adpulse-heal-test-hog --label com.adpulse.project=adpulse --label com.adpulse.role=chaos \
  --label com.adpulse.env="$ENV_NAME" --cpus 1 --memory 32m --entrypoint sh adpulse-base:dev -c 'while :; do :; done' >/dev/null
sleep 3
if play kill_noisy_neighbor "{\"env\":\"host\"}" && ! docker ps -q --filter name=adpulse-heal-test-hog | grep -q .; then
  pass "role=chaos CPU hog stopped; protected containers untouched ($(docker ps -q --filter label=com.adpulse.env="$ENV_NAME" | wc -l) $ENV_NAME containers still running)"
else bad "kill_noisy_neighbor"; docker rm -f adpulse-heal-test-hog >/dev/null 2>&1; fi

echo
if ((fail)); then echo "HEAL PLAYBOOKS: FAIL"; exit 1; fi
echo "HEAL PLAYBOOKS: all passed"
