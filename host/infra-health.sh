#!/usr/bin/env bash
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

EXPECTED=${1:-}
if [[ $EXPECTED == "--skip-revision" ]]; then
  EXPECTED=""
  SKIP_REVISION=1
else
  SKIP_REVISION=0
  [[ -n $EXPECTED ]] || { echo "usage: $0 <expected-git-sha|--skip-revision>" >&2; exit 2; }
fi

if [[ $SKIP_REVISION -eq 0 ]]; then
  MARKER=/etc/yz-infra/infra-deployed.sha
  [[ -r $MARKER ]] || { echo "missing $MARKER" >&2; exit 1; }
  DEPLOYED=$(tr -d '\n' < "$MARKER")
  [[ $DEPLOYED == "$EXPECTED" ]] || {
    echo "deployed revision $DEPLOYED does not match $EXPECTED" >&2
    exit 1
  }
fi

service_running() {
  local compose_file=$1
  local project=$2
  local service=$3
  docker compose -f "$compose_file" -p "$project" ps --status running --services | grep -qx "$service"
}

service_running /srv/proxy/compose.yaml proxy traefik || { echo "traefik is not running" >&2; exit 1; }
service_running /srv/proxy/compose.yaml proxy socket-proxy || { echo "socket-proxy is not running" >&2; exit 1; }
service_running /srv/ops/compose.yaml ops uptime-kuma || { echo "uptime-kuma is not running" >&2; exit 1; }
service_running /srv/ops/compose.yaml ops dozzle || { echo "dozzle is not running" >&2; exit 1; }

TRAEFIK_ID=$(docker compose -f /srv/proxy/compose.yaml -p proxy ps -q traefik)
TRAEFIK_HEALTH=unknown
for _ in $(seq 1 30); do
  TRAEFIK_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$TRAEFIK_ID" 2>/dev/null || echo unknown)
  [[ $TRAEFIK_HEALTH == "healthy" ]] && break
  sleep 2
done
[[ $TRAEFIK_HEALTH == "healthy" ]] || { echo "traefik health is $TRAEFIK_HEALTH" >&2; exit 1; }

OPS_READY=0
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:3001/ &&
     curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:9999/; then
    OPS_READY=1
    break
  fi
  sleep 2
done
[[ $OPS_READY -eq 1 ]] || { echo "ops endpoints are not ready" >&2; exit 1; }

[[ -r /etc/yz-infra/restic.env ]] || { echo "missing /etc/yz-infra/restic.env" >&2; exit 1; }
systemctl is-enabled --quiet yz-backup.timer || { echo "yz-backup.timer is not enabled" >&2; exit 1; }
systemctl is-active --quiet yz-backup.timer || { echo "yz-backup.timer is not active" >&2; exit 1; }

LAST_RUN=$(systemctl show -p ExecMainStartTimestamp --value yz-backup.service 2>/dev/null || true)
if [[ -z $LAST_RUN || $LAST_RUN == "n/a" ]]; then
  echo "yz-backup.service has never run" >&2
  exit 1
fi
if systemctl is-failed --quiet yz-backup.service; then
  echo "the last yz-backup.service run failed" >&2
  exit 1
fi

if [[ $SKIP_REVISION -eq 1 ]]; then
  echo "infra healthy"
else
  echo "infra healthy at $EXPECTED"
fi
