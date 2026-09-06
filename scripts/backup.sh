#!/usr/bin/env bash
# Back up the world, coordinating with the server so the archive is consistent.
#
# When the server is live:
#   save-off (stop writes) -> save-all flush (block until on disk) -> tar -> save-on
# Without the save-off/save-on pair you can capture a half-written region file.
#
# Run manually:  ./mc backup
# Or from cron:  0 4 * * * /home/joshua/minecraft-pi/scripts/backup.sh

set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER=mc
BACKUP_DIR="./backups"
DATA_DIR="./data"
ENV_FILE="./.env"
RCON_TIMEOUT="${RCON_TIMEOUT:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Read one key out of .env without sourcing it — cron does not load .env, and
# sourcing a file that holds RCON_PASSWORD would execute whatever is in it.
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

KEEP_DAYS="${KEEP_DAYS:-$(env_get BACKUP_KEEP_DAYS)}"
KEEP_DAYS="${KEEP_DAYS:-7}"

# An optional label marks a backup as deliberate: "before-1.22-upgrade".
# Labelled archives are kept indefinitely; see the prune step at the end.
LABEL="${1:-}"
if [ -n "$LABEL" ]; then
  LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
fi
ARCHIVE="$BACKUP_DIR/world-$STAMP${LABEL:+-$LABEL}.tgz"

mkdir -p "$BACKUP_DIR"

# Refuse to run twice at once: cron firing while a manual ./mc backup is still
# running would otherwise interleave two tars of the same world. flock is
# util-linux, so it is always present on the Pi; guard anyway so that a host
# without it degrades to a warning rather than to a false "already running".
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BACKUP_DIR/.lock"
  if ! flock -n 9; then
    echo "Another backup is already running; aborting." >&2
    exit 1
  fi
else
  echo "WARNING: flock unavailable; concurrent runs are not guarded." >&2
fi

SAVES_OFF=false

restore_saving() {
  if $SAVES_OFF; then
    # Best effort, and deliberately not allowed to mask the real exit code.
    timeout "$RCON_TIMEOUT" docker exec "$CONTAINER" rcon-cli save-on >/dev/null 2>&1 \
      || echo "WARNING: could not re-enable saving. Run: ./mc cmd save-on" >&2
  fi
}
# Installed before saving is ever disabled, so an interrupt in the window
# between the two cannot leave a live server with writes turned off.
trap restore_saving EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Every RCON call is bounded. rcon-cli against an unresponsive server blocks
# indefinitely, which in a cron job means a hung process rather than a failure.
rcon() {
  timeout "$RCON_TIMEOUT" docker exec "$CONTAINER" rcon-cli "$@" >/dev/null
}

container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"
}

# Autopause SIGSTOPs the JVM when nobody is online — which is exactly the state
# a 04:00 cron backup finds it in. RCON cannot be answered by a stopped process.
# A paused server has already flushed and is not writing, so the archive is
# consistent without the save dance. 'T' is the stopped state in /proc/PID/stat.
server_paused() {
  local state
  state="$(docker exec "$CONTAINER" sh -c '
    for d in /proc/[0-9]*; do
      [ -r "$d/comm" ] || continue
      [ "$(cat "$d/comm" 2>/dev/null)" = "java" ] || continue
      awk "{print \$3}" "$d/stat" 2>/dev/null
      exit 0
    done
  ' 2>/dev/null || true)"
  [ "${state:-}" = "T" ]
}

if container_running; then
  if server_paused; then
    echo "Server is autopaused; skipping RCON flush (world is already on disk)."
  else
    echo "Flushing world to disk..."
    if ! rcon save-off; then
      echo "ERROR: 'save-off' failed. Refusing to archive a live, writing world." >&2
      exit 1
    fi
    SAVES_OFF=true
    # 'flush' is the blocking form; the old fixed `sleep 5` was a guess that
    # could return before the write finished on a busy server.
    if ! rcon save-all flush; then
      echo "ERROR: 'save-all flush' failed. World may not be fully written." >&2
      exit 1
    fi
  fi
else
  echo "Container not running; archiving the data directory as-is."
fi

# Scope the archive to state that cannot be regenerated. The rest of ./data —
# the mods tree, the Fabric loader, jars, caches — is re-downloaded from the
# modpack on demand and would otherwise dominate seven days of retention.
mapfile -t INCLUDE < <(
  cd "$DATA_DIR" 2>/dev/null || exit 0
  for p in world* config server.properties ops.json whitelist.json \
           banned-players.json banned-ips.json usercache.json; do
    [ -e "$p" ] && printf '%s\n' "$p"
  done
)

if [ "${#INCLUDE[@]}" -eq 0 ]; then
  echo "ERROR: nothing to back up under $DATA_DIR. Has the server ever started?" >&2
  exit 1
fi

echo "Archiving ${#INCLUDE[@]} path(s) to $ARCHIVE ..."
tar -czf "$ARCHIVE" -C "$DATA_DIR" "${INCLUDE[@]}"

# Re-enable saving as soon as the read is done, rather than waiting for the
# exit trap to do it after verification and pruning.
if $SAVES_OFF; then
  rcon save-on || echo "WARNING: could not re-enable saving. Run: ./mc cmd save-on" >&2
  SAVES_OFF=false
fi

echo "Verifying archive..."
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
  echo "ERROR: $ARCHIVE is unreadable. Removing it." >&2
  rm -f "$ARCHIVE"
  exit 1
fi

# Prune only the unlabelled, automatic archives (world-YYYYMMDD-HHMMSS.tgz).
# A labelled backup was taken deliberately, so it is kept until you remove it.
echo "Pruning unlabelled backups older than $KEEP_DAYS days..."
find "$BACKUP_DIR" -maxdepth 1 -type f \
  -regextype posix-extended \
  -regex '.*/world-[0-9]{8}-[0-9]{6}\.tgz' \
  -mtime "+$KEEP_DAYS" -delete

echo "Done: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
