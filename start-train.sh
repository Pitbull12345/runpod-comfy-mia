#!/usr/bin/env bash
set -Eeuo pipefail

AIT="${AI_TOOLKIT:-/opt/ai-toolkit}"
VENV="${AI_TOOLKIT_VENV:-/opt/ai-toolkit-venv}"
WORKSPACE="${WORKSPACE:-/workspace}"
PORT="${AI_TOOLKIT_PORT:-8675}"
ENABLE_JUPYTER="${ENABLE_JUPYTER:-1}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ printf '\n[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

[[ -x "$VENV/bin/python" ]] || die "Training Python missing: $VENV/bin/python"
[[ -f "$AIT/run.py" ]] || die "AI Toolkit missing: $AIT/run.py"

mkdir -p "$WORKSPACE/datasets" "$WORKSPACE/lora-output" "$WORKSPACE/training-configs" \
  "$WORKSPACE/model-cache/huggingface" "$WORKSPACE/model-cache/torch" "$WORKSPACE/training-logs"

log "GPU preflight"
"$VENV/bin/python" - <<'PY'
import json, torch
x={"torch":torch.__version__,"torch_cuda":torch.version.cuda,"cuda_available":torch.cuda.is_available()}
if torch.cuda.is_available():
    x["gpu"]=torch.cuda.get_device_name(0)
    x["capability"]=torch.cuda.get_device_capability(0)
    x["vram_gib"]=round(torch.cuda.get_device_properties(0).total_memory/1024**3,2)
print(json.dumps(x))
if not torch.cuda.is_available():
    raise SystemExit("CUDA is not available")
PY

[[ -f /opt/AI_TOOLKIT_BUILD_COMMIT ]] && log "AI Toolkit commit: $(cat /opt/AI_TOOLKIT_BUILD_COMMIT)"

if [[ -n "${PUBLIC_KEY:-}" ]]; then
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
  "$VENV/bin/jupyter" lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    --ServerApp.root_dir="$WORKSPACE" --ServerApp.token="$JUPYTER_TOKEN" --ServerApp.password='' \
    > "$WORKSPACE/training-logs/jupyter.log" 2>&1 &
  log "JupyterLab started on port $JUPYTER_PORT"
fi

export DATASET_ROOT="$WORKSPACE/datasets"
export LORA_OUTPUT_ROOT="$WORKSPACE/lora-output"
export TRAINING_CONFIG_ROOT="$WORKSPACE/training-configs"
[[ -n "${HF_TOKEN:-}" ]] && export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"

log "Starting AI Toolkit UI on port $PORT"
log "Datasets=$DATASET_ROOT Outputs=$LORA_OUTPUT_ROOT Configs=$TRAINING_CONFIG_ROOT"

cd "$AIT/ui"
exec npm run start
