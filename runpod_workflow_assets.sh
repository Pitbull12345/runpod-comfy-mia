#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# RunPod ComfyUI workflow asset installer
# =============================================================================
# Purpose:
#   Prepare the models / LoRAs / VAEs / text encoders / custom nodes required by
#   the bundled ComfyUI workflows. This is intentionally separate from the base
#   RunPod bootstrap script.
#
# Defaults:
#   WORKSPACE=/workspace
#   COMFY=/workspace/runpod-slim/ComfyUI
#   WORKFLOWS_DIR=<directory next to this script>/workflows
#
# Usage:
#   chmod +x runpod_workflow_assets.sh
#   ./runpod_workflow_assets.sh
#
# Useful modes:
#   ./runpod_workflow_assets.sh --verify-only
#   ./runpod_workflow_assets.sh --nodes-only
#   ./runpod_workflow_assets.sh --models-only
#   ./runpod_workflow_assets.sh --no-node-install
#   ./runpod_workflow_assets.sh --no-download
#
# Optional environment:
#   HF_TOKEN=hf_...                 # needed for gated Hugging Face models
#   WORKSPACE=/workspace
#   COMFY=/workspace/runpod-slim/ComfyUI
#   WORKFLOWS_DIR=/path/to/jsons
#   VERIFY_EXISTING=1              # hash existing public files too (slow)
#
# Safety:
#   - Existing model files are never deleted or overwritten.
#   - Existing custom-node directories are never removed.
#   - Existing files elsewhere under /workspace are reused via symlinks.
#   - Personal/ambiguous assets are reported instead of guessed.
# =============================================================================

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="${COMFY:-$WORKSPACE/runpod-slim/ComfyUI}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${WORKFLOWS_DIR:-$SCRIPT_DIR/workflows}"
STATE="${STATE:-$WORKSPACE/.workflow-assets}"
LOG_DIR="$STATE/logs"
VERIFY_EXISTING="${VERIFY_EXISTING:-0}"

VERIFY_ONLY=0
NODES_ONLY=0
MODELS_ONLY=0
NO_NODE_INSTALL=0
NO_DOWNLOAD=0

while (($#)); do
    case "$1" in
        --verify-only) VERIFY_ONLY=1 ;;
        --nodes-only) NODES_ONLY=1 ;;
        --models-only) MODELS_ONLY=1 ;;
        --no-node-install) NO_NODE_INSTALL=1 ;;
        --no-download) NO_DOWNLOAD=1 ;;
        --workflows-dir)
            shift
            [[ $# -gt 0 ]] || { echo "--workflows-dir requires a path" >&2; exit 2; }
            WORKFLOWS_DIR="$1"
            ;;
        --help|-h)
            sed -n '1,55p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ "$NODES_ONLY" == 1 && "$MODELS_ONLY" == 1 ]]; then
    echo "--nodes-only and --models-only are mutually exclusive" >&2
    exit 2
fi

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/assets-$(date -u '+%Y%m%dT%H%M%SZ').log"
exec > >(tee -a "$LOG") 2>&1

ts() { date '+%H:%M:%S'; }
info() { printf '\n[%s] INFO  %s\n' "$(ts)" "$*"; }
warn() { printf '\n[%s] WARN  %s\n' "$(ts)" "$*" >&2; }
err() { printf '\n[%s] ERROR %s\n' "$(ts)" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

run() {
    if [[ "$VERIFY_ONLY" == 1 ]]; then
        printf '[verify-only]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

[[ -d "$COMFY" ]] || { err "ComfyUI not found: $COMFY"; exit 1; }
[[ -d "$WORKFLOWS_DIR" ]] || { err "Workflow directory not found: $WORKFLOWS_DIR"; exit 1; }

info "Workflow asset installer"
echo "ComfyUI:       $COMFY"
echo "Workflows:     $WORKFLOWS_DIR"
echo "State:         $STATE"
echo "Verify only:   $VERIFY_ONLY"
echo "Log:           $LOG"

df -h "$WORKSPACE" || true
if have nvidia-smi; then
    nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader || true
fi

# -----------------------------------------------------------------------------
# Minimal tools
# -----------------------------------------------------------------------------

ensure_tools() {
    local need=()
    have git || need+=(git)
    have curl || need+=(curl)
    if [[ "$NO_DOWNLOAD" == 0 && "$VERIFY_ONLY" == 0 ]]; then
        have aria2c || need+=(aria2)
    fi
    have python3 || need+=(python3)

    if ((${#need[@]} == 0)); then
        return 0
    fi

    if [[ "$VERIFY_ONLY" == 1 ]]; then
        warn "Missing utilities: ${need[*]}"
        return 0
    fi

    if have apt-get && [[ "$(id -u)" == 0 ]]; then
        info "Installing helper utilities: ${need[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${need[@]}"
    else
        warn "Missing utilities (${need[*]}) and cannot install them automatically"
    fi
}
ensure_tools

have python3 || { err "python3 is required"; exit 1; }

mkdir -p "$STATE"
REQ_MODELS="$STATE/required-models.tsv"
REQ_NODES="$STATE/required-nodes.txt"
REQ_AUX="$STATE/required-node-repos.txt"
WORKFLOW_SUMMARY="$STATE/workflow-summary.tsv"
UNRESOLVED="$STATE/unresolved-assets.txt"
FAILED="$STATE/failed-assets.txt"
INSTALLED="$STATE/installed-assets.txt"
: > "$UNRESOLVED"
: > "$FAILED"
: > "$INSTALLED"

# -----------------------------------------------------------------------------
# Parse workflows. Preserve nested LoRA relative paths because ComfyUI workflows
# can reference loras/subdir/file.safetensors rather than just a basename.
# -----------------------------------------------------------------------------

info "Scanning workflow JSON files"
python3 - "$WORKFLOWS_DIR" "$REQ_MODELS" "$REQ_NODES" "$REQ_AUX" "$WORKFLOW_SUMMARY" <<'PY'
import json, os, sys
from pathlib import Path

root = Path(sys.argv[1])
out_models = Path(sys.argv[2])
out_nodes = Path(sys.argv[3])
out_aux = Path(sys.argv[4])
out_summary = Path(sys.argv[5])

model_exts = ('.safetensors','.gguf','.ckpt','.pt','.pth','.onnx','.bin','.engine')
loader_dest = {
    'UNETLoader':'diffusion_models',
    'DiffusionModelLoaderKJ':'diffusion_models',
    'UnetLoaderGGUF':'diffusion_models',
    'CLIPLoader':'text_encoders',
    'VAELoader':'vae',
    'CLIPVisionLoader':'clip_vision',
    'CheckpointLoaderSimple':'checkpoints',
    'UpscaleModelLoader':'upscale_models',
    'LoraLoaderModelOnly':'loras',
    'Krea2ControlLoRALoader':'loras',
    'Lora Loader Stack (rgthree)':'loras',
    'Power Lora Loader (rgthree)':'loras',
    'PixaromaLoraLoader':'loras',
}

models = {}
nodes = set()
aux = set()
summary = []

for path in sorted(root.glob('*.json')):
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except Exception as e:
        summary.append((path.name, 'ERROR', str(e)))
        continue

    ns = data.get('nodes', [])
    summary.append((path.name, str(len(ns)), data.get('id','')))
    for n in ns:
        typ = str(n.get('type',''))
        prop = n.get('properties') or {}
        cnr = prop.get('cnr_id')
        aux_id = prop.get('aux_id')
        if cnr and cnr != 'comfy-core':
            nodes.add(str(cnr))
        if aux_id:
            aux.add(str(aux_id))

        # Model metadata embedded by ComfyUI.
        for m in prop.get('models') or []:
            if not isinstance(m, dict):
                continue
            name = m.get('name')
            if not isinstance(name, str) or not name.lower().endswith(model_exts):
                continue
            dest = str(m.get('directory') or loader_dest.get(typ,'')).strip('/')
            if not dest:
                continue
            rel = name.replace('\\','/').lstrip('/')
            if '..' in Path(rel).parts:
                continue
            key = (dest, rel)
            rec = models.setdefault(key, {'urls':set(),'wfs':set()})
            if m.get('url'):
                rec['urls'].add(str(m['url']))
            rec['wfs'].add(path.name)

        # Exact model-looking widget values on known model loader nodes.
        dest = loader_dest.get(typ)
        values = []
        def walk(x):
            if isinstance(x, str): values.append(x)
            elif isinstance(x, list):
                for v in x: walk(v)
            elif isinstance(x, dict):
                for v in x.values(): walk(v)
        walk(n.get('widgets_values'))

        if dest:
            for s in values:
                if '\n' in s or len(s) > 400 or not s.lower().endswith(model_exts):
                    continue
                rel = s.replace('\\','/').lstrip('/')
                if '..' in Path(rel).parts:
                    continue
                key=(dest,rel)
                models.setdefault(key, {'urls':set(),'wfs':set()})['wfs'].add(path.name)

        # WanAnimatePreprocess detection models live outside standard model dirs.
        if typ == 'OnnxDetectionModelLoader':
            for s in values:
                if s.lower().endswith(('.onnx','.pt','.pth')):
                    key=('__wananimate_detection__', os.path.basename(s))
                    models.setdefault(key, {'urls':set(),'wfs':set()})['wfs'].add(path.name)

        # ControlNet Aux downloads these to its own ckpt tree.
        if typ == 'DWPreprocessor':
            for s in values:
                if s in {'yolox_l.onnx','dw-ll_ucoco_384_bs5.torchscript.pt'}:
                    key=('__controlnet_aux__', s)
                    models.setdefault(key, {'urls':set(),'wfs':set()})['wfs'].add(path.name)

# Known local/custom helper nodes created for this workspace. The base bootstrap
# capture is expected to restore these; list them so verification is explicit.
local_helpers = {'PoseArmSuppressor','GrokPoseToPrompt','ICYLMStudioMultimodalPrompt','BetterImageLoader'}
for h in local_helpers:
    nodes.add('LOCAL:' + h)

with out_models.open('w', encoding='utf-8') as f:
    f.write('dest|relpath|basename|embedded_url|workflows\n')
    for (dest, rel), rec in sorted(models.items()):
        url = sorted(rec['urls'])[0] if rec['urls'] else ''
        f.write(f"{dest}|{rel}|{os.path.basename(rel)}|{url}|{';'.join(sorted(rec['wfs']))}\n")
with out_nodes.open('w', encoding='utf-8') as f:
    for x in sorted(nodes): f.write(x+'\n')
with out_aux.open('w', encoding='utf-8') as f:
    for x in sorted(aux): f.write(x+'\n')
with out_summary.open('w', encoding='utf-8') as f:
    f.write('workflow\tnodes\tid\n')
    for row in summary: f.write('\t'.join(row)+'\n')
PY

echo "Workflows scanned: $(($(wc -l < "$WORKFLOW_SUMMARY") - 1))"
echo "Model references:  $(($(wc -l < "$REQ_MODELS") - 1))"
echo "Node packages:      $(wc -l < "$REQ_NODES")"

# Keep a copy of the supplied workflows inside ComfyUI without overwriting any
# workflow the user may already have edited there.
WORKFLOW_INSTALL_DIR="$COMFY/user/default/workflows/AI-Instagram-Girls"
if [[ "$VERIFY_ONLY" == 0 ]]; then
    mkdir -p "$WORKFLOW_INSTALL_DIR"
    find "$WORKFLOWS_DIR" -maxdepth 1 -type f -name '*.json' -print0 | while IFS= read -r -d '' wf; do
        dst="$WORKFLOW_INSTALL_DIR/$(basename "$wf")"
        [[ -e "$dst" ]] || cp -a "$wf" "$dst"
    done
fi

# -----------------------------------------------------------------------------
# Custom nodes
# -----------------------------------------------------------------------------

choose_comfy_python() {
    local p
    for p in \
        "$COMFY/.venv-cu128/bin/python" \
        "$COMFY/.venv/bin/python" \
        "$WORKSPACE/runpod-slim/.venv/bin/python"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    command -v python3
}
COMFY_PY="$(choose_comfy_python)"
MANAGER="$COMFY/custom_nodes/ComfyUI-Manager"

# Repository fallbacks for packages where the workflow gives a known aux_id or
# the project has a clear canonical repository. Manager is attempted first.
declare -A NODE_REPO NODE_MANAGER_NAME
NODE_REPO["ComfyUI_Comfyroll_CustomNodes"]="https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git"
NODE_REPO["ComfyUI-Pixaroma"]="https://github.com/pixaroma/ComfyUI-Pixaroma.git"
NODE_REPO["ComfyUI-QwenVL"]="https://github.com/startloy/ComfyUI-QwenVL.git"
NODE_REPO["ComfyUI-WanAnimatePreprocess"]="https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git"
NODE_REPO["LanPaint"]="https://github.com/scraed/LanPaint.git"
NODE_REPO["RES4LYF"]="https://github.com/ClownsharkBatwing/RES4LYF.git"
NODE_REPO["cg-use-everywhere"]="https://github.com/chrisgoringe/cg-use-everywhere.git"
NODE_REPO["comfyui-custom-scripts"]="https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
NODE_REPO["comfyui-easy-use"]="https://github.com/yolain/ComfyUI-Easy-Use.git"
NODE_REPO["comfyui-gguf"]="https://github.com/city96/ComfyUI-GGUF.git"
NODE_REPO["comfyui-impact-pack"]="https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
NODE_REPO["comfyui-inspire-pack"]="https://github.com/ltdrdata/ComfyUI-Inspire-Pack.git"
NODE_REPO["comfyui-kjnodes"]="https://github.com/kijai/ComfyUI-KJNodes.git"
NODE_REPO["comfyui-krea2-conditioning"]="https://github.com/nova452/Rebalance-Pack.git"
NODE_REPO["comfyui-krea2-ostris-edit"]="https://github.com/ostris/ComfyUI-Krea2-Ostris-Edit.git"
NODE_REPO["comfyui-logic"]="https://github.com/theUpsider/ComfyUI-Logic.git"
NODE_REPO["comfyui-rmbg"]="https://github.com/1038lab/ComfyUI-RMBG.git"
NODE_REPO["comfyui-videohelpersuite"]="https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
NODE_REPO["comfyui_controlnet_aux"]="https://github.com/Fannovel16/comfyui_controlnet_aux.git"
NODE_REPO["comfyui_essentials"]="https://github.com/cubiq/ComfyUI_essentials.git"
NODE_REPO["comfyui_nvidia_rtx_nodes"]="https://github.com/Comfy-Org/Nvidia_RTX_Nodes_ComfyUI.git"
NODE_REPO["controlaltai-nodes"]="https://github.com/gseth/ControlAltAI-Nodes.git"
NODE_REPO["efficiency-nodes-comfyui"]="https://github.com/jags111/efficiency-nodes-comfyui.git"
NODE_REPO["rgthree-comfy"]="https://github.com/rgthree/rgthree-comfy.git"
NODE_REPO["scale-image-to-total-pixels-advanced"]="https://github.com/BigStationW/ComfyUi-Scale-Image-to-Total-Pixels-Advanced.git"
NODE_REPO["textencodeeditadvanced"]="https://github.com/BigStationW/ComfyUi-TextEncodeEditAdvanced.git"
NODE_REPO["comfyui-krea2-controlnet"]="https://github.com/facok/comfyui-krea2-controlnet.git"

NODE_MANAGER_NAME["comfyui-krea2-conditioning"]="Rebalance-Pack"
NODE_MANAGER_NAME["comfyui-krea2-ostris-edit"]="ComfyUI-Krea2-Ostris-Edit"
NODE_MANAGER_NAME["comfyui-kjnodes"]="ComfyUI-KJNodes"
NODE_MANAGER_NAME["comfyui-impact-pack"]="ComfyUI-Impact-Pack"
NODE_MANAGER_NAME["comfyui-inspire-pack"]="ComfyUI-Inspire-Pack"
NODE_MANAGER_NAME["comfyui-videohelpersuite"]="ComfyUI-VideoHelperSuite"
NODE_MANAGER_NAME["comfyui_controlnet_aux"]="comfyui_controlnet_aux"
NODE_MANAGER_NAME["comfyui_essentials"]="ComfyUI_essentials"
NODE_MANAGER_NAME["comfyui-custom-scripts"]="ComfyUI-Custom-Scripts"
NODE_MANAGER_NAME["comfyui-easy-use"]="ComfyUI-Easy-Use"
NODE_MANAGER_NAME["comfyui-gguf"]="ComfyUI-GGUF"
NODE_MANAGER_NAME["comfyui-rmbg"]="ComfyUI-RMBG"
NODE_MANAGER_NAME["controlaltai-nodes"]="ControlAltAI-Nodes"
NODE_MANAGER_NAME["rgthree-comfy"]="rgthree-comfy"
NODE_MANAGER_NAME["ComfyUI_Comfyroll_CustomNodes"]="ComfyUI_Comfyroll_CustomNodes"
NODE_MANAGER_NAME["ComfyUI-Pixaroma"]="ComfyUI-Pixaroma"
NODE_MANAGER_NAME["ComfyUI-QwenVL"]="ComfyUI-QwenVL"
NODE_MANAGER_NAME["ComfyUI-WanAnimatePreprocess"]="ComfyUI-WanAnimatePreprocess"
NODE_MANAGER_NAME["LanPaint"]="LanPaint"
NODE_MANAGER_NAME["RES4LYF"]="RES4LYF"
NODE_MANAGER_NAME["cg-use-everywhere"]="cg-use-everywhere"
NODE_MANAGER_NAME["comfyui-logic"]="ComfyUI-Logic"
NODE_MANAGER_NAME["comfyui_nvidia_rtx_nodes"]="Nvidia_RTX_Nodes_ComfyUI"
NODE_MANAGER_NAME["efficiency-nodes-comfyui"]="efficiency-nodes-comfyui"
NODE_MANAGER_NAME["scale-image-to-total-pixels-advanced"]="ComfyUi-Scale-Image-to-Total-Pixels-Advanced"
NODE_MANAGER_NAME["textencodeeditadvanced"]="ComfyUi-TextEncodeEditAdvanced"

ensure_manager() {
    [[ "$NO_NODE_INSTALL" == 0 ]] || return 0
    [[ "$VERIFY_ONLY" == 0 ]] || return 0
    if [[ ! -f "$MANAGER/cm-cli.py" ]]; then
        info "Installing ComfyUI-Manager"
        mkdir -p "$COMFY/custom_nodes"
        git clone https://github.com/Comfy-Org/ComfyUI-Manager.git "$MANAGER"
        if [[ -f "$MANAGER/requirements.txt" ]]; then
            "$COMFY_PY" -m pip install -r "$MANAGER/requirements.txt"
        fi
    fi
}

repo_dirname() {
    local url="$1"
    local n="${url##*/}"
    n="${n%.git}"
    echo "$n"
}

install_node() {
    local node="$1"
    [[ "$node" == LOCAL:* ]] && return 0
    [[ "$NO_NODE_INSTALL" == 0 ]] || return 0

    local manager_name="${NODE_MANAGER_NAME[$node]:-$node}"
    local repo="${NODE_REPO[$node]:-}"

    if [[ "$VERIFY_ONLY" == 1 ]]; then
        echo "CHECK NODE: $node"
        return 0
    fi

    local ok=0
    if [[ -f "$MANAGER/cm-cli.py" ]]; then
        info "Custom node: $node"
        if COMFYUI_PATH="$COMFY" "$COMFY_PY" "$MANAGER/cm-cli.py" install "$manager_name" --mode remote; then
            ok=1
        fi
    fi

    if [[ "$ok" == 0 && -n "$repo" ]]; then
        local dst="$COMFY/custom_nodes/$(repo_dirname "$repo")"
        if [[ -d "$dst" ]]; then
            info "Node repository already exists: $dst"
            ok=1
        else
            warn "Manager install did not resolve $node; trying canonical Git repository"
            if git clone "$repo" "$dst"; then
                ok=1
            fi
        fi
    fi

    if [[ "$ok" == 1 ]]; then
        echo "NODE $node" >> "$INSTALLED"
    else
        echo "NODE $node" >> "$FAILED"
    fi
}

verify_local_helpers() {
    local helper="$1"
    # Search source text for the class/node name. This is only a verification
    # aid; these local nodes should normally be restored by runpod_bootstrap.sh.
    if grep -Rqs --exclude-dir=.git --exclude='*.json' "$helper" "$COMFY/custom_nodes" 2>/dev/null; then
        echo "LOCAL NODE $helper: FOUND"
    else
        warn "Local helper node not found: $helper (restore it from the environment capture)"
        echo "LOCAL NODE $helper" >> "$UNRESOLVED"
    fi
}

if [[ "$MODELS_ONLY" == 0 ]]; then
    ensure_manager
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        if [[ "$node" == LOCAL:* ]]; then
            verify_local_helpers "${node#LOCAL:}"
        else
            install_node "$node"
        fi
    done < "$REQ_NODES"

    # Install repos explicitly referenced through aux_id but missing from CNR IDs.
    while IFS= read -r aux; do
        [[ -n "$aux" ]] || continue
        node_key="${aux##*/}"
        if ! grep -qiF "$node_key" "$REQ_NODES"; then
            repo="https://github.com/${aux}.git"
            dst="$COMFY/custom_nodes/$node_key"
            if [[ -d "$dst" ]]; then
                continue
            fi
            if [[ "$VERIFY_ONLY" == 1 ]]; then
                echo "CHECK NODE REPO: $aux"
            elif [[ "$NO_NODE_INSTALL" == 0 ]]; then
                info "Installing workflow aux repository: $aux"
                git clone "$repo" "$dst" || echo "NODE-REPO $aux" >> "$FAILED"
            fi
        fi
    done < "$REQ_AUX"

    if [[ "$VERIFY_ONLY" == 0 && "$NO_NODE_INSTALL" == 0 && -f "$MANAGER/cm-cli.py" ]]; then
        info "Restoring custom-node dependencies"
        COMFYUI_PATH="$COMFY" "$COMFY_PY" "$MANAGER/cm-cli.py" restore-dependencies || \
            warn "Manager dependency restoration reported errors; see log"
    fi
fi

# -----------------------------------------------------------------------------
# Public model manifest.
# Format: basename|destination|URL|SHA256|flags
# Empty SHA means download is still supported, but no post-download hash check.
# 'gated' means HF_TOKEN should be supplied if Hugging Face requires acceptance.
# -----------------------------------------------------------------------------

MANIFEST="$STATE/public-model-manifest.tsv"
cat > "$MANIFEST" <<'MANIFEST_EOF'
krast_v20.safetensors|diffusion_models|https://huggingface.co/cusiman/Krea2_Collection/resolve/main/krast_v20.safetensors||
qwen3vl_4b_fp8_scaled.safetensors|text_encoders|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors|54bd5144df0bbc25dd6ccadfcb826b521445a1b06ae5a42570bdd2974ca87094|
qwen_image_vae.safetensors|vae|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors|a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f|
krea2_turbo_fp8_scaled.safetensors|diffusion_models|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_fp8_scaled.safetensors|eb4dd8c612cfd10f64f25b057e6e6bbcb5737c94a7372177e456dbf7579502f1|
krea2_turbo_int8_convrot.safetensors|diffusion_models|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_int8_convrot.safetensors|8e4eeda70dd5037ab1ba2bef6b417f9f901e26093117cf397f741fc1fdaaf3f1|
krea2_turbo_bf16.safetensors|diffusion_models|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_bf16.safetensors|78bbf8f4165eda19cea3cb06c78089221932a39e2eed8af9da741f942c47ffb3|
krea2_turbo_lora_rank_64_bf16.safetensors|loras|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/loras/krea2_turbo_lora_rank_64_bf16.safetensors|db8c5bae0a415d448da9d842111d6e51f7d32e47143a3118eb267e5c4773de87|
krea2_turbo_openpose_controlnet.safetensors|loras|https://huggingface.co/thedeoxen/Krea-2-pose-controlnet/resolve/main/krea2_turbo_openpose_controlnet.safetensors|0ddc3aafce4abdf7af3309b2f00c1bacdf15df1f2b4fb7adc9ff71795da90ecf|
depth-control-lora.safetensors|loras|https://huggingface.co/Patil/Krea-2-depth-controlnet/resolve/main/depth-control-lora.safetensors|fb80547ed79b47c1e3fea7bb9d36297e3917b2115fab6700ca1501350f9f483c|
4xNomosWebPhoto_RealPLKSR.safetensors|upscale_models|https://huggingface.co/Phips/4xNomosWebPhoto_RealPLKSR/resolve/main/4xNomosWebPhoto_RealPLKSR.safetensors|9be0228f98156a100d6636d99b373ed2785b999723f9adc4cca504329ab157f2|
Krea2_Raw_convrot_int8mixed.safetensors|diffusion_models|https://huggingface.co/Kutches/Kr3a/resolve/main/Krea2_Raw_convrot_int8mixed.safetensors|18620f3389a95e1688870a56ece490988386015ac43a8b10f9a61a9ec0350324|
krea2RealVae_v10.safetensors|vae|https://huggingface.co/artsyww/KREA2REALVAE/resolve/main/krea2RealVae_v10.safetensors|0dbbe0baeca04c2b98d2f3809c6f595608939809c88b695ba971368f17c874b8|
krea2filterbypass3.safetensors|loras|https://huggingface.co/fwwrsd/krea2-loras/resolve/main/krea2filterbypass3.safetensors|ec5901a2d0b8f4e4e1e7e62fe4567566f0837799f7a413b03a06f72f47934dda|
KNPV3_1.safetensors|loras|https://huggingface.co/Kutches/Kr3a/resolve/main/KNPV3_1.safetensors|fee8d39466016f42c1b72a6cfa4b6716b26c33a4caf97b75b86c727d487cec7e|
realism_engine_krea2_v3.1.safetensors|loras|https://huggingface.co/RazzzHF/realism_engine_krea2/resolve/main/realism_engine_krea2_v3.1.safetensors|a6712629445a2e91a616568e82befa8c8c7518e891a0f7c9918138634b5b54a5|
head_size_krea2_loraholic.safetensors|loras|https://huggingface.co/Kutches/Kr3a/resolve/main/head_size_krea2_loraholic.safetensors||
snofs_krea_v1_4.safetensors|loras|https://huggingface.co/gravedigga/loras/resolve/main/snofs_krea_v1_4.safetensors|767888edde83003f14cf930f13f174fe2a7431e252a515ddf04bd93d382a8932|
krea2-bloomgirls-realism-step00004000.safetensors|loras|https://huggingface.co/gravedigga/loras/resolve/main/krea2-bloomgirls-realism-step00004000.safetensors||
slop_twerk_LowNoise_merged3_7_v2.safetensors|loras|https://huggingface.co/gravedigga/loras/resolve/main/slop_twerk_LowNoise_merged3_7_v2.safetensors|d70d23144d43ee6d7ffbd3d2d5cade1f0f9004a3e013a7c33dd2f91f37e438ea|
wan2.1_14B_SCAIL_2_fp8_scaled.safetensors|diffusion_models|https://huggingface.co/fwwrsd/scail-2/resolve/main/diffusion_models/wan2.1_14B_SCAIL_2_fp8_scaled.safetensors|11513b4697ecf566de0cb74660c478f301fb6699a62b10369e91a6ed0fd6b083|
clip_vision_h.safetensors|clip_vision|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors|64a7ef761bfccbadbaa3da77366aac4185a6c58fa5de5f589b42a65bcc21f161|
umt5_xxl_fp8_e4m3fn_scaled.safetensors|text_encoders|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors||
wan_2.1_vae.safetensors|vae|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors|2fc39d31359a4b0a64f55876d8ff7fa8d780956ae2cb13463b0223e15148976b|
Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64_fixed.safetensors|loras|https://huggingface.co/fwwrsd/scail-2/resolve/main/Wan21_I2V_14B_lightx2v_cfg_step_distill_lora_rank64_fixed.safetensors|8833bd4fd7c8eabebf0bc8ee5cfaf47f4f310ce116928a02c1adf8941dd4b0f1|
wan2.1_SCAIL_2_DPO_lora_bf16(1).safetensors|loras|https://huggingface.co/Comfy-Org/SCAIL-2/resolve/main/loras/wan2.1_SCAIL_2_DPO_lora_bf16.safetensors|b106522036f64e50f5f8ae3b808973515ff442cc2fac27b65d875eafb95b89e2|
wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors|loras|https://huggingface.co/lightx2v/Wan2.2-LightX2V/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors|8833bd4fd7c8eabebf0bc8ee5cfaf47f4f310ce116928a02c1adf8941dd4b0f1|
sam3.1_multiplex_fp16.safetensors|checkpoints|https://huggingface.co/Comfy-Org/sam3.1/resolve/main/checkpoints/sam3.1_multiplex_fp16.safetensors|9ba99c92703c2e8b4f47de2d34a539bb8e18923049e238b780d70dbe6368eb03|
flux-2-klein-9b.safetensors|diffusion_models|https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/resolve/main/flux-2-klein-9b.safetensors||gated
flux-2-klein-9b-fp8.safetensors|diffusion_models|https://huggingface.co/black-forest-labs/FLUX.2-klein-9B-fp8/resolve/main/flux-2-klein-9b-fp8.safetensors|865ba09f5b4c3cbd3468a4bd3acb9fcb2f8740c54317482f0bcd4ed1d3655cee|gated
qwen_3_8b_fp8mixed.safetensors|text_encoders|https://huggingface.co/Comfy-Org/flux2-klein-9B/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors||
flux2-vae.safetensors|vae|https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors|d64f3a68e1cc4f9f4e29b6e0da38a0204fe9a49f2d4053f0ec1fa1ca02f9c4b5|
flux-2-klein-9b-Q5_K_M.gguf|diffusion_models|https://huggingface.co/unsloth/FLUX.2-klein-9B-GGUF/resolve/main/flux-2-klein-9b-Q5_K_M.gguf|ad0ace013fb401560ba4a7ff2b2bb3235795f07c19dffebf411806b424700503|
lenovo_flux_klein9b.safetensors|loras|https://huggingface.co/Danrisi/Lenovo_FluxKlein9b_base/resolve/main/lenovo_flux_klein9b.safetensors||
klein_snofs_v1_1.safetensors|loras|https://huggingface.co/jerrydev11/Qwen_snof/resolve/main/klein_snofs_v1_1.safetensors|5a9f4b70721c922ce468f77723aa2fcd4c2d8f889e3bab5e71fd46737d1f30ca|
Qwen-Rapid-AIO-NSFW-v23.safetensors|checkpoints|https://huggingface.co/Phr00t/Qwen-Image-Edit-Rapid-AIO/resolve/main/v23/Qwen-Rapid-AIO-NSFW-v23.safetensors|fdb919fc81bea63f13759967fc92c9118142e5c70d4e6795199233a35eefa233|
Head_9B.safetensors|loras|https://huggingface.co/Kutches/Kl4b/resolve/main/Head_9B.safetensors|0f246ab23021c71a44d1c0d693d641ab16100105eeb9321485f25044f04c0cf6|
bfs_head_v1_flux-klein_9b_step3500_rank128.safetensors|loras|https://huggingface.co/botp/BFS-Best-Face-Swap/resolve/main/bfs_head_v1_flux-klein_9b_step3500_rank128.safetensors|70d8aaf332d710b905d5085afaa87c3ef577edffd54ffcfadeb8c47a854f9044|
f2k_9B_lcs_consist_preview_20260328.safetensors|loras|https://huggingface.co/lrzjason/Consistance_Edit_Lora/resolve/main/f2k_9B_lcs_consist_preview_20260328.safetensors||
Samsung_fluxklein9b.safetensors|loras|https://huggingface.co/Danrisi/Samsung_FluxKlein_9b/resolve/main/Samsung_fluxklein9b.safetensors|1b18aa689abee31f2a0037741a30f87c39d892b802e408e9f8d66bb0bd2b216d|
breast_slider_klein9b_v11_20260213_091528.safetensors|loras|https://huggingface.co/Winnougan/Must_Have_Klein_9b_loras/resolve/main/breast_slider_klein9b_v11_20260213_091528.safetensors|58e80bf5acc1da786a5a51976497adcdfb3d6eeee69074519ae05e1a424a4011|
detail_slider_klein_9b_20260123_065513.safetensors|loras|https://huggingface.co/andrewwe/klein9bl/resolve/main/detail_slider_klein_9b_20260123_065513.safetensors|0cf7947ae3eda1996c00b660bf65216d070e07595e9dc03919c2a45667ac2540|
ass_slider_klein9b_v12_20260216_080807.safetensors|loras|https://huggingface.co/Winnougan/Must_Have_Klein_9b_loras/resolve/main/ass_slider_klein9b_v12_20260216_080807.safetensors|330d62e98d9c9bc06dac1bea411c5b178346764ebf034c3e0f88d73a791ecb6a|
pawg_klein.safetensors|loras|https://huggingface.co/msrcam/Flux.2_Klein_9B_LoRas/resolve/main/pawg_klein.safetensors|973d611fa277920fe64ada89ec820958f0ceb9c6c335063371672c8899629804|
realistic.safetensors|loras|https://huggingface.co/dx8152/Flux2-Klein-9B-Enhanced-Details/resolve/main/realistic.safetensors|9788dcbeffb79a7823427aaadd47ea122077e3cd9f142de012b58649d50b897e|
Flux.2 Klein 9B - Sling Bikini.safetensors|loras|https://huggingface.co/Sentinel7/flux2/resolve/main/2453203/2758425/Flux.2%20Klein%209B%20-%20Sling%20Bikini.safetensors|f3980506bece0b6fdc732b4806c5eb63b29bc7b3aaa6269e295ca971252f7a3b|
Huihui-Qwen3-VL-4B-Instruct-abliterated.safetensors|text_encoders|https://huggingface.co/ahmed22xa/Huihui-Qwen3-VL-4B-Instruct-abliterated-comfy/resolve/main/Huihui-Qwen3-VL-4B-Instruct-abliterated.safetensors|03590b45adf6a071dd5de231d4e2b697355746e36ce2d9368b4c0587ba014cd2|
Huihui-Qwen3-VL-4B-Instruct-abliterated-fp8_scaled.safetensors|text_encoders|https://huggingface.co/ahmed22xa/Huihui-Qwen3-VL-4B-Instruct-abliterated-comfy/resolve/main/Huihui-Qwen3-VL-4B-Instruct-abliterated-fp8_scaled.safetensors|45fe15d359fbc6fe8773f24cebc34acedf5696d96d41a0c9a3039611ece3b866|
MANIFEST_EOF

# Auxiliary detector assets that are explicitly named by the workflows.
# Format: basename|absolute target path|URL|SHA256
AUX_MANIFEST="$STATE/aux-model-manifest.tsv"
cat > "$AUX_MANIFEST" <<AUX_EOF
vitpose-l-wholebody.onnx|$COMFY/models/detection/vitpose-l-wholebody.onnx|https://huggingface.co/JunkyByte/easy_ViTPose/resolve/main/onnx/wholebody/vitpose-l-wholebody.onnx|89bdf6692d9224dbd5004dcef23a9ba2d54c5776212b359d5a5b5068ac14fd08
yolov10m.onnx|$COMFY/models/detection/yolov10m.onnx|https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx|89b526498a6d55f869a6ab52e3a2eb20ad45b3711c1f7de3dd9ca0b399dfd6d7
yolox_l.onnx|$COMFY/custom_nodes/comfyui_controlnet_aux/ckpts/yzd-v/DWPose/yolox_l.onnx|https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx|
dw-ll_ucoco_384_bs5.torchscript.pt|$COMFY/custom_nodes/comfyui_controlnet_aux/ckpts/hr16/DWPose-TorchScript-BatchSize5/dw-ll_ucoco_384_bs5.torchscript.pt|https://huggingface.co/hr16/DWPose-TorchScript-BatchSize5/resolve/main/dw-ll_ucoco_384_bs5.torchscript.pt|
AUX_EOF

# -----------------------------------------------------------------------------
# Download / reuse helpers
# -----------------------------------------------------------------------------

model_root_for_dest() {
    local dest="$1"
    printf '%s/models/%s' "$COMFY" "$dest"
}

FILE_INDEX="$STATE/workspace-model-file-index.tsv"
build_file_index() {
    info "Indexing existing model-like files under $WORKSPACE (one pass)"
    find "$WORKSPACE" -maxdepth 9 \
        \( -type f -o -type l \) \
        \( -iname '*.safetensors' -o -iname '*.gguf' -o -iname '*.ckpt' \
           -o -iname '*.pt' -o -iname '*.pth' -o -iname '*.onnx' -o -iname '*.engine' \) \
        -printf '%f|%p\n' 2>/dev/null > "$FILE_INDEX" || true
}
build_file_index

find_existing_by_basename() {
    local base="$1"
    awk -F'|' -v b="$base" '$1==b {sub(/^[^|]*\|/, ""); print; exit}' "$FILE_INDEX"
}

sha_ok() {
    local file="$1" expected="$2"
    [[ -n "$expected" ]] || return 0
    [[ -f "$file" ]] || return 1
    local got
    got="$(sha256sum "$file" | awk '{print $1}')"
    [[ "${got,,}" == "${expected,,}" ]]
}

download_url() {
    local url="$1" out="$2"
    mkdir -p "$(dirname "$out")"
    local headers=()
    if [[ "$url" == https://huggingface.co/* && -n "${HF_TOKEN:-}" ]]; then
        headers+=("Authorization: Bearer ${HF_TOKEN}")
    fi

    if have aria2c; then
        local args=(-c -x 8 -s 8 -k 1M --file-allocation=none --auto-file-renaming=false --allow-overwrite=false)
        local h
        for h in "${headers[@]}"; do args+=(--header="$h"); done
        aria2c "${args[@]}" -d "$(dirname "$out")" -o "$(basename "$out")" "$url"
    else
        local args=(-L --fail --retry 5 --retry-delay 3 --continue-at -)
        local h
        for h in "${headers[@]}"; do args+=(-H "$h"); done
        curl "${args[@]}" -o "$out" "$url"
    fi
}

manifest_lookup() {
    local base="$1"
    awk -F'|' -v b="$base" '$1==b {print; exit}' "$MANIFEST"
}

aux_lookup() {
    local base="$1"
    awk -F'|' -v b="$base" '$1==b {print; exit}' "$AUX_MANIFEST"
}

ensure_target_from_source() {
    local source="$1" target="$2"
    [[ -e "$target" || -L "$target" ]] && return 0
    mkdir -p "$(dirname "$target")"
    ln -s "$source" "$target"
}

install_standard_asset() {
    local dest="$1" rel="$2" base="$3" embedded_url="$4" workflows="$5"
    local target="$(model_root_for_dest "$dest")/$rel"

    # Older workflow filenames that are explicitly mapped to the modern public
    # filename later in the script. Do not report them unresolved here.
    if [[ "$base" == "wan21-vae.safetensors" || "$base" == "krea2TurboFP8_krea2TURBO.safetensors" ]]; then
        return 0
    fi

    if [[ -e "$target" || -L "$target" ]]; then
        echo "OK      $dest/$rel"
        if [[ "$VERIFY_EXISTING" == 1 ]]; then
            local line sha
            line="$(manifest_lookup "$base" || true)"
            sha="$(echo "$line" | awk -F'|' '{print $4}')"
            if [[ -n "$sha" && -f "$target" ]] && ! sha_ok "$target" "$sha"; then
                warn "Existing file hash differs from curated manifest: $target (left untouched)"
            fi
        fi
        return 0
    fi

    local existing
    existing="$(find_existing_by_basename "$base" || true)"
    if [[ -n "$existing" && "$existing" != "$target" ]]; then
        info "Reusing existing asset: $base"
        echo "  $existing"
        echo "  -> $target"
        if [[ "$VERIFY_ONLY" == 0 ]]; then
            ensure_target_from_source "$existing" "$target"
        fi
        echo "LINK $dest/$rel <- $existing" >> "$INSTALLED"
        return 0
    fi

    local line mbase mdest url sha flags
    line="$(manifest_lookup "$base" || true)"
    if [[ -n "$line" ]]; then
        IFS='|' read -r mbase mdest url sha flags <<< "$line"
    else
        url="$embedded_url"
        sha=""
        flags=""
    fi

    if [[ -z "$url" ]]; then
        warn "No trusted public download mapping: $dest/$rel"
        echo "MODEL $dest/$rel | workflows=$workflows" >> "$UNRESOLVED"
        return 0
    fi

    if [[ "$flags" == *gated* && -z "${HF_TOKEN:-}" ]]; then
        warn "$base may require Hugging Face access. Set HF_TOKEN after accepting the model license."
        echo "GATED $dest/$rel | $url" >> "$UNRESOLVED"
        return 0
    fi

    if [[ "$VERIFY_ONLY" == 1 || "$NO_DOWNLOAD" == 1 ]]; then
        echo "MISSING $dest/$rel"
        echo "        $url"
        return 0
    fi

    info "Downloading $dest/$rel"
    mkdir -p "$(dirname "$target")"
    local tmp="${target}.partial"
    rm -f "$tmp"
    if download_url "$url" "$tmp"; then
        if [[ -n "$sha" ]] && ! sha_ok "$tmp" "$sha"; then
            err "SHA256 mismatch: $base"
            rm -f "$tmp"
            echo "HASH $dest/$rel | $url" >> "$FAILED"
            return 0
        fi
        mv "$tmp" "$target"
        echo "DOWNLOAD $dest/$rel" >> "$INSTALLED"
    else
        rm -f "$tmp"
        warn "Download failed: $base"
        echo "DOWNLOAD $dest/$rel | $url" >> "$FAILED"
    fi
}

install_aux_asset() {
    local base="$1"
    local line target url sha
    line="$(aux_lookup "$base" || true)"
    [[ -n "$line" ]] || { echo "AUX $base" >> "$UNRESOLVED"; return 0; }
    IFS='|' read -r _ target url sha <<< "$line"

    if [[ -e "$target" || -L "$target" ]]; then
        echo "OK      auxiliary/$base"
        return 0
    fi

    local existing
    existing="$(find_existing_by_basename "$base" || true)"
    if [[ -n "$existing" ]]; then
        info "Reusing auxiliary model: $base"
        if [[ "$VERIFY_ONLY" == 0 ]]; then
            ensure_target_from_source "$existing" "$target"
        fi
        return 0
    fi

    if [[ "$VERIFY_ONLY" == 1 || "$NO_DOWNLOAD" == 1 ]]; then
        echo "MISSING auxiliary/$base -> $target"
        return 0
    fi

    info "Downloading auxiliary detector: $base"
    mkdir -p "$(dirname "$target")"
    local tmp="${target}.partial"
    rm -f "$tmp"
    if download_url "$url" "$tmp"; then
        if [[ -n "$sha" ]] && ! sha_ok "$tmp" "$sha"; then
            err "SHA256 mismatch: $base"
            rm -f "$tmp"
            echo "HASH AUX $base" >> "$FAILED"
            return 0
        fi
        mv "$tmp" "$target"
        echo "DOWNLOAD AUX $base" >> "$INSTALLED"
    else
        rm -f "$tmp"
        echo "DOWNLOAD AUX $base | $url" >> "$FAILED"
    fi
}

# -----------------------------------------------------------------------------
# Models
# -----------------------------------------------------------------------------

if [[ "$NODES_ONLY" == 0 ]]; then
    info "Preparing workflow model assets"
    tail -n +2 "$REQ_MODELS" | while IFS='|' read -r dest rel base embedded_url workflows; do
        [[ -n "$dest" && -n "$rel" ]] || continue
        case "$dest" in
            __wananimate_detection__|__controlnet_aux__)
                install_aux_asset "$base"
                ;;
            *)
                install_standard_asset "$dest" "$rel" "$base" "$embedded_url" "$workflows"
                ;;
        esac
    done

    # Compatibility aliases justified by the workflow's own embedded download
    # notes. These are created only if the old filename is required and absent.
    if grep -q '^vae|wan21-vae.safetensors|' "$REQ_MODELS"; then
        # The workflow's own note identifies wan_2.1_vae as the required file.
        install_standard_asset "vae" "wan_2.1_vae.safetensors" "wan_2.1_vae.safetensors" "" "compatibility for wan21-vae.safetensors"
        src="$COMFY/models/vae/wan_2.1_vae.safetensors"
        dst="$COMFY/models/vae/wan21-vae.safetensors"
        if [[ -e "$src" && ! -e "$dst" ]]; then
            info "Creating workflow compatibility alias: wan21-vae.safetensors -> wan_2.1_vae.safetensors"
            [[ "$VERIFY_ONLY" == 1 ]] || ln -s "$src" "$dst"
        fi
    fi

    if grep -q '^diffusion_models|krea2TurboFP8_krea2TURBO.safetensors|' "$REQ_MODELS"; then
        # The workflow's embedded model note names krea2_turbo_int8_convrot.
        install_standard_asset "diffusion_models" "krea2_turbo_int8_convrot.safetensors" "krea2_turbo_int8_convrot.safetensors" "" "compatibility for krea2TurboFP8_krea2TURBO.safetensors"
        src="$COMFY/models/diffusion_models/krea2_turbo_int8_convrot.safetensors"
        dst="$COMFY/models/diffusion_models/krea2TurboFP8_krea2TURBO.safetensors"
        if [[ -e "$src" && ! -e "$dst" ]]; then
            warn "Creating compatibility alias: krea2TurboFP8_krea2TURBO.safetensors -> krea2_turbo_int8_convrot.safetensors"
            [[ "$VERIFY_ONLY" == 1 ]] || ln -s "$src" "$dst"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Final verification report
# -----------------------------------------------------------------------------

info "Final workflow asset verification"
MISSING_COUNT=0
while IFS='|' read -r dest rel base embedded_url workflows; do
    [[ "$dest" == "dest" ]] && continue
    [[ -n "$dest" ]] || continue
    if [[ "$dest" == __wananimate_detection__ || "$dest" == __controlnet_aux__ ]]; then
        line="$(aux_lookup "$base" || true)"
        target="$(echo "$line" | awk -F'|' '{print $2}')"
    else
        target="$(model_root_for_dest "$dest")/$rel"
    fi
    if [[ -e "$target" || -L "$target" ]]; then
        printf 'OK      %s\n' "$target"
    else
        printf 'MISSING %s  [%s]\n' "$target" "$workflows"
        MISSING_COUNT=$((MISSING_COUNT+1))
    fi
done < "$REQ_MODELS"

echo
echo "============================================================"
echo "WORKFLOW ASSET INSTALL COMPLETE"
echo "============================================================"
echo "Required model refs: $(($(wc -l < "$REQ_MODELS") - 1))"
echo "Missing after run:   $MISSING_COUNT"
echo "Unresolved entries:  $(wc -l < "$UNRESOLVED")"
echo "Failed entries:      $(wc -l < "$FAILED")"
echo
echo "Reports:"
echo "  $REQ_MODELS"
echo "  $REQ_NODES"
echo "  $UNRESOLVED"
echo "  $FAILED"
echo "  $LOG"

if [[ -s "$UNRESOLVED" ]]; then
    echo
    echo "Unresolved (usually personal/private/ambiguous assets):"
    sed 's/^/  - /' "$UNRESOLVED"
fi
if [[ -s "$FAILED" ]]; then
    echo
    echo "Failures:"
    sed 's/^/  - /' "$FAILED"
fi

echo
if ((MISSING_COUNT == 0)); then
    echo "All workflow model references are present. Restart ComfyUI if custom nodes were installed."
else
    echo "Some workflow references still need attention; see the unresolved/failed reports above."
fi
