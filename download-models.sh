#!/bin/bash
# Скачивание моделей по списку.
#   download-models               - список /workspace/models.txt (или /opt/models.txt)
#   download-models мой_список.txt
# Уже скачанные файлы пропускаются, оборванные закачки продолжаются.

HF=/opt/ComfyUI/venv/bin/hf
MODELS_DIR=/opt/ComfyUI/models          # на RunPod это симлинк на /workspace/models

LIST="$1"
if [ -z "$LIST" ]; then
    if [ -f /workspace/models.txt ]; then LIST=/workspace/models.txt; else LIST=/opt/models.txt; fi
fi
[ -f "$LIST" ] || { echo "Список не найден: $LIST"; exit 1; }

[ -f /etc/rp_environment ] && source /etc/rp_environment

echo "Список: $LIST"
echo "Папка:  $MODELS_DIR"
[ -n "$HF_TOKEN" ] && echo "HF_TOKEN: есть" || echo "HF_TOKEN: нет (закрытые репозитории не скачаются)"
echo

ok=0; skip=0; fail=0
TMP="$MODELS_DIR/.download-tmp"

while read -r folder source name <&3 || [ -n "$folder" ]; do
    # пропуск пустых строк и комментариев
    [ -z "$folder" ] && continue
    case "$folder" in \#*) continue ;; esac

    if [[ "$source" == hf:* ]]; then
        spec="${source#hf:}"            # repo:путь/к/файлу
        repo="${spec%%:*}"
        path="${spec#*:}"
        [ -z "$name" ] && name="$(basename "$path")"
    else
        url="$source"
        [ -z "$name" ] && name="$(basename "${url%%\?*}")"
    fi

    dest="$MODELS_DIR/$folder/$name"
    mkdir -p "$MODELS_DIR/$folder"

    if [ -s "$dest" ] && [ ! -f "$dest.aria2" ]; then
        echo "= есть    $folder/$name"
        skip=$((skip+1)); continue
    fi

    echo "↓ качаю   $folder/$name"
    if [[ "$source" == hf:* ]]; then
        rm -rf "$TMP" && mkdir -p "$TMP"
        if "$HF" download "$repo" "$path" --local-dir "$TMP" && mv "$TMP/$path" "$dest"; then
            ok=$((ok+1))
        else
            echo "! ошибка  $folder/$name"; fail=$((fail+1))
        fi
        rm -rf "$TMP"
    else
        hdr=()
        if [[ "$url" == *civitai.com* ]] && [ -n "$CIVITAI_TOKEN" ]; then
            hdr=(--header="Authorization: Bearer $CIVITAI_TOKEN")
        fi
        if aria2c -x 16 -s 16 -c --console-log-level=warn --summary-interval=10 \
                "${hdr[@]}" -d "$MODELS_DIR/$folder" -o "$name" "$url"; then
            ok=$((ok+1))
        else
            echo "! ошибка  $folder/$name"; fail=$((fail+1))
        fi
    fi
done 3< "$LIST"

echo
echo "Готово: скачано $ok, уже было $skip, ошибок $fail"
[ "$fail" -eq 0 ]
