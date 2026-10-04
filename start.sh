#!/bin/bash

# Save RunPod template variables (HF_TOKEN etc.) for SSH sessions,
# otherwise sshd doesn't pass them and they are not visible in the terminal
export -p | grep -E 'declare -x (HF_|RUNPOD_|CIVITAI_|DOWNLOAD_|VAST_|PUBLIC_IPADDR)' > /etc/rp_environment

# SSH: RunPod passes the key in PUBLIC_KEY, Vast.ai in SSH_PUBLIC_KEY
KEY="${PUBLIC_KEY:-$SSH_PUBLIC_KEY}"
if [ -n "$KEY" ]; then
    mkdir -p ~/.ssh /run/sshd
    grep -qxF "$KEY" ~/.ssh/authorized_keys 2>/dev/null || echo "$KEY" >> ~/.ssh/authorized_keys
    chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
    ssh-keygen -A >/dev/null 2>&1          # host keys, if they are not in the image
    if [ -f /run/sshd.pid ] && kill -0 "$(cat /run/sshd.pid)" 2>/dev/null; then
        echo "SSH: sshd is already running"
    elif /usr/sbin/sshd; then
        echo "SSH: sshd started on port 22"
    else
        echo "!!! SSH: sshd failed to start, checking config:"; /usr/sbin/sshd -t
    fi
else
    echo "!!! SSH: no public key provided (PUBLIC_KEY / SSH_PUBLIC_KEY are empty), sshd not started"
fi

# Vast.ai: there is no /workspace by default, create it so everything lives where it does on RunPod
if [ -n "$PUBLIC_IPADDR" ] || [ -n "$VAST_CONTAINERLABEL" ]; then
    mkdir -p /workspace
fi

# Persistent storage: on RunPod this is /workspace (Network Volume or pod disk), on Vast.ai the instance disk.
# Models, outputs, inputs and user (workflows, settings) live there and survive restarts.
if [ -d /workspace ]; then
    for dir in models output input user; do
        # leave folders mounted via -v alone (otherwise rm -rf would delete files on the host)
        if mountpoint -q "/opt/ComfyUI/$dir"; then
            echo "$dir: mounted via -v, leaving as is"
            continue
        fi
        mkdir -p "/workspace/$dir"
        # on first start, move the default ComfyUI folder structure over (without overwriting)
        if [ -d "/opt/ComfyUI/$dir" ] && [ ! -L "/opt/ComfyUI/$dir" ]; then
            cp -rn "/opt/ComfyUI/$dir/." "/workspace/$dir/" 2>/dev/null
            rm -rf "/opt/ComfyUI/$dir"
        fi
        ln -sfn "/workspace/$dir" "/opt/ComfyUI/$dir"
    done
    echo "Models: /workspace/models"

    # the model list lives on the disk so it can be edited without rebuilding the image
    [ -f /workspace/models.txt ] || cp /opt/models.txt /workspace/models.txt
fi

# Background model download (DOWNLOAD_MODELS=1 variable in the RunPod template).
# ComfyUI starts right away; downloaded models appear after refreshing the page.
if [ "$DOWNLOAD_MODELS" = "1" ]; then
    echo "Downloading models in the background, log: /workspace/download-models.log"
    download-models > /workspace/download-models.log 2>&1 &
fi

cd /opt/ComfyUI

EXTRA_ARGS=()
# RunPod: the https://<pod>-8188.proxy.runpod.net proxy sends Host: localhost,
# while Origin stays the proxy domain. ComfyUI treats it as a foreign site and answers 403.
# Allow exactly this domain (the flag also disables the Origin check in ComfyUI).
if [ -n "$RUNPOD_POD_ID" ]; then
    EXTRA_ARGS+=(--enable-cors-header "https://${RUNPOD_POD_ID}-8188.proxy.runpod.net")
    echo "ComfyUI: https://${RUNPOD_POD_ID}-8188.proxy.runpod.net"
fi

exec /opt/ComfyUI/venv/bin/python main.py \
    --listen 0.0.0.0 --port 8188 \
    --enable-manager \
    --use-sage-attention \
    --fast fp16_accumulation \
    "${EXTRA_ARGS[@]}"
