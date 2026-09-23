#!/usr/bin/env bash
set -Eeuo pipefail

COMFY="${COMFY:-/opt/ComfyUI}"
VENV="${COMFY_VENV:-/opt/venv}"
WORKSPACE="${WORKSPACE:-/workspace}"
USER_ROOT="${COMFY_USER_ROOT:-/opt/comfy-user}"
COMFY_PORT="${COMFY_PORT:-8188}"
ENABLE_JUPYTER="${ENABLE_JUPYTER:-1}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ printf '\n[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

[[ -x "$VENV/bin/python" ]] || die "Baked Python missing: $VENV/bin/python"
[[ -f "$COMFY/main.py" ]] || die "Baked ComfyUI missing: $COMFY/main.py"

# Persistent data only. Keep application/runtime state off /workspace because
# some RunPod storage backends reject chmod/chown/timestamp preservation.
mkdir -p \
  "$WORKSPACE/input" "$WORKSPACE/output" "$WORKSPACE/temp" "$WORKSPACE/workflows" \
  "$WORKSPACE/models/checkpoints" "$WORKSPACE/models/diffusion_models" \
  "$WORKSPACE/models/unet" "$WORKSPACE/models/vae" \
  "$WORKSPACE/models/text_encoders" "$WORKSPACE/models/clip" \
  "$WORKSPACE/models/clip_vision" "$WORKSPACE/models/loras" \
  "$WORKSPACE/models/controlnet" "$WORKSPACE/models/upscale_models" \
  "$WORKSPACE/models/embeddings"

# ComfyUI user state and ComfyUI-Manager state live on the normal container FS.
# Only the workflows directory is linked back to /workspace for persistence.
mkdir -p "$USER_ROOT/default" "$USER_ROOT/__manager"
if [[ ! -e "$USER_ROOT/default/workflows" && ! -L "$USER_ROOT/default/workflows" ]]; then
  ln -s "$WORKSPACE/workflows" "$USER_ROOT/default/workflows"
fi

log "GPU preflight"
"$VENV/bin/python" - <<'PY'
import json, torch
x={"torch":torch.__version__,"torch_cuda":torch.version.cuda,
   "cuda_available":torch.cuda.is_available()}
if torch.cuda.is_available():
    x["gpu"]=torch.cuda.get_device_name(0)
    x["capability"]=torch.cuda.get_device_capability(0)
    x["vram_gib"]=round(torch.cuda.get_device_properties(0).total_memory/1024**3,2)
print(json.dumps(x))
PY

if [[ -n "${PUBLIC_KEY:-}" ]]; then
  log "Configuring SSH key(s)"
  mkdir -p /root/.ssh
  printf '%s\n' "$PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 0700 /root/.ssh
  chmod 0600 /root/.ssh/authorized_keys
fi

ssh-keygen -A >/dev/null 2>&1 || true
/usr/sbin/sshd
log "SSH started on port 22"

if [[ "$ENABLE_JUPYTER" == "1" ]]; then
  if [[ -z "${JUPYTER_TOKEN:-}" ]]; then
    JUPYTER_TOKEN="$(openssl rand -hex 16)"
    export JUPYTER_TOKEN
    log "Generated Jupyter token: $JUPYTER_TOKEN"
  fi
  log "Starting JupyterLab on port $JUPYTER_PORT"
  "$VENV/bin/jupyter" lab --ip=0.0.0.0 --port="$JUPYTER_PORT" \
    --no-browser --allow-root \
    --ServerApp.root_dir="$WORKSPACE" \
    --ServerApp.token="$JUPYTER_TOKEN" \
    --ServerApp.password='' \
    > "$WORKSPACE/jupyter.log" 2>&1 &
fi

log "Starting ComfyUI"
log "Code=$COMFY Python=$VENV/bin/python Workspace=$WORKSPACE UserRoot=$USER_ROOT Port=$COMFY_PORT"

cd "$COMFY"

# Deliberately no runtime pip install, no venv creation, no SageAttention install,
# and no copy/move of ComfyUI into /workspace.
exec "$VENV/bin/python" main.py \
  --listen 0.0.0.0 \
  --port "$COMFY_PORT" \
  --disable-auto-launch \
  --input-directory "$WORKSPACE/input" \
  --output-directory "$WORKSPACE/output" \
  --temp-directory "$WORKSPACE/temp" \
  --user-directory "$USER_ROOT" \
  --extra-model-paths-config "$COMFY/extra_model_paths.yaml"
