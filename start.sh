#!/bin/bash

# Переменные шаблона RunPod (HF_TOKEN и т.п.) сохраняем для SSH-сессий,
# иначе sshd их не передаёт и в терминале их не видно
export -p | grep -E 'declare -x (HF_|RUNPOD_|CIVITAI_|DOWNLOAD_)' > /etc/rp_environment

# SSH: RunPod передаёт публичный ключ в переменной PUBLIC_KEY
if [ -n "$PUBLIC_KEY" ]; then
    mkdir -p ~/.ssh /run/sshd
    echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
    chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
    /usr/sbin/sshd
fi

# Постоянное хранилище: на RunPod это /workspace (Network Volume или диск пода).
# Модели, результаты, входные файлы и user (workflow, настройки) живут там и переживают перезапуск.
if [ -d /workspace ]; then
    for dir in models output input user; do
        # папку, подключённую через -v, не трогаем (иначе rm -rf удалил бы файлы на хосте)
        if mountpoint -q "/opt/ComfyUI/$dir"; then
            echo "$dir: подключена через -v, оставляю как есть"
            continue
        fi
        mkdir -p "/workspace/$dir"
        # при первом запуске переносим стандартную структуру папок ComfyUI (без перезаписи)
        if [ -d "/opt/ComfyUI/$dir" ] && [ ! -L "/opt/ComfyUI/$dir" ]; then
            cp -rn "/opt/ComfyUI/$dir/." "/workspace/$dir/" 2>/dev/null
            rm -rf "/opt/ComfyUI/$dir"
        fi
        ln -sfn "/workspace/$dir" "/opt/ComfyUI/$dir"
    done
    echo "Models: /workspace/models"

    # список моделей лежит на диске, чтобы его можно было править без пересборки образа
    [ -f /workspace/models.txt ] || cp /opt/models.txt /workspace/models.txt
fi

# Автоскачивание моделей в фоне (переменная DOWNLOAD_MODELS=1 в шаблоне RunPod).
# ComfyUI стартует сразу; скачанные модели появятся после обновления страницы.
if [ "$DOWNLOAD_MODELS" = "1" ]; then
    echo "Скачивание моделей в фоне, лог: /workspace/download-models.log"
    download-models > /workspace/download-models.log 2>&1 &
fi

cd /opt/ComfyUI
exec /opt/ComfyUI/venv/bin/python main.py \
    --listen 0.0.0.0 --port 8188 \
    --enable-manager \
    --use-sage-attention \
    --fast fp16_accumulation
