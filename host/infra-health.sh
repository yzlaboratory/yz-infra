#!/usr/bin/env bash
# Server-side health probe for the shared infra stack.
#
# Returns 0 only when:
#   - the deployed git revision matches the expected revision
#   - Traefik and socket-proxy are running and Traefik is healthy
#   - Uptime Kuma and Dozzle are running
#   - their localhost endpoints respond
#   - the restic config exists and the backup timer is enabled
#
# Usage: yz-infra-health <expected-git-sha>
set -euo pipefail

EXPECTED=${1:-}
[[ -n $EXPECTED ]] || { echo "usage: $0 <expected-git-sha>" >&2; exit 2; }

MARKER=/etc/yz-infra/infra-deployed.sha
[[ -r $MARKER ]] || { echo "missing $MARKER" >&2; exit 1; }
DEPLOYED=$(tr -d '\n' < "$MARKER")
[[ $DEPLOYED == "$EXPECTED" ]] || {
  echo "deployed revision $DEPLOYED does not match $EXPECTED" >&2
  exit 1
}

proxy_service_running() {
  docker compose -f /srv/proxy/compose.yaml -p proxy ps --status running --services | grep -qx "$1"
}
ops_service_running() {
  docker compose -f /srv/ops/compose.yaml -p ops ps --status running --services | grep -qx "$1"
}

proxy_service_running traefik || { echo "traefik is not running" >&2; exit 1; }
proxy_service_running socket-proxy || { echo "socket-proxy is not running" >&2; exit 1; }
ops_service_running uptime-kuma || { echo "uptime-kuma is not running" >&2; exit 1; }
ops_service_running dozzle || { echo "dozzle is not running" >&2; exit 1; }

TRAEFIK_ID=$(docker compose -f /srv/proxy/compose.yaml -p proxy ps -q traefik)
TRAEFIK_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$TRAEFIK_ID" 2>/dev/null || echo unknown)
[[ $TRAEFIK_HEALTH == "healthy" ]] || { echo "traefik health is $TRAEFIK_HEALTH" >&2; exit 1; }

curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:3001/ || { echo "uptime-kuma endpoint is down" >&2; exit 1; }
curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:9999/ || { echo "dozzle endpoint is down" >&2; exit 1; }

[[ -r /etc/yz-infra/restic.env ]] || { echo "missing /etc/yz-infra/restic.env" >&2; exit 1; }
systemctl is-enabled --quiet yz-backup.timer || { echo "yz-backup.timer is not enabled" >&2; exit 1; }
systemctl is-active --quiet yz-backup.timer || { echo "yz-backup.timer is not active" >&2; exit 1; }

echo "infra healthy at $EXPECTED"
