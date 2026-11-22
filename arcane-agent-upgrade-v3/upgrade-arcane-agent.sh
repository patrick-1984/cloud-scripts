#!/usr/bin/env bash
# Upgrade an existing Arcane 2.x edge agent, keeping its token and data.
# Usage: curl -fsSL URL | bash -s -- [container-name] [-y]
# Env: IMAGE, BRIDGE_IMAGE, BACKUP_DIR, DATA_HOST_DIR_OVERRIDE (see README).

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
# Even a Docker client supplied by snap must never read the piped script.
dkr() { local r=0; "$DOCKER" "$@" </dev/null || r=$?; [ "$r" -eq 0 ] || FAILED_DKR="docker ${1:-} ${2:-} (called from line ${BASH_LINENO[0]})"; return "$r"; }

env_value() {
  local entry
  while IFS= read -r entry; do
    case "$entry" in "$1="*) printf '%s' "${entry#*=}"; return 0 ;; esac
  done <<< "$OLD_ENV"
  return 1
}

invert_bool() {
  case "$1" in
    true|True|TRUE|1|t|T) printf false ;;
    false|False|FALSE|0|f|F) printf true ;;
    *) die "invalid boolean value for $2" ;;
  esac
}

mask() {
  local x
  for x in "$@"; do
    case "$x" in
      *=*) case "${x%%=*}" in
        *TOKEN*|*KEY*|*SECRET*|*PASSWORD*|*DATABASE_URL|*PROXY) x="${x%%=*}=***" ;;
      esac ;;
    esac
    printf '%q ' "$x"
  done
}

rollback_hint() {
  printf 'Rollback (stop the new agent before restoring any data):\n  docker rm -f %q\n  docker rename %q %q\n' "$C" "$C-old" "$C"
  printf '  # Restore the pre-upgrade data backups if the database was migrated.\n  docker start %q\n' "$C"
  printf 'Backups and original inspect: %s\n' "$BACKUP_SET"
}

recover() {
  local rc=$?
  trap - EXIT INT TERM
  [ "$rc" -ne 0 ] && [ "$RECOVER" = yes ] || return "$rc"
  # Recovery is best effort; retain a failing exit code and all backups.
  set +e
  printf '\nUpgrade failed at line %s: %s (exit %s)\nAttempting to recover the original container.\n' "${FAILED_LINE:-?}" "${FAILED_DKR:-${FAILED_CMD:-?}}" "$rc" >&2
  if [ "$RENAMED" = yes ]; then
    if dkr inspect "$C" >/dev/null 2>&1; then
      if ! dkr rm -f "$C" >/dev/null; then
        printf 'Could not remove the new container; original remains at %s-old.\n' "$C" >&2
        rollback_hint >&2
        exit "$rc"
      fi
    fi
    if ! dkr rename "$C-old" "$C"; then
      printf 'Could not restore the original name. Start %s-old after checking its data.\n' "$C" >&2
      rollback_hint >&2
      exit "$rc"
    fi
  fi
  if [ "$WAS_RUNNING" = true ]; then
    if dkr start "$C" >/dev/null; then
      printf 'Original container restored as %s; restart requested.\n' "$C" >&2
    else
      printf 'Could not restart %s; Docker reported the error above.\n' "$C" >&2
    fi
  else
    printf 'Original container restored as %s (it was stopped before the upgrade).\n' "$C" >&2
  fi
  if [ "$DATA_TOUCHED" = yes ]; then
    printf 'The database may have migrated. If the old agent cannot run, stop it and restore data from %s before starting it.\n' "$BACKUP_SET" >&2
  fi
  exit "$rc"
}

healthy() {
  local st lg
  st=$(dkr inspect "$1" --format '{{.State.Running}} {{.State.Restarting}} {{.RestartCount}}' 2>/dev/null) || return 1
  [ "$st" = 'true false 0' ] || return 1
  lg=$(dkr logs --tail 100 "$1" 2>&1) || return 1
  ! printf '%s\n' "$lg" | grep -q -E 'Failed to run Arcane|legacy environment variables|upgrade to Arcane v2.17|level=fatal'
}

# This function is called in a conditional: explicitly check every Docker failure.
# Return 2 only for the known database upgrade gate, 1 for all other failures.
start_and_check() {
  local img=$1 logs state i
  shift
  if dkr inspect "$C" >/dev/null 2>&1; then
    dkr rm -f "$C" >/dev/null || return 1
  fi
  DATA_TOUCHED=yes
  dkr run "${BASE[@]}" "$@" "$img" >/dev/null || return 1
  for ((i=0; i<15; i++)); do
    sleep 3
    logs=$(dkr logs --tail 200 "$C" 2>&1) || { printf '%s\n' "$logs" >&2; return 1; }
    case "$logs" in *'upgrade to Arcane v2.17.1 first'*) return 2 ;; esac
    if printf '%s\n' "$logs" | grep -q -E 'Failed to run Arcane|legacy environment variables|direct agents were removed|level=fatal'; then
      printf '%s\n' "$logs" | grep -o -E 'replace [^"]*' | sort -u | sed 's/^/  -> /' >&2 || true
      return 1
    fi
    state=$(dkr inspect "$C" --format '{{.State.Running}} {{.State.Restarting}} {{.RestartCount}}') || return 1
    [ "$state" = 'true false 0' ] || return 1
  done
}

main() {
  set -Eeuo pipefail
  FAILED_CMD=; FAILED_LINE=; FAILED_DKR=
  trap 'FAILED_CMD=$BASH_COMMAND; FAILED_LINE=$LINENO' ERR
  umask 077
  IMAGE=${IMAGE:-ghcr.io/getarcaneapp/agent:v3}
  BRIDGE_IMAGE=${BRIDGE_IMAGE:-ghcr.io/getarcaneapp/agent:v2.17.3}
  BACKUP_DIR=${BACKUP_DIR:-${HOME:-/root}}
  C=; YES=no; RECOVER=no; RENAMED=no; DATA_TOUCHED=no
  for a in "$@"; do
    case "$a" in
      -y|--yes) YES=yes ;;
      -h|--help)
        printf 'Usage: ... | bash -s -- [NAME] [-y]\nEnv: IMAGE, BRIDGE_IMAGE, BACKUP_DIR, DATA_HOST_DIR_OVERRIDE\n'
        return 0 ;;
      -*) die "unknown option: $a" ;;
      *) [ -z "$C" ] || die 'pass only one container NAME'; C=$a ;;
    esac
  done
  DOCKER=$(command -v docker) || die 'docker not found (include /snap/bin in PATH for snap Docker)'
  if ! derr=$(dkr version --format '{{.Server.Version}}' 2>&1); then
    printf '\nDocker client: %s\nUser: %s  HOME=%s\nDOCKER_HOST=%s  DOCKER_CONTEXT=%s\nDocker said:\n%s\n' \
      "$DOCKER" "$(id -un)" "${HOME:-<unset>}" "${DOCKER_HOST:-<unset>}" "${DOCKER_CONTEXT:-<unset>}" "$derr" >&2
    die 'cannot talk to the Docker daemon (details above)'
  fi

  if [ -z "$C" ]; then
    found=()
    names=$(dkr ps -a --format '{{.Names}}') || die 'cannot list containers'
    while IFS= read -r name; do
      case "$name" in ''|*-old) continue ;; esac
      image=$(dkr inspect "$name" --format '{{.Config.Image}}') || die "cannot inspect $name"
      env=$(dkr inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}') || die "cannot read environment of $name"
      agent=no
      if [[ $image =~ (^|/)getarcaneapp/(agent|arcane-headless)(:|@|$) ]]; then agent=yes; fi
      while IFS= read -r e; do
        case "$e" in EDGE_AGENT=true|ARCANE_AGENT=true|AGENT_TOKEN=*) agent=yes ;; esac
      done <<< "$env"
      [ "$agent" = yes ] || continue
      found+=("$name")
      [ "$name" != arcane-edge-agent ] || C=$name
    done <<< "$names"
    if [ -z "$C" ] && [ "${#found[@]}" -eq 0 ] && dkr inspect arcane-edge-agent-old >/dev/null 2>&1; then C=arcane-edge-agent; fi
    if [ -z "$C" ]; then
      [ "${#found[@]}" -eq 1 ] || die "found ${#found[@]} agent containers (${found[*]:-none}); pass NAME: ... | bash -s -- NAME -y"
      C=${found[0]}
    fi
  fi
  # Accept only names, not IDs/options: all later operations refer to this name.
  [[ $C =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'invalid container NAME'
  if dkr inspect "$C-old" >/dev/null 2>&1; then
    if dkr inspect "$C" >/dev/null 2>&1 && healthy "$C"; then
      say "$C is running and healthy; $C-old is the previous agent. Nothing changed. Remove it when Arcane shows the host Online: docker rm $C-old"
      return 0
    fi
    say "Resuming an earlier failed upgrade: $C-old is the original agent; removing the failed $C and retrying"
    if dkr inspect "$C" >/dev/null 2>&1; then dkr rm -f "$C" >/dev/null || die "cannot remove the failed $C"; fi
    dkr rename "$C-old" "$C" || die "cannot rename $C-old back to $C"
  fi
  C=$(dkr inspect "$C" --format '{{.Name}}') || die "container $C not found"
  C=${C#/}
  cur_image=$(dkr inspect "$C" --format '{{.Config.Image}}')
  image_id=$(dkr inspect "$C" --format '{{.Image}}')
  # Inspect the immutable image ID: :latest and docker ps may no longer name this image.
  meta=$(dkr image inspect "$image_id" --format '{{if .Config.Labels}}{{index .Config.Labels "org.opencontainers.image.version"}}{{end}}{{println}}{{range .RepoTags}}{{println .}}{{end}}')
  version=${meta%%$'\n'*}
  already=no
  if [[ $version =~ ^v?3($|\.) ]]; then
    already=yes
  elif [ -z "$version" ] || [ "$version" = '<no value>' ]; then
    while IFS= read -r ref; do
      if [[ $ref =~ (^|/)getarcaneapp/(agent|arcane-headless):v?3($|[.@-]) ]]; then already=yes; fi
    done <<< "$cur_image"$'\n'"$meta"
  fi
  if [ "$already" = yes ]; then say "$C is already v3 ($cur_image); nothing changed."; return 0; fi
  if dkr inspect "$C-old" >/dev/null 2>&1; then
    die "$C-old already exists; preserve it until you have verified the current agent and its data"
  fi
  say "Agent container: $C (image $cur_image)"
  OLD_ENV=$(dkr inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}')
  WAS_RUNNING=$(dkr inspect "$C" --format '{{.State.Running}}')

  BASE=(-d --name "$C" --no-healthcheck)
  pol=$(dkr inspect "$C" --format '{{.HostConfig.RestartPolicy.Name}}')
  retries=$(dkr inspect "$C" --format '{{.HostConfig.RestartPolicy.MaximumRetryCount}}')
  pol=${pol:-no}
  if [ "$pol" = on-failure ] && [ "$retries" -gt 0 ]; then pol="$pol:$retries"; fi
  BASE+=(--restart "$pol")
  net=$(dkr inspect "$C" --format '{{.HostConfig.NetworkMode}}')
  case "$net" in default|bridge|'') ;; *) BASE+=(--network "$net") ;; esac
  networks=$(dkr inspect "$C" --format '{{len .NetworkSettings.Networks}}')
  [ "$networks" -le 1 ] || die 'multiple Docker networks; migrate this container manually to preserve its attachments'
  hosts=$(dkr inspect "$C" --format '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}')
  while IFS= read -r h; do [ -z "$h" ] || BASE+=(--add-host "$h"); done <<< "$hosts"

  # Preserve the database path and the settings needed to decrypt/use the same data.
  DATA_DIR=/app/data
  db_url=$(env_value ARCANE_DATABASE_URL || env_value DATABASE_URL || true)
  case "$db_url" in
    file:*|sqlite:*|/*)
      p=${db_url#file:}; p=${p#sqlite:}; p=${p%%\?*}
      case "$p" in ///*) p=${p#//} ;; esac
      case "$p" in /*) ;; *) p="/app/$p" ;; esac
      DATA_DIR=$(dirname "$p"); DATA_DIR=${DATA_DIR%/.} ;;
  esac
  [ "$DATA_DIR" != / ] || die 'database directory is /; migrate this layout manually'
  # Always back up the data directory, including when it is in the writable layer.
  MOUNT_DSTS=("$DATA_DIR"); DATA_WHERE=; DATA_HOST_DIR=
  mounts=$(dkr inspect "$C" --format '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}|{{.RW}}|{{.Propagation}}{{println}}{{end}}')
  while IFS='|' read -r typ name src dst rw propagation; do
    [ -n "$dst" ] || continue
    opts=rw; [ "$rw" != false ] || opts=ro
    case "$typ" in
      volume) spec="$name:$dst:$opts" ;;
      bind) spec="$src:$dst:$opts"; [ -z "$propagation" ] || spec="$spec,$propagation" ;;
      *) die "unsupported mount type $typ at $dst; migrate this layout manually" ;;
    esac
    BASE+=(-v "$spec")
    case "$dst" in
      */docker.sock|*/podman.sock) ;;
      *) if [ "$dst" != "$DATA_DIR" ] && [ ! -S "$src" ]; then MOUNT_DSTS+=("$dst"); fi ;;
    esac
    case "$DATA_DIR/" in "${dst%/}/"*)
      [ "$rw" != false ] || die "agent data at $dst is read-only"
      if [ "$typ" = volume ]; then
        if [[ $name =~ ^[a-f0-9]{64}$ ]]; then DATA_WHERE="anonymous volume $name (host path $src)"
        else DATA_WHERE="named volume $name (host path $src)"; fi
      else DATA_WHERE="host folder $src (bind mount)"; fi ;;
    esac
  done <<< "$mounts"
  if [ -z "$DATA_WHERE" ]; then
    if [ -w /opt ]; then DATA_HOST_DIR=${DATA_HOST_DIR_OVERRIDE:-/opt/arcane-agent/$C}
    else DATA_HOST_DIR=${DATA_HOST_DIR_OVERRIDE:-${HOME:-/root}/arcane-agent/$C}; fi
    case "$DATA_HOST_DIR" in /*) ;; *) die 'DATA_HOST_DIR_OVERRIDE must be an absolute path' ;; esac
    case "$DATA_HOST_DIR" in *:*) die 'DATA_HOST_DIR_OVERRIDE must not contain a colon' ;; esac
    if [ -e "$DATA_HOST_DIR" ]; then
      [ -d "$DATA_HOST_DIR" ] || die "$DATA_HOST_DIR is not a directory"
      [ -z "$(ls -A "$DATA_HOST_DIR")" ] || die "$DATA_HOST_DIR is not empty; set DATA_HOST_DIR_OVERRIDE to an empty folder"
    fi
    DATA_WHERE="INSIDE the container; will copy to $DATA_HOST_DIR"
    BASE+=(-v "$DATA_HOST_DIR:$DATA_DIR")
  fi

  ENV_V3=(); ENV_V2=(); have_token=no; have_manager=no
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    k=${e%%=*}; v=${e#*=}
    # V2 must receive its old names, including database/encryption/project settings.
    case "$k" in ARCANE_*) ;; *) ENV_V2+=(-e "$e") ;; esac
    case "$k" in
      EDGE_AGENT|ARCANE_AGENT|AGENT_MODE|ARCANE_AGENT_MODE|EDGE_MUX_DISABLED|ARCANE_EDGE_MUX_DISABLED) continue ;;
      MANAGER_API_URL|AGENT_TOKEN) k="ARCANE_$k" ;;
      EDGE_*) k="ARCANE_AGENT_${k#EDGE_}" ;;
      ARCANE_EDGE_AGENT) continue ;;
      ARCANE_EDGE_*) k="ARCANE_AGENT_${k#ARCANE_EDGE_}" ;;
      ANALYTICS_DISABLED|UPDATE_CHECK_DISABLED)
        v=$(invert_bool "$v" "$k"); k="ARCANE_${k%_DISABLED}_ENABLED" ;;
      DATABASE_URL|ENCRYPTION_KEY|ENCRYPTION_KEY_FILE|PROJECTS_DIRECTORY|PROJECTS_DIRECTORY_FILE|UI_CONFIGURATION_DISABLED)
        k="ARCANE_$k" ;;
      ARCANE_*) ;;
      PUID|PGID|TZ|DOCKER_*|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|ALL_PROXY|http_proxy|https_proxy|no_proxy|all_proxy|OTEL_*) ;;
      *) continue ;;
    esac
    # An explicitly supplied v3 spelling wins over a legacy spelling, regardless of order.
    if canonical=$(env_value "$k"); then v=$canonical; fi
    case "$k" in
      ARCANE_AGENT_TRANSPORT)
        case "$v" in poll|'') v=auto ;; auto|grpc|websocket) ;; *) die 'ARCANE_AGENT_TRANSPORT must be auto, grpc or websocket' ;; esac ;;
      ARCANE_AGENT_TOKEN) [ -z "$v" ] || have_token=yes ;;
      ARCANE_MANAGER_API_URL) [ -z "$v" ] || have_manager=yes ;;
    esac
    ENV_V3+=(-e "$k=$v")
  done <<< "$OLD_ENV"
  ENV_V3+=(-e ARCANE_AGENT=true)
  [ "$have_token" = yes ] || die "no nonempty AGENT_TOKEN/ARCANE_AGENT_TOKEN in $C; use a new enrollment command from Arcane"
  [ "$have_manager" = yes ] || die "no MANAGER_API_URL/ARCANE_MANAGER_API_URL in $C"
  # Translate prefixed settings back for the bridge, after the original v2 values.
  for ((i=1; i<${#ENV_V3[@]}; i+=2)); do
    e=${ENV_V3[i]}; k=${e%%=*}; v=${e#*=}
    case "$k" in
      ARCANE_AGENT) k=EDGE_AGENT ;;
      ARCANE_AGENT_*) k="EDGE_${k#ARCANE_AGENT_}"; [ "$k" != EDGE_TOKEN ] || k=AGENT_TOKEN ;;
      ARCANE_ANALYTICS_ENABLED|ARCANE_UPDATE_CHECK_ENABLED)
        v=$(invert_bool "$v" "$k"); k="${k#ARCANE_}"; k="${k%_ENABLED}_DISABLED" ;;
      ARCANE_*) k=${k#ARCANE_} ;;
      *) continue ;;
    esac
    ENV_V2+=(-e "$k=$v")
  done

  say 'New container:'
  printf 'docker run '; mask "${BASE[@]}" "${ENV_V3[@]}" "$IMAGE"; printf '\n'
  printf 'Agent data (%s): %s\nWill back up: %s -> %s\n' "$DATA_DIR" "$DATA_WHERE" "${MOUNT_DSTS[*]}" "$BACKUP_DIR"
  if [ "$YES" != yes ]; then
    { exec 3</dev/tty; } 2>/dev/null || die 'no terminal to confirm on; nothing changed. Rerun with: ... | bash -s -- -y'
    ok=
    read -r -p "Proceed? The old container is kept as $C-old. [y/N] " ok <&3 || true
    exec 3<&-
    case "$ok" in y|Y) ;; *) printf 'Nothing changed.\n'; return 0 ;; esac
  fi

  mkdir -p "$BACKUP_DIR"
  # Private, unique directory prevents overwriting backups on a second run in the same second.
  BACKUP_SET=$(mktemp -d "$BACKUP_DIR/$C.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
  dkr inspect "$C" > "$BACKUP_SET/inspect.json"
  say "Pulling $IMAGE"
  dkr pull "$IMAGE"
  trap recover EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  RECOVER=yes
  say "Stopping $C"
  if ! serr=$(dkr stop "$C" 2>&1 >/dev/null); then
    [ "$(dkr inspect "$C" --format '{{.State.Running}}')" = false ] || die "docker stop $C failed: $serr"
    printf 'docker stop reported an error but %s is stopped: %s\n' "$C" "$serr" >&2
  fi
  n=0
  for dst in "${MOUNT_DSTS[@]}"; do
    n=$((n+1))
    f="$BACKUP_SET/$n.tar.gz"
    printf '%s\n' "$dst" > "$BACKUP_SET/$n.path"
    # gzip alone produces a nonempty file even on empty input: validate the tar too.
    dkr cp "$C:$dst" - | gzip > "$f" || die "backup of $dst failed"
    tar -tzf "$f" >/dev/null || die "backup of $dst is not a valid tar archive"
    printf 'Backup of %s: %s\n' "$dst" "$f"
  done
  if [ -n "$DATA_HOST_DIR" ]; then
    mkdir -p "$DATA_HOST_DIR"
    dkr cp "$C:$DATA_DIR/." "$DATA_HOST_DIR/" || die "copying $DATA_DIR to $DATA_HOST_DIR failed"
    printf 'Agent data copied to %s\n' "$DATA_HOST_DIR"
  fi
  dkr rename "$C" "$C-old"
  RENAMED=yes
  say "Starting $IMAGE"
  rc=0; start_and_check "$IMAGE" "${ENV_V3[@]}" || rc=$?
  if [ "$rc" -eq 2 ]; then
    say "The database needs an intermediate migration with $BRIDGE_IMAGE"
    dkr pull "$BRIDGE_IMAGE"
    rc2=0; start_and_check "$BRIDGE_IMAGE" "${ENV_V2[@]}" || rc2=$?
    [ "$rc2" -eq 0 ] || die "$BRIDGE_IMAGE did not stay up"
    dkr stop "$C" >/dev/null
    say "Starting $IMAGE again"
    rc=0; start_and_check "$IMAGE" "${ENV_V3[@]}" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    dkr logs --tail 40 "$C" 2>&1 || true
    die "$IMAGE did not stay up (see logs above)"
  fi
  RECOVER=no
  say "Done: $C runs $IMAGE. Last log lines:"
  dkr logs --tail 15 "$C" 2>&1 || true
  printf '\nCheck that the host shows Online in Arcane (Agents). Then remove the old container: docker rm %q\n' "$C-old"
  rollback_hint
}

# Bash parses all definitions before starting work. No child inherits the curl pipe;
# only the confirmation read above uses the terminal, and pipelines use their own input.
main "$@" </dev/null
