#!/usr/bin/env bash
# Thin wrapper around the common admin operations.
# Usage: ./mc <command> [args]
#   ./mc up                     start the server
#   ./mc down                   stop the server (graceful, waits for save)
#   ./mc restart                restart
#   ./mc logs                   follow the logs
#   ./mc status                 container status
#   ./mc console                interactive RCON console
#   ./mc cmd <minecraft cmd>    run one RCON command
#   ./mc players                who is online
#   ./mc whitelist <name>       add a player to the whitelist
#   ./mc unwhitelist <name>     remove a player
#   ./mc backup                 tar the world to ./backups
#   ./mc shell                  shell inside the container

set -euo pipefail
cd "$(dirname "$0")"

CONTAINER=mc

require_running() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "Container '$CONTAINER' is not running. Try: ./mc up" >&2
    exit 1
  fi
}

case "${1:-}" in
  up)
    docker compose up -d
    echo "Started. Follow startup with: ./mc logs"
    ;;
  down)
    # -t must exceed STOP_SERVER_ANNOUNCE_DELAY so the world finishes saving.
    docker compose down -t 90
    ;;
  restart)
    docker compose down -t 90 && docker compose up -d
    ;;
  logs)
    docker compose logs -f
    ;;
  status)
    docker ps --filter "name=$CONTAINER" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  console)
    require_running
    docker exec -it "$CONTAINER" rcon-cli
    ;;
  cmd)
    require_running
    shift
    docker exec "$CONTAINER" rcon-cli "$@"
    ;;
  players)
    require_running
    docker exec "$CONTAINER" rcon-cli list
    ;;
  whitelist)
    require_running
    [ -n "${2:-}" ] || { echo "Usage: ./mc whitelist <player>" >&2; exit 1; }
    docker exec "$CONTAINER" rcon-cli whitelist add "$2"
    ;;
  unwhitelist)
    require_running
    [ -n "${2:-}" ] || { echo "Usage: ./mc unwhitelist <player>" >&2; exit 1; }
    docker exec "$CONTAINER" rcon-cli whitelist remove "$2"
    ;;
  backup)
    ./scripts/backup.sh
    ;;
  shell)
    require_running
    docker exec -it "$CONTAINER" bash
    ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
