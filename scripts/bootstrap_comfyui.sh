#!/usr/bin/env bash
set -euo pipefail

# === Config laden ===
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
# Defaults
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
GDRIVE_ROOT_FOLDER_ID="${GDRIVE_ROOT_FOLDER_ID:-}"
RCLONE_CLIENT_ID="${RCLONE_CLIENT_ID:-}"
RCLONE_CLIENT_SECRET="${RCLONE_CLIENT_SECRET:-}"
COMFY_DIR="${COMFY_DIR:-$HOME/ComfyUI}"
PORT="${PORT:-8188}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
GDRIVE_MOUNT="${GDRIVE_MOUNT:-$HOME/gdrive}"
RCLONE_LOG_DIR="${RCLONE_LOG_DIR:-$HOME/rclone_logs}"
RCLONE_LOG_FILE="$RCLONE_LOG_DIR/mount.log"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-Backups/ComfyUI}"
VENV_DIR="$COMFY_DIR/.venv"

GDRIVE_MODELS_DIR="$GDRIVE_MOUNT/models"
GDRIVE_WORKFLOWS_DIR="$GDRIVE_MOUNT/workflows"
GDRIVE_INPUT_DIR="$GDRIVE_MOUNT/input"
GDRIVE_OUTPUT_DIR="$GDRIVE_MOUNT/output"

need_cmd(){ command -v "$1" >/dev/null 2>&1; }
in_file(){ grep -qE "^$1" "$2"; }
log(){ echo "[$(date +'%H:%M:%S')] $*"; }

restore_from_latest_backup(){
  log "Suche neuestes Backup in ${GDRIVE_REMOTE}:${REMOTE_BACKUP_DIR} …"
  local latest
  latest="$(rclone lsjson "${GDRIVE_REMOTE}:${REMOTE_BACKUP_DIR}" --files-only \
            | jq -r 'max_by(.ModTime)//empty | .Path')"
  [ -z "${latest:-}" ] && return 1
  log "Backup: $latest"
  local tmp="/tmp/${latest##*/}"
  rclone copy "${GDRIVE_REMOTE}:${REMOTE_BACKUP_DIR}/${latest}" /tmp --progress
  tar -xzpf "$tmp" -C "$HOME/.."
}

ensure_symlinks(){
  log "Setze Symlinks auf GDrive …"
  mkdir -p "$COMFY_DIR/user/default" \
           "$GDRIVE_MODELS_DIR" "$GDRIVE_WORKFLOWS_DIR" "$GDRIVE_INPUT_DIR" "$GDRIVE_OUTPUT_DIR"
  rm -rf "$COMFY_DIR/models" "$COMFY_DIR/user/default/workflows" "$COMFY_DIR/input" "$COMFY_DIR/output" || true
  ln -sfn "$GDRIVE_MODELS_DIR"    "$COMFY_DIR/models"
  ln -sfn "$GDRIVE_WORKFLOWS_DIR" "$COMFY_DIR/user/default/workflows"
  ln -sfn "$GDRIVE_INPUT_DIR"     "$COMFY_DIR/input"
  ln -sfn "$GDRIVE_OUTPUT_DIR"    "$COMFY_DIR/output"
}

fresh_setup(){
  log "Frisches Setup …"
  if [ ! -d "$COMFY_DIR/.git" ]; then
    git clone https://github.com/comfyanonymous/ComfyUI "$COMFY_DIR"
  else
    (cd "$COMFY_DIR" && git fetch --all && git pull --rebase) || true
  fi
  [ -d "$VENV_DIR" ] || "$PYTHON_BIN" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools
  [ -f "$COMFY_DIR/requirements.txt" ] && "$VENV_DIR/bin/pip" install -r "$COMFY_DIR/requirements.txt"
  mkdir -p "$COMFY_DIR/custom_nodes"
  if [ ! -d "$COMFY_DIR/custom_nodes/ComfyUI-Manager/.git" ]; then
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$COMFY_DIR/custom_nodes/ComfyUI-Manager"
  else
    (cd "$COMFY_DIR/custom_nodes/ComfyUI-Manager" && git fetch --all && git pull --rebase) || true
  fi
}

torch_probe(){
  "$VENV_DIR/bin/python" - <<'PY' || true
try:
    import torch, sys
    print(f"Python: {sys.version.split()[0]}")
    print(f"Torch:  {torch.__version__}, CUDA: {getattr(torch.version,'cuda',None)}, cuda_is_available={torch.cuda.is_available()}")
except Exception as e:
    print("Hinweis: Torch noch nicht importierbar. OK, falls später via ComfyUI-Manager kommt.")
    print("Fehler:", e)
PY
}

start_comfy(){
  log "Starte ComfyUI auf Port $PORT …"
  trap 'log "rclone vfs/flush …"; rclone rc vfs/flush _async=false || true' EXIT
  cd "$COMFY_DIR"
  exec "$VENV_DIR/bin/python" main.py --listen 0.0.0.0 --port "$PORT"
}

# ===== System vorbereiten =====
log "Systempakete …"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
sudo apt-get install -y git curl ca-certificates fuse3 software-properties-common jq
need_cmd rclone || sudo apt-get install -y rclone

log "Python 3.12 …"
need_cmd "$PYTHON_BIN" || { sudo add-apt-repository -y ppa:deadsnakes/ppa || true; sudo apt-get update -y; sudo apt-get install -y python3.12 python3.12-venv python3.12-dev; }

# ===== rclone Remote =====
log "rclone Remote ($GDRIVE_REMOTE) …"
mkdir -p "$HOME/.config/rclone"
RCONF="$HOME/.config/rclone/rclone.conf"

echo "==> rclone Remote prüfen ($GDRIVE_REMOTE) …"
mkdir -p "$HOME/.config/rclone"
RCONF="$HOME/.config/rclone/rclone.conf"

remote_exists() {
  [ -f "$RCONF" ] && grep -qE "^\[$GDRIVE_REMOTE\]" "$RCONF"
}

if ! remote_exists; then
  echo "==> Remote '$GDRIVE_REMOTE' fehlt – starte Headless-OAuth."
  echo "    Du bekommst gleich eine URL. Öffne sie lokal im Browser, autorisiere,"
  echo "    und kopiere den Verifizierungscode zurück ins Terminal."

  # Headless-OAuth erzwingen: rclone zeigt URL + Eingabeaufforderung
  # (mit Client-ID/Secret falls gesetzt; sonst rclone-Defaults)
  rclone config create "$GDRIVE_REMOTE" drive \
    ${RCLONE_CLIENT_ID:+client_id "$RCLONE_CLIENT_ID"} \
    ${RCLONE_CLIENT_SECRET:+client_secret "$RCLONE_CLIENT_SECRET"} \
    scope "drive" \
    config_is_local true

  # Manche rclone-Versionen legen den Remote an, verlangen aber anschließend
  # noch das eigentliche OAuth-Token: reconnect triggert erneut die URL.
  if ! remote_exists; then
    echo "==> Erzeuge/aktualisiere OAuth-Token (reconnect) …"
    rclone config reconnect "${GDRIVE_REMOTE}:" || true
  fi

  if remote_exists; then
    echo "==> Remote '$GDRIVE_REMOTE' ist eingerichtet."
  else
    echo "!! Konnte Remote nicht einrichten. Führe notfalls manuell aus:"
    echo "   rclone config"
    exit 1
  fi
else
  echo "==> Remote '$GDRIVE_REMOTE' vorhanden – weiter."
fi


# ===== GDrive mounten =====
log "Mount $GDRIVE_MOUNT …"
mkdir -p "$GDRIVE_MOUNT" "$RCLONE_LOG_DIR"
mount | grep -q "on $GDRIVE_MOUNT type fuse.rclone" && fusermount3 -u "$GDRIVE_MOUNT" || true
rclone mount "$GDRIVE_REMOTE:" "$GDRIVE_MOUNT" \
  --daemon --vfs-cache-mode full --vfs-cache-max-size 100G \
  --buffer-size 64M --transfers 4 --checkers 8 \
  --dir-cache-time 30s --poll-interval 15s \
  --log-file "$RCLONE_LOG_FILE" --log-level INFO
sleep 2
mkdir -p "$GDRIVE_MODELS_DIR" "$GDRIVE_WORKFLOWS_DIR" "$GDRIVE_INPUT_DIR" "$GDRIVE_OUTPUT_DIR"

# ===== Abfrage Restore? =====
echo
read -r -p "ComfyUI aus dem neuesten Backup wiederherstellen? [j/N]: " REPLY
REPLY="${REPLY:-N}"
echo

if [[ "$REPLY" =~ ^([jJ]|[yY])$ ]]; then
  restore_from_latest_backup || { echo "Kein Backup gefunden → frisches Setup."; fresh_setup; }
else
  fresh_setup
fi

ensure_symlinks

[ -f "$HOME/.ssh/id_ed25519" ] || ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" >/dev/null

torch_probe
start_comfy
