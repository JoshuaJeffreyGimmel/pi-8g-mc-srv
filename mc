#!/usr/bin/env bash
# Thin wrapper around the common admin operations.

set -euo pipefail
cd "$(dirname "$0")"

CONTAINER=mc
PACK_DIR="./modpacks"
BACKUP_DIR="./backups"
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
  backup [label]         tar the world to ./backups; a label exempts it
                         from the automatic prune
  backups                list existing backups
  schedule               show whether automatic backups are installed
  schedule apply         make cron match AUTOMATIC_BACKUPS in .env
  shell                  shell inside the container
USAGE
}

require_running() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "Container '$CONTAINER' is not running. Try: ./mc up" >&2
    exit 1
  fi
}

# Read one key from .env without sourcing it — .env holds RCON_PASSWORD, and
# sourcing would execute whatever happens to be in the file.
# cut -f2- so that values containing '=' (URLs) survive intact.
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

# TRUE/true/yes/1 all count as on; anything else, including unset, is off.
env_is_true() {
  case "$(printf '%s' "$(env_get "$1")" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

active_pack() {
  env_get MODRINTH_MODPACK
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
  cur_ver="$(env_get MC_VERSION)"
  cur_loader="$(env_get MODRINTH_LOADER)"
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

list_backups() {
  local f found=false count=0
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "No backups yet. Create one with: ./mc backup"
    return 0
  fi
  # Newest first. The embedded timestamp sorts chronologically, so a reverse
  # name sort is also a reverse time sort.
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    found=true
    count=$((count + 1))
    printf '  %s  %6s  %s\n' \
      "$(date -r "$f" '+%Y-%m-%d %H:%M')" \
      "$(du -h "$f" | cut -f1)" \
      "$(basename "$f")"
  done < <(printf '%s\n' "$BACKUP_DIR"/world-*.tgz | sort -r)
  if ! $found; then
    echo "No backups yet. Create one with: ./mc backup"
    return 0
  fi
  echo
  echo "  $count archive(s), $(du -sh "$BACKUP_DIR" | cut -f1) total in $BACKUP_DIR"
  echo "  Unlabelled archives are pruned after BACKUP_KEEP_DAYS; labelled ones are kept."
}

# The cron entry is wrapped in markers so it can be rewritten or removed
# without disturbing any other crontab entries the user has.
CRON_BEGIN="# >>> minecraft-pi automatic backups >>>"
CRON_END="# <<< minecraft-pi automatic backups <<<"

cron_installed() {
  command -v crontab >/dev/null 2>&1 || return 1
  crontab -l 2>/dev/null | grep -qF "$CRON_BEGIN"
}

schedule_status() {
  local schedule
  schedule="$(env_get BACKUP_SCHEDULE)"; schedule="${schedule:-0 4 * * *}"
  if env_is_true AUTOMATIC_BACKUPS; then
    echo ".env wants:  AUTOMATIC_BACKUPS=TRUE   schedule: $schedule"
  else
    echo ".env wants:  AUTOMATIC_BACKUPS=FALSE"
  fi
  if cron_installed; then
    echo "crontab has: installed"
    crontab -l 2>/dev/null | awk -v b="$CRON_BEGIN" -v e="$CRON_END" \
      '$0==b{s=1;next} $0==e{s=0;next} s{print "  " $0}'
  elif command -v crontab >/dev/null 2>&1; then
    echo "crontab has: nothing"
  else
    echo "crontab has: n/a (no crontab command on this host)"
  fi
  echo
  if env_is_true AUTOMATIC_BACKUPS && ! cron_installed; then
    echo "Out of sync. Run: ./mc schedule apply"
  elif ! env_is_true AUTOMATIC_BACKUPS && cron_installed; then
    echo "Out of sync. Run: ./mc schedule apply"
  else
    echo "In sync."
  fi
}

schedule_apply() {
  if ! command -v crontab >/dev/null 2>&1; then
    echo "ERROR: no crontab command on this host; cannot manage automatic backups." >&2
    exit 1
  fi
  local schedule tmp
  schedule="$(env_get BACKUP_SCHEDULE)"; schedule="${schedule:-0 4 * * *}"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  # Start from the current crontab minus any block we previously installed.
  crontab -l 2>/dev/null | awk -v b="$CRON_BEGIN" -v e="$CRON_END" \
    '$0==b{s=1;next} $0==e{s=0;next} !s{print}' > "$tmp" || true

  if env_is_true AUTOMATIC_BACKUPS; then
    # cron runs with a bare environment and no working directory, so every
    # path here has to be absolute.
    mkdir -p "$PWD/backups"
    {
      echo "$CRON_BEGIN"
      echo "$schedule $PWD/scripts/backup.sh >> $PWD/backups/backup.log 2>&1"
      echo "$CRON_END"
    } >> "$tmp"
    crontab "$tmp"
    echo "Automatic backups enabled: $schedule"
    echo "Log: $PWD/backups/backup.log"
  else
    crontab "$tmp"
    echo "Automatic backups disabled; managed cron entry removed."
  fi
  trap - RETURN
}

case "${1:-}" in
  up)
    docker compose up -d
    echo "Started. Follow startup with: ./mc logs"
    # AUTOMATIC_BACKUPS is a setting in .env, but cron lives on the host and
    # nothing applies it implicitly. Say so, rather than let someone believe
    # backups are running because the variable is set.
    if env_is_true AUTOMATIC_BACKUPS && ! cron_installed; then
      echo
      echo "NOTE: .env sets AUTOMATIC_BACKUPS=TRUE but no cron entry is installed." >&2
      echo "      Backups are NOT running. Install it with: ./mc schedule apply" >&2
    fi
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
    shift
    # An optional label marks the archive as deliberate and exempts it from
    # the automatic prune: ./mc backup before-1.22-upgrade
    ./scripts/backup.sh "$@"
    ;;
  backups)
    list_backups
    ;;
  schedule)
    if [ "${2:-}" = "apply" ]; then schedule_apply; else schedule_status; fi
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
