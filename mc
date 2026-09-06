#!/usr/bin/env bash
# Thin wrapper around the common admin operations.

set -euo pipefail
cd "$(dirname "$0")"

CONTAINER=mc
PACK_DIR="./modpacks"
ENV_FILE="./.env"

usage() {
  cat <<'USAGE'
Usage: ./mc <command> [args]

  up                     start the server
  down                   stop the server (graceful, waits for save)
  restart                restart
  logs                   follow the logs
  status                 container status
  console                interactive RCON console
  cmd <minecraft cmd>    run one RCON command
  players                who is online
  whitelist <name>       add a player to the whitelist
  unwhitelist <name>     remove a player
  pack                   list local .mrpack files, marking the active one
  pack <file.mrpack>     install a local .mrpack and point .env at it
  backup                 tar the world to ./backups
  shell                  shell inside the container
USAGE
}

require_running() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "Container '$CONTAINER' is not running. Try: ./mc up" >&2
    exit 1
  fi
}

active_pack() {
  [ -f "$ENV_FILE" ] || return 0
  # cut -f2- so that URLs containing '=' survive intact.
  grep -m1 '^MODRINTH_MODPACK=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

# Rewrite one KEY=value in .env, in place, without sed substitution — a pack
# filename may contain characters sed would treat as delimiters or backrefs.
set_env_var() {
  local key="$1" value="$2" tmp found=false line
  tmp="$(mktemp ./.env.XXXXXX)"
  trap 'rm -f "$tmp"' RETURN
  if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*|"#$key="*)
          # Keep only the first occurrence, rewritten; drop later duplicates
          # so the file cannot end up with two values for one key.
          if ! $found; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
            found=true
          fi
          ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
    done < "$ENV_FILE"
    # .env holds RCON_PASSWORD; do not widen its permissions.
    chmod --reference="$ENV_FILE" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  else
    chmod 600 "$tmp"
  fi
  $found || printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  trap - RETURN
}

# Print what the pack declares, so a loader/version mismatch with .env is
# visible before the server spends ten minutes failing to start.
pack_info() {
  local f="$1" idx
  command -v unzip >/dev/null 2>&1 || return 0
  idx="$(unzip -p "$f" modrinth.index.json 2>/dev/null)" || return 0
  [ -n "$idx" ] || return 0

  local name mcver loader deps
  if command -v jq >/dev/null 2>&1; then
    name="$(printf '%s' "$idx" | jq -r '.name // empty')"
    mcver="$(printf '%s' "$idx" | jq -r '.dependencies.minecraft // empty')"
    loader="$(printf '%s' "$idx" | jq -r '.dependencies | keys[] | select(. != "minecraft")' 2>/dev/null | head -1 || true)"
  else
    # jq is not installed on Raspberry Pi OS by default, and this check is
    # most useful precisely on a fresh box, so parse the two fields by hand.
    name="$(printf '%s' "$idx" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    deps="$(printf '%s' "$idx" | tr -d '\n\r' | grep -o '"dependencies"[[:space:]]*:[[:space:]]*{[^}]*}' | head -1 || true)"
    mcver="$(printf '%s' "$deps" | grep -o '"minecraft"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    loader="$(printf '%s' "$deps" | grep -o '"[a-z][a-z-]*"[[:space:]]*:' \
      | sed 's/"[[:space:]]*:$//; s/^"//' \
      | grep -v -x -e minecraft -e dependencies | head -1 || true)"
  fi
  loader="${loader%-loader}"

  [ -n "$name" ] && echo "  pack:      $name"
  [ -n "$mcver" ] && echo "  minecraft: $mcver"
  [ -n "$loader" ] && echo "  loader:    $loader"

  local cur_ver cur_loader
  cur_ver="$(grep -m1 '^MC_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  cur_loader="$(grep -m1 '^MODRINTH_LOADER=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  if [ -n "$mcver" ] && [ -n "$cur_ver" ] && [ "$mcver" != "$cur_ver" ]; then
    echo "  WARNING: .env has MC_VERSION=$cur_ver but the pack declares $mcver." >&2
  fi
  if [ -n "$loader" ] && [ -n "$cur_loader" ] && [ "$loader" != "$cur_loader" ]; then
    echo "  WARNING: .env has MODRINTH_LOADER=$cur_loader but the pack declares $loader." >&2
  fi
}

pack_list() {
  local active found=false f
  active="$(active_pack)"
  echo "Packs in $PACK_DIR:"
  for f in "$PACK_DIR"/*.mrpack; do
    [ -e "$f" ] || continue
    found=true
    if [ "/modpacks/$(basename "$f")" = "$active" ]; then
      printf '  * %s (active)\n' "$(basename "$f")"
    else
      printf '    %s\n' "$(basename "$f")"
    fi
  done
  $found || echo "    (none yet — add one with: ./mc pack <file.mrpack>)"
  echo
  echo "MODRINTH_MODPACK=${active:-<unset>}"
}

pack_use() {
  local src="$1" base dest

  # A bare name that already lives in ./modpacks means "switch to that one".
  if [ ! -f "$src" ] && [ "$src" = "${src##*/}" ] && [ -f "$PACK_DIR/$src" ]; then
    src="$PACK_DIR/$src"
  fi

  [ -f "$src" ] || { echo "No such file: $src" >&2; exit 1; }
  case "$src" in
    *.mrpack) ;;
    *) echo "ERROR: expected a .mrpack file — the extension is how the image detects a local pack." >&2
       exit 1 ;;
  esac

  # Catch a renamed zip or a truncated download now, rather than as an
  # unexplained server failure several minutes into startup.
  if command -v unzip >/dev/null 2>&1; then
    if ! unzip -l "$src" 2>/dev/null | grep -q 'modrinth\.index\.json'; then
      echo "ERROR: $src has no modrinth.index.json inside; it is not a valid .mrpack." >&2
      exit 1
    fi
  fi

  mkdir -p "$PACK_DIR"
  base="$(basename "$src")"
  dest="$PACK_DIR/$base"

  if [ "$(cd "$(dirname "$src")" && pwd)/$base" != "$(cd "$PACK_DIR" && pwd)/$base" ]; then
    cp -f "$src" "$dest"
    echo "Copied $base into $PACK_DIR/"
  else
    echo "Using $base already in $PACK_DIR/"
  fi
  # Must stay readable by the container user, which is not root.
  chmod a+r "$dest"

  pack_info "$dest"

  set_env_var MODRINTH_MODPACK "/modpacks/$base"
  # A rebuilt pack keeps its filename, so the installer would otherwise decide
  # nothing changed and skip it.
  set_env_var MC_PACK_FORCE_SYNC "TRUE"

  echo
  echo "MODRINTH_MODPACK=/modpacks/$base"
  echo "Apply with: ./mc restart"
  echo "Switching packs usually needs a fresh world — see README, 'Changing the modpack'."
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
  pack)
    if [ -n "${2:-}" ]; then pack_use "$2"; else pack_list; fi
    ;;
  backup)
    ./scripts/backup.sh
    ;;
  shell)
    require_running
    docker exec -it "$CONTAINER" bash
    ;;
  *)
    usage
    exit 1
    ;;
esac
