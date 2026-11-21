#!/usr/bin/env bash
set -euo pipefail

compose_dir=$1
service=$2
volume_data=$3
archive=$4

cd "$compose_dir"
mkdir -p backups

container=$(docker compose ps -q "$service" 2>/dev/null | head -n1 || true)
start_after=0
if [[ -n $container && $(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false) == "true" ]]; then
  docker compose stop "$service" >/dev/null
  start_after=1
fi
cleanup() {
  if [[ $start_after -eq 1 ]]; then
    if ! docker compose start "$service" >/dev/null 2>&1; then
      echo "WARNING: could not restart $service" >&2
    fi
  fi
}
trap cleanup EXIT

if [[ ! -d $volume_data ]]; then
  echo "missing volume data directory: $volume_data" >&2
  exit 1
fi

tar -czf "backups/$archive" -C "$volume_data" .
find backups -type f -mtime +7 -delete
