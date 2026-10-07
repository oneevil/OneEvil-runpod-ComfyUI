# syntax=docker/dockerfile:1
# OneEvil-runpod-ComfyUI
FROM ubuntu:26.04

LABEL org.opencontainers.image.title="OneEvil-runpod-ComfyUI" \
      org.opencontainers.image.description="ComfyUI for RunPod: Ubuntu 26.04, PyTorch nightly cu132, SageAttention, llama-cpp, custom nodes"

# Image without CUDA Toolkit: torch, SageAttention and llama-cpp-python are installed
# from prebuilt wheel files built on the host (the wheels/ folder next to the Dockerfile,
# mounted only during the build and never included in the image).
# Host and image must match: Ubuntu 26.04, system Python 3.14.

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PATH=/opt/ComfyUI/venv/bin:$PATH

##############################################################
# System packages (NO driver: the host provides it)
##############################################################
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget curl git build-essential pkg-config \
        python3 python3-venv python3-dev \
        ffmpeg libgl1 libglib2.0-0t64 aria2 \
        openssh-server \
    && rm -rf /var/lib/apt/lists/*

##############################################################
# Layer order: rarely changing things first (venv, torch, wheels),
# then what gets updated on every build (ComfyUI, nodes).
# This way updating ComfyUI doesn't re-download gigabytes of torch.
##############################################################

# venv
RUN mkdir -p /opt/ComfyUI && \
    python3 -m venv /opt/ComfyUI/venv && \
    pip install --upgrade pip && \
    python --version
WORKDIR /opt/ComfyUI

# Wheel files from the host are NOT copied into the image: the wheels/ folder is mounted
# only during installation (RUN --mount), which makes the image 2-3 GB lighter.
# Only the list of torch versions gets into the image, to pin them via constraints.
COPY wheels/torch-versions.txt /constraints.txt
RUN cat /constraints.txt

# torch/torchvision/torchaudio/triton: exactly the versions from the host (from /wheels),
# their nvidia-* dependencies come from the indexes
RUN --mount=type=bind,source=wheels,target=/wheels \
    pip install --pre --find-links /wheels -r /constraints.txt \
        --extra-index-url https://download.pytorch.org/whl/nightly/cu132

# Make CUDA libraries from the nvidia-* pip packages visible system-wide:
# llama-cpp was built with the toolkit and looks for libcudart/libcublas, which only live here in the image
RUN find /opt/ComfyUI/venv -path '*/nvidia/*' -name 'lib*.so*' -printf '%h\n' | sort -u \
        > /etc/ld.so.conf.d/nvidia-pip.conf && \
    cat /etc/ld.so.conf.d/nvidia-pip.conf && ldconfig

# SageAttention and llama-cpp-python from prebuilt wheels
RUN --mount=type=bind,source=wheels,target=/wheels \
    pip install /wheels/sageattention-*.whl /wheels/llama_cpp_python-*.whl -c /constraints.txt

##############################################################
# UPDATABLE PART
# CACHE_BUST changes on every build (build-and-push.sh passes the current time),
# so everything below is rebuilt: fresh ComfyUI and fresh nodes.
##############################################################
ARG CACHE_BUST=0
RUN echo "Build: ${CACHE_BUST}"

# ComfyUI (latest version of the default branch). Cloned into the folder that already holds the venv
RUN git init -q && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI.git && \
    git fetch -q --depth 1 origin HEAD && \
    git checkout -q -f FETCH_HEAD && \
    echo "+ ComfyUI @ $(git rev-parse --short HEAD)"

RUN pip install -r requirements.txt -c /constraints.txt && \
    pip install -r manager_requirements.txt -c /constraints.txt && \
    pip install nvidia-vfx matrix-nio PyOpenGL-accelerate -c /constraints.txt && \
    pip install huggingface_hub -c /constraints.txt && \
    hf --help > /dev/null && echo "+ hf CLI OK"

##############################################################
# PHASE 5: Nodes (always the latest versions)
# Format: node <repository> <folder> [branch]; folders are named the same as on the work machine
# Without a branch, the default branch is used (usually main/master)
##############################################################
RUN set -e; cd custom_nodes; \
    node() { \
      git clone --depth 1 ${3:+--branch "$3"} "$1" "$2"; \
      echo "+ $2 @ $(git -C "$2" rev-parse --abbrev-ref HEAD) $(git -C "$2" rev-parse --short HEAD)"; \
    }; \
    node https://github.com/evanspearman/ComfyMath.git                           ComfyMath; \
    node https://github.com/BobRandomNumber/ComfyUI-Crystools-MonitorOnly.git    ComfyUI-Crystools-MonitorOnly; \
    node https://github.com/Lightricks/ComfyUI-LTXVideo.git                      ComfyUI-LTXVideo; \
    node https://github.com/Luisacaotica/ComfyUI-MiniMaxH3Mod.git                ComfyUI-MiniMaxH3Mod; \
    node https://github.com/bbaudio-2025/Comfyui-MMH3-UltimateUpscale.git        Comfyui-MMH3-UltimateUpscale; \
    node https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler.git    Comfyui_Minimax_h3_latent_Upscaler; \
    node https://github.com/T8mars/comfyui-minimax-h3-audio-T8.git               comfyui-minimax-h3-audio-T8; \
    node https://github.com/vrgamegirl19/comfyui-vrgamedevgirl.git               comfyui-vrgamedevgirl              Beta2.0; \
    node https://github.com/city96/ComfyUI-GGUF.git                              ComfyUI-GGUF; \
    node https://github.com/ltdrdata/ComfyUI-Impact-Pack.git                     comfyui-impact-pack; \
    node https://github.com/kijai/ComfyUI-KJNodes.git                            comfyui-kjnodes; \
    node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git             comfyui-videohelpersuite; \
    node https://github.com/LAOGOU-666/Comfyui-Memory_Cleanup.git                comfyui_memory_cleanup; \
    node https://github.com/erosDiffusion/ComfyUI-EulerDiscreteScheduler.git     erosdiffusion-eulerflowmatchingdiscretescheduler

# LTXVideo patch: remove the hard pin of ninja to an old version.
# (The pyramid_blending.py patch is no longer needed: LTXVideo dropped the pad import from kornia.)
RUN sed -i 's/^ninja~=.*/ninja/' custom_nodes/ComfyUI-LTXVideo/requirements.txt

# Dependencies of all nodes; torch is pinned via constraints, the build fails on a conflict
RUN set -e; cd custom_nodes; \
    for d in */; do \
      if [ -f "$d/requirements.txt" ]; then \
        echo ">>> $d"; \
        pip install -r "$d/requirements.txt" -c /constraints.txt; \
      fi; \
    done

# The kornia fork is installed last so the nodes don't overwrite it
RUN pip install --no-deps --force-reinstall git+https://github.com/AbhiKhoyani/kornia@main && \
    python -c "import torch; print('torch', torch.__version__)"

##############################################################
# PHASE 6: Autostart (instead of systemd)
##############################################################
COPY start.sh /start.sh
COPY download-models.sh /usr/local/bin/download-models
COPY pack-project.sh /usr/local/bin/pack-project
COPY models.txt /opt/models.txt

# shutil patch for network volumes (see fs_compat.py), loaded at startup by every venv Python.
# A .pth file rather than sitecustomize.py: Ubuntu ships its own sitecustomize, which would shadow ours
COPY fs_compat.py /tmp/fs_compat.py
RUN SP="$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" && \
    mv /tmp/fs_compat.py "$SP/fs_compat.py" && \
    echo 'import fs_compat' > "$SP/fs_compat.pth" && \
    python -c "import shutil; assert hasattr(shutil.copystat, '__wrapped__')" && echo "+ fs_compat OK"

# PATH and template variables go to the TOP of .bashrc: the stock Ubuntu .bashrc returns early
# for non-interactive shells, so lines appended at the end are skipped by `ssh pod <command>`
RUN chmod +x /start.sh /usr/local/bin/download-models /usr/local/bin/pack-project && \
    { echo 'export PATH=/opt/ComfyUI/venv/bin:$PATH'; \
      echo '[ -f /etc/rp_environment ] && source /etc/rp_environment'; \
      cat /root/.bashrc; } > /tmp/bashrc && mv /tmp/bashrc /root/.bashrc

EXPOSE 8188 22
CMD ["/start.sh"]
