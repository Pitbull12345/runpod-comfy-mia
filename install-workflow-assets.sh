#!/usr/bin/env bash
set -Eeuo pipefail
export COMFY="${COMFY:-/opt/ComfyUI}"
export WORKSPACE="${WORKSPACE:-/workspace}"

for s in \
  /workspace/runpod_workflow_assets.sh \
  /workspace/workflow-assets/runpod_workflow_assets.sh \
  /workspace/runpod_workflow_assets_bundle/runpod_workflow_assets.sh
do
  if [[ -f "$s" ]]; then
    chmod +x "$s"
    exec "$s" "$@"
  fi
done

echo "runpod_workflow_assets.sh not found under /workspace." >&2
exit 1
