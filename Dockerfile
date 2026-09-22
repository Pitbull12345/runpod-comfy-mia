# syntax=docker/dockerfile:1.7
ARG CUDA_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
FROM ${CUDA_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG TORCH_VERSION=2.11.0
ARG TORCHVISION_VERSION=0.26.0
ARG TORCHAUDIO_VERSION=2.11.0
ARG TORCH_INDEX=cu128
ARG COMFY_REF=master

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    COMFY=/opt/ComfyUI COMFY_VENV=/opt/venv WORKSPACE=/workspace \
    COMFY_PORT=8188 ENABLE_JUPYTER=1 JUPYTER_PORT=8888

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git git-lfs python3 python3-venv python3-pip \
    ffmpeg libgl1 libglib2.0-0 libsm6 libxext6 openssh-server openssl tini \
    nano vim-tiny tmux htop tree jq rsync unzip zip iproute2 procps psmisc lsof \
    build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/* && git lfs install --system

RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/python -m pip install --upgrade pip setuptools wheel \
    && /opt/venv/bin/python -m pip install \
       torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} \
       torchaudio==${TORCHAUDIO_VERSION} \
       --index-url https://download.pytorch.org/whl/${TORCH_INDEX}

RUN git clone https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI \
    && cd /opt/ComfyUI \
    && git fetch --depth 1 origin "${COMFY_REF}" \
    && git checkout --detach FETCH_HEAD \
    && /opt/venv/bin/python -m pip install -r requirements.txt

RUN git clone https://github.com/Comfy-Org/ComfyUI-Manager.git \
      /opt/ComfyUI/custom_nodes/ComfyUI-Manager \
    && if [[ -f /opt/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt ]]; then \
         /opt/venv/bin/python -m pip install \
           -r /opt/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt; \
       fi \
    && /opt/venv/bin/python -m pip install jupyterlab

COPY extra_model_paths.yaml /opt/ComfyUI/extra_model_paths.yaml
COPY start-comfy.sh /usr/local/bin/start-comfy.sh
COPY install-workflow-assets.sh /usr/local/bin/install-workflow-assets

RUN chmod 0755 /usr/local/bin/start-comfy.sh /usr/local/bin/install-workflow-assets \
    && mkdir -p /run/sshd /workspace \
    && printf '%s\n' \
       'PermitRootLogin prohibit-password' \
       'PasswordAuthentication no' \
       'PubkeyAuthentication yes' \
       > /etc/ssh/sshd_config.d/99-runpod.conf

WORKDIR /workspace
EXPOSE 22 8188 8888

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8188/system_stats >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/start-comfy.sh"]
