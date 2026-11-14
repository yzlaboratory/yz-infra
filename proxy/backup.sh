#!/usr/bin/env bash
# Snapshot Traefik's certificate volume into /srv/proxy/backups so the host
# restic job picks it up. Certificates are reproducible, but re-issuing after
# repeated volume loss can hit Let's Encrypt rate limits.
#
# Stop Traefik briefly so acme.json is not captured mid-write.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p backups

container=$(docker compose ps -q traefik 2>/dev/null | head -n1 || true)
start_after=0
if [[ -n $container && $(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false) == "true" ]]; then
  docker compose stop traefik >/dev/null
  start_after=1
fi
cleanup() {
  if [[ $start_after -eq 1 ]]; then
    if ! docker compose start traefik >/dev/null 2>&1; then
      echo "WARNING: could not restart traefik" >&2
    fi
  fi
}
trap cleanup EXIT

VOLUME_DATA=/var/lib/docker/volumes/proxy-letsencrypt/_data
if [[ -d $VOLUME_DATA ]]; then
  tar -czf backups/acme.tar.gz -C "$VOLUME_DATA" .
fi

find backups -type f -mtime +7 -delete
