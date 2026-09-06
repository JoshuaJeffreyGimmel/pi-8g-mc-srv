#!/usr/bin/env bash
# Back up the world, coordinating with the server so the archive is consistent.
#
# Sequence: save-off (stop writes) -> save-all (flush to disk) -> tar -> save-on.
# Without the save-off/save-on pair you can capture a half-written region file.
#
# Run manually:  ./mc backup
# Or from cron:  0 4 * * * /home/joshua/minecraft-pi/scripts/backup.sh

set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER=mc
BACKUP_DIR="./backups"
KEEP_DAYS=7
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

rcon() { docker exec "$CONTAINER" rcon-cli "$@" >/dev/null 2>&1 || true; }

RUNNING=false
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  RUNNING=true
fi

if $RUNNING; then
  echo "Flushing world to disk..."
  rcon save-off
  rcon save-all
  sleep 5
fi

# Always re-enable saving, even if tar fails.
cleanup() {
  if $RUNNING; then
    rcon save-on
  fi
}
trap cleanup EXIT

echo "Archiving to $BACKUP_DIR/world-$STAMP.tgz ..."
tar -czf "$BACKUP_DIR/world-$STAMP.tgz" \
  --exclude='*.jar' \
  --exclude='logs' \
  --exclude='cache' \
  -C ./data .

echo "Pruning backups older than $KEEP_DAYS days..."
find "$BACKUP_DIR" -name 'world-*.tgz' -type f -mtime "+$KEEP_DAYS" -delete

echo "Done: $BACKUP_DIR/world-$STAMP.tgz"
