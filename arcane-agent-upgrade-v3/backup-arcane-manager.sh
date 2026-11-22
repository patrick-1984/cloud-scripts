#!/usr/bin/env bash
# Back up an Arcane manager (server) container before upgrading it.
# Saves: docker inspect of the container, every data mount (database, /app/data, projects),
# and the compose files of the stack the container was started from.
# Usage: curl -fsSL URL | bash -s -- [container-name] [-y] [--no-stop]
#   container-name  default: autodetect the single getarcaneapp/arcane or getarcaneapp/manager container
#   -y              do not ask for confirmation
#   --no-stop       copy while the manager runs (no downtime, but SQLite data may be inconsistent)
# Env: BACKUP_DIR (default $HOME)

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
# Docker must never read the piped script from stdin.
dkr() { "$DOCKER" "$@" </dev/null; }

restart_on_exit() {
  local rc=$?
  trap - EXIT
  if [ "${STOPPED:-no}" = yes ]; then
    printf '\nStarting %s again.\n' "$C" >&2
    dkr start "$C" >/dev/null || printf 'Could not start %s; start it by hand: docker start %s\n' "$C" "$C" >&2
  fi
  exit "$rc"
}

main() {
  set -Eeuo pipefail
  umask 077
  BACKUP_DIR=${BACKUP_DIR:-${HOME:-/root}}
  C=; YES=no; STOP=yes; STOPPED=no
  for a in "$@"; do
    case "$a" in
      -y|--yes) YES=yes ;;
      --no-stop) STOP=no ;;
      -h|--help) printf 'Usage: ... | bash -s -- [NAME] [-y] [--no-stop]\nEnv: BACKUP_DIR\n'; return 0 ;;
      -*) die "unknown option: $a" ;;
      *) [ -z "$C" ] || die 'pass only one container NAME'; C=$a ;;
    esac
  done
  DOCKER=$(command -v docker) || die 'docker not found'
  if ! derr=$(dkr version --format '{{.Server.Version}}' 2>&1); then
    printf '\nDocker said:\n%s\n' "$derr" >&2
    die 'cannot talk to the Docker daemon (run as root)'
  fi

  if [ -z "$C" ]; then
    found=()
    names=$(dkr ps -a --format '{{.Names}}') || die 'cannot list containers'
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      # docker ps may show only an image ID once a tag has moved: use the configured image.
      image=$(dkr inspect "$name" --format '{{.Config.Image}}') || continue
      if [[ $image =~ (^|/)getarcaneapp/(arcane|manager)(:|@|$) ]]; then found+=("$name"); fi
    done <<< "$names"
    [ "${#found[@]}" -eq 1 ] || die "found ${#found[@]} Arcane manager containers (${found[*]:-none}); pass the NAME: ... | bash -s -- NAME"
    C=${found[0]}
  fi
  [[ $C =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'invalid container NAME'
  dkr inspect "$C" >/dev/null 2>&1 || die "container $C not found"
  image=$(dkr inspect "$C" --format '{{.Config.Image}}')
  running=$(dkr inspect "$C" --format '{{.State.Running}}')

  env=$(dkr inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}')
  db_url=$(printf '%s\n' "$env" | sed -n 's/^\(ARCANE_\)\{0,1\}DATABASE_URL=//p' | head -n1)
  case "$db_url" in
    postgres*|pg*) PG=yes ;;
    *) PG=no ;;
  esac

  MOUNTS=()
  mounts=$(dkr inspect "$C" --format '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{println}}{{end}}')
  while IFS='|' read -r typ name src dst; do
    [ -n "$dst" ] || continue
    case "$dst" in */docker.sock|*/podman.sock) continue ;; esac
    [ -S "$src" ] && continue
    if [ "$typ" = volume ]; then MOUNTS+=("$dst|volume $name"); else MOUNTS+=("$dst|host folder $src"); fi
  done <<< "$mounts"
  HAS_DATA_MOUNT=no
  for m in "${MOUNTS[@]}"; do case "${m%%|*}" in /app/data|/app/data/*) HAS_DATA_MOUNT=yes ;; esac; done
  [ "$HAS_DATA_MOUNT" = yes ] || MOUNTS+=("/app/data|inside the container (no volume)")

  workdir=$(dkr inspect "$C" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
  files=$(dkr inspect "$C" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)
  [ "$workdir" != '<no value>' ] || workdir=
  [ "$files" != '<no value>' ] || files=
  COMPOSE=()
  if [ -n "$files" ]; then
    IFS=, read -r -a parts <<< "$files"
    for f in "${parts[@]}"; do [ -f "$f" ] && COMPOSE+=("$f"); done
  fi
  if [ -n "$workdir" ] && [ -f "$workdir/.env" ]; then COMPOSE+=("$workdir/.env"); fi

  say "Arcane manager: $C (image $image, running: $running)"
  for m in "${MOUNTS[@]}"; do printf '  data: %s  (%s)\n' "${m%%|*}" "${m#*|}"; done
  if [ "${#COMPOSE[@]}" -gt 0 ]; then printf '  compose: %s\n' "${COMPOSE[*]}"; else printf '  compose: none found (not started by docker compose, or files moved)\n'; fi
  [ "$PG" = no ] || printf '  NOTE: the database is PostgreSQL. This script does not dump it: run pg_dump separately.\n'
  if [ "$STOP" = yes ] && [ "$running" = true ]; then
    printf '  The manager will be stopped during the copy and started again afterwards.\n'
  elif [ "$STOP" = no ]; then
    printf '  --no-stop: copying while it runs; the SQLite database may be inconsistent.\n'
  fi
  printf '  Target: %s\n' "$BACKUP_DIR"
  if [ "$YES" != yes ]; then
    { exec 3</dev/tty; } 2>/dev/null || die 'no terminal to confirm on; nothing changed. Rerun with: ... | bash -s -- -y'
    ok=
    read -r -p "Proceed? [y/N] " ok <&3 || true
    exec 3<&-
    case "$ok" in y|Y) ;; *) printf 'Nothing changed.\n'; return 0 ;; esac
  fi

  mkdir -p "$BACKUP_DIR"
  OUT=$(mktemp -d "$BACKUP_DIR/arcane-manager-backup.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
  dkr inspect "$C" > "$OUT/inspect.json"
  trap restart_on_exit EXIT
  if [ "$STOP" = yes ] && [ "$running" = true ]; then
    say "Stopping $C"
    dkr stop "$C" >/dev/null || [ "$(dkr inspect "$C" --format '{{.State.Running}}')" = false ] || die "cannot stop $C"
    STOPPED=yes
  fi
  n=0
  for m in "${MOUNTS[@]}"; do
    dst=${m%%|*}; n=$((n+1))
    printf '%s\n' "$dst" > "$OUT/$n.path"
    dkr cp "$C:$dst" - | gzip > "$OUT/$n.tar.gz" || die "backup of $dst failed"
    tar -tzf "$OUT/$n.tar.gz" >/dev/null || die "backup of $dst is not a valid archive"
    printf 'Backed up %s -> %s\n' "$dst" "$OUT/$n.tar.gz"
  done
  if [ "${#COMPOSE[@]}" -gt 0 ]; then
    tar -czf "$OUT/compose.tar.gz" "${COMPOSE[@]}" 2>/dev/null || tar -czf "$OUT/compose.tar.gz" -P "${COMPOSE[@]}"
    printf 'Backed up compose files -> %s\n' "$OUT/compose.tar.gz"
  fi
  if [ "$STOPPED" = yes ]; then
    say "Starting $C again"
    dkr start "$C" >/dev/null
    STOPPED=no
  fi
  trap - EXIT
  (cd "$OUT" && sha256sum -- * > SHA256SUMS) || true

  say "Backup complete: $OUT"
  ls -l "$OUT"
  printf '\nCopy this folder off the host before upgrading. Each N.tar.gz holds the folder named in N.path;\n'
  # shellcheck disable=SC2016  # literal command text for the user
  printf 'to put one back into a (stopped) container: gunzip -c N.tar.gz | docker cp - CONTAINER:$(dirname "$(cat N.path)")\n'
}

main "$@" </dev/null
