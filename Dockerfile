# OneEvil-runpod-ComfyUI
FROM ubuntu:26.04

LABEL org.opencontainers.image.title="OneEvil-runpod-ComfyUI" \
      org.opencontainers.image.description="ComfyUI для RunPod: Ubuntu 26.04, PyTorch nightly cu132, SageAttention, llama-cpp, кастомные ноды"

# Образ без CUDA Toolkit: torch, SageAttention и llama-cpp-python ставятся
# из готовых wheel-файлов, собранных на хосте (папка wheels/ рядом с Dockerfile).
# Хост и образ должны совпадать: Ubuntu 26.04, системный Python 3.14.

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PATH=/opt/ComfyUI/venv/bin:$PATH

##############################################################
# Системные пакеты (драйвер НЕ ставим: его даёт хост)
##############################################################
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget curl git build-essential pkg-config \
        python3 python3-venv python3-dev \
        ffmpeg libgl1 libglib2.0-0t64 aria2 \
        openssh-server \
    && rm -rf /var/lib/apt/lists/*

##############################################################
# ФАЗА 1: ComfyUI + venv
##############################################################
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI && \
    python3 -m venv /opt/ComfyUI/venv && \
    pip install --upgrade pip && \
    python --version
WORKDIR /opt/ComfyUI

##############################################################
# Wheel-файлы с хоста
##############################################################
COPY wheels/ /wheels/
RUN cp /wheels/torch-versions.txt /constraints.txt && cat /constraints.txt

# torch/torchvision/torchaudio/triton: ровно те версии, что на хосте (из /wheels),
# их зависимости nvidia-* берутся из индексов
RUN pip install --pre --find-links /wheels -r /constraints.txt \
        --extra-index-url https://download.pytorch.org/whl/nightly/cu132

# Библиотеки CUDA из pip-пакетов nvidia-* делаем видимыми для всей системы:
# llama-cpp был собран с toolkit и ищет libcudart/libcublas, в образе они только здесь
RUN find /opt/ComfyUI/venv -path '*/nvidia/*' -name 'lib*.so*' -printf '%h\n' | sort -u \
        > /etc/ld.so.conf.d/nvidia-pip.conf && \
    cat /etc/ld.so.conf.d/nvidia-pip.conf && ldconfig

RUN pip install -r requirements.txt -c /constraints.txt && \
    pip install -r manager_requirements.txt -c /constraints.txt && \
    pip install nvidia-vfx matrix-nio PyOpenGL-accelerate -c /constraints.txt && \
    pip install huggingface_hub -c /constraints.txt && \
    hf --help > /dev/null && echo "+ hf CLI OK"

##############################################################
# ФАЗЫ 2-3: SageAttention и llama-cpp-python из готовых wheel
##############################################################
RUN pip install /wheels/sageattention-*.whl /wheels/llama_cpp_python-*.whl -c /constraints.txt

##############################################################
# ФАЗА 5: Ноды (всегда последние версии)
# Формат: node <репозиторий> <папка> [ветка]; папки названы так же, как на рабочей машине
# Без ветки берётся ветка по умолчанию (обычно main/master)
##############################################################
RUN set -e; cd custom_nodes; \
    node() { \
      git clone --depth 1 ${3:+--branch "$3"} "$1" "$2"; \
      echo "+ $2 @ $(git -C "$2" rev-parse --abbrev-ref HEAD) $(git -C "$2" rev-parse --short HEAD)"; \
    }; \
    node https://github.com/evanspearman/ComfyMath.git                           ComfyMath; \
    node https://github.com/BobRandomNumber/ComfyUI-Crystools-MonitorOnly.git    ComfyUI-Crystools-MonitorOnly; \
    node https://github.com/Lightricks/ComfyUI-LTXVideo.git                      ComfyUI-LTXVideo; \
    node https://github.com/bbaudio-2025/Comfyui-MMH3-UltimateUpscale.git        Comfyui-MMH3-UltimateUpscale; \
    node https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler.git    Comfyui_Minimax_h3_latent_Upscaler; \
    node https://github.com/T8mars/comfyui-minimax-h3-audio-T8.git               comfyui-minimax-h3-audio-T8; \
    node https://github.com/vrgamegirl19/comfyui-vrgamedevgirl.git               comfyui-vrgamedevgirl              Beta2.0; \
    node https://github.com/city96/ComfyUI-GGUF.git                              ComfyUI-GGUF; \
    node https://github.com/pixaroma/ComfyUI-Pixaroma.git                        ComfyUI-Pixaroma; \
    node https://github.com/ltdrdata/ComfyUI-Impact-Pack.git                     comfyui-impact-pack; \
    node https://github.com/kijai/ComfyUI-KJNodes.git                            comfyui-kjnodes; \
    node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git             comfyui-videohelpersuite; \
    node https://github.com/LAOGOU-666/Comfyui-Memory_Cleanup.git                comfyui_memory_cleanup; \
    node https://github.com/erosDiffusion/ComfyUI-EulerDiscreteScheduler.git     erosdiffusion-eulerflowmatchingdiscretescheduler

# Патчи LTXVideo из шпаргалки. Код ноды обновляется, поэтому патчи мягкие:
# если файла/строки уже нет, сборка не падает, а в логе будет предупреждение
RUN cd custom_nodes/ComfyUI-LTXVideo && \
    sed -i 's/^ninja~=.*/ninja/' requirements.txt && \
    if grep -qE '^ *pad,$' pyramid_blending.py 2>/dev/null; then \
      sed -i -e '/^ *pad,$/d' -e '1i import torch.nn.functional as _kfx\npad = _kfx.pad' pyramid_blending.py && \
      echo "+ LTX patch: pyramid_blending.py"; \
    else \
      echo "!!! LTX patch: pyramid_blending.py не требует патча или изменился, проверьте вручную"; \
    fi

# Зависимости всех нод; torch зафиксирован через constraints, сборка упадёт при конфликте
RUN set -e; cd custom_nodes; \
    for d in */; do \
      if [ -f "$d/requirements.txt" ]; then \
        echo ">>> $d"; \
        pip install -r "$d/requirements.txt" -c /constraints.txt; \
      fi; \
    done

# Форк kornia ставим последним, чтобы ноды его не перезаписали
RUN pip install --no-deps --force-reinstall git+https://github.com/AbhiKhoyani/kornia@main && \
    python -c "import torch; print('torch', torch.__version__)"

##############################################################
# ФАЗА 6: Автозапуск (вместо systemd)
##############################################################
COPY start.sh /start.sh
COPY download-models.sh /usr/local/bin/download-models
COPY pack-project.sh /usr/local/bin/pack-project
COPY models.txt /opt/models.txt
RUN chmod +x /start.sh /usr/local/bin/download-models /usr/local/bin/pack-project && \
    echo 'export PATH=/opt/ComfyUI/venv/bin:$PATH' >> /root/.bashrc && \
    echo '[ -f /etc/rp_environment ] && source /etc/rp_environment' >> /root/.bashrc

EXPOSE 8188 22
CMD ["/start.sh"]
