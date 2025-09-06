#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a

COMFY_DIR="${COMFY_DIR:-$HOME/ComfyUI}"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-Backups/ComfyUI}"
DO_UNMOUNT="${DO_UNMOUNT:-true}"

HOST="$(hostname -s || echo host)"
TS="$(date -u +'%Y%m%dT%H%M%SZ')"
ARCHIVE_LOCAL="/tmp/comfyui_${HOST}_${TS}.tgz"
ARCHIVE_REMOTE="${REMOTE_BACKUP_DIR}/comfyui_${HOST}_${TS}.tgz"

TAR_EXCLUDES=( "--exclude=$COMFY_DIR/user/cache" "--exclude=$COMFY_DIR/.git" )
log(){ echo "[$(date +'%H:%M:%S')] $*"; }
find_pids(){ pgrep -f "$COMFY_DIR/main.py" || true; }

graceful_stop(){
  local pids; pids="$(find_pids)"
  if [ -n "$pids" ]; then
    log "SIGTERM → $pids"; kill $pids || true
    for _ in {1..20}; do sleep 1; [ -z "$(find_pids)" ] && { log "gestoppt."; return; } done
    log "SIGKILL …"; kill -9 $pids || true
  else
    log "ComfyUI läuft nicht."
  fi
}

flush_vfs(){ log "rclone vfs/flush …"; rclone rc vfs/flush _async=false || log "Warnung: rc nicht aktiv."; }

create_tar(){
  log "Packe $COMFY_DIR → $ARCHIVE_LOCAL"
  tar -czpf "$ARCHIVE_LOCAL" "${TAR_EXCLUDES[@]}" -C "$(dirname "$COMFY_DIR")" "$(basename "$COMFY_DIR")"
  du -h "$ARCHIVE_LOCAL" || true
}

upload(){
  log "Upload nach ${GDRIVE_REMOTE}:${REMOTE_BACKUP_DIR}"
  rclone mkdir "${GDRIVE_REMOTE}:${REMOTE_BACKUP_DIR}" || true
  rclone copy "$ARCHIVE_LOCAL" "${GDRIVE_REMOTE}:${REMOTE_BACKUP_DIR}" --progress
  log "Verifikation (Größe):"
  local ls; ls="$(rclone lsjson "${GDRIVE_REMOTE}:${ARCHIVE_REMOTE}" --hash 2>/dev/null || true)"
  [ -n "$ls" ] && echo "$ls" | jq -r '.[0].Size, .[0].MD5' || echo "Keine LSJSON-Daten verfügbar."
}

maybe_unmount(){
  if [ "${DO_UNMOUNT}" = true ]; then
    mount | grep -q "on $HOME/gdrive type fuse.rclone" && { log "Unmount gdrive"; fusermount3 -u "$HOME/gdrive" || true; } || log "gdrive nicht gemountet."
  fi
}

log "Shutdown & Backup …"
[ -d "$COMFY_DIR" ] || { echo "ComfyUI nicht gefunden: $COMFY_DIR"; exit 1; }

graceful_stop
flush_vfs
create_tar
upload
flush_vfs
maybe_unmount
log "Fertig. Lokal: $ARCHIVE_LOCAL | Remote: ${GDRIVE_REMOTE}:${ARCHIVE_REMOTE}"
