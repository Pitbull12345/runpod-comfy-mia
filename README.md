# RunPod ComfyUI — custom stable template

This image avoids the failure mode you were hitting in stock/community templates.

## The important design choice

Executable software is baked into the image:

```text
/opt/ComfyUI
/opt/venv
```

Runtime/user data is separate:

```text
/workspace/models
/workspace/input
/workspace/output
/workspace/temp
/workspace/user
```

A RunPod volume mounted at `/workspace` therefore cannot hide, replace, or
partially corrupt the Python environment.

There are **no startup-time pip installs**, no startup-time venv creation, no
automatic SageAttention wheel install, and no `mv` of ComfyUI into `/workspace`.

## GPU builds

Default/A100:

```text
CUDA 12.8.1
PyTorch 2.11.0 + cu128
```

Optional Blackwell/5090 build:

```text
CUDA 13.0.1
PyTorch 2.11.0 + cu130
```

The same Dockerfile builds both variants.

## Recommended way to build

Create a GitHub repository and put this bundle in it. The included
`.github/workflows/build.yml` automatically builds:

```text
ghcr.io/YOUR_USER/runpod-comfy-mia:cu128
ghcr.io/YOUR_USER/runpod-comfy-mia:cu130
```

Make the resulting GHCR package public, or add its registry credentials to
RunPod.

## RunPod custom template

Use `RUNPOD_TEMPLATE_SETTINGS.txt`.

Most important setting:

```text
Container Start Command: blank
```

Do not override the entrypoint.

For A100 use:

```text
ghcr.io/YOUR_USER/runpod-comfy-mia:cu128
```

For RTX 5090 use:

```text
ghcr.io/YOUR_USER/runpod-comfy-mia:cu130
```

Ports:

```text
8188/http
8888/http
22/tcp
```

I recommend a 200–250 GB container disk if the pod will download the entire
workflow model collection onto its disposable disk.

A volume is optional. If you use one, mount it at `/workspace`.

## Expected startup log

Startup should only do:

```text
GPU preflight
SSH started
Jupyter started
Starting ComfyUI
```

It should NOT say:

```text
creating venv
installing sageattention
moving ComfyUI
copying ComfyUI into /workspace
.../venv/bin/activate not found
```

## Workflow asset installer

After ComfyUI is healthy, place the workflow-assets installer from the previous
step somewhere under `/workspace`, then run:

```bash
install-workflow-assets --verify-only
install-workflow-assets
```

The wrapper automatically forces:

```text
COMFY=/opt/ComfyUI
```

so it targets this image correctly.

## Health checks

```bash
nvidia-smi

/opt/venv/bin/python -c \
'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0))'

curl -s http://127.0.0.1:8188/system_stats | jq .
```

ComfyUI proxy:

```text
https://<POD_ID>-8188.proxy.runpod.net
```

Jupyter proxy:

```text
https://<POD_ID>-8888.proxy.runpod.net
```

## Why this is safer

The container image contains the immutable working runtime. `/workspace` is
treated only as data storage. Even if `/workspace` has unusual ownership,
doesn't preserve Unix metadata, or contains stale files from an older pod, it
cannot remove `/opt/venv/bin/python` or `/opt/ComfyUI/main.py`.
