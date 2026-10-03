#!/bin/bash
# Выбор проекта из /opt/ComfyUI/output стрелками и упаковка в tar для переноса на RunPod.
# Папки, начинающиеся на VRGDG_, не показываются.
#   ↑/↓ — выбор, Enter — упаковать, q — выход

OUTPUT_DIR="${OUTPUT_DIR:-/opt/ComfyUI/output}"

# Где запущен скрипт: на поде RunPod (есть /workspace) или на своём сервере
if [ -d /workspace ]; then
    ON_POD=1
    [ -f /etc/rp_environment ] && source /etc/rp_environment
    EXPORT_DIR="${EXPORT_DIR:-/workspace/export}"     # на постоянном диске, не на маленьком Container Disk
else
    ON_POD=0
    EXPORT_DIR="${EXPORT_DIR:-$HOME/comfyui-export}"
fi

[ -d "$OUTPUT_DIR" ] || { echo "Нет папки $OUTPUT_DIR"; exit 1; }

# Проекты: новые сверху. Glob, а не find: так работают и симлинки
# (если output или папки проектов — ссылки на другой диск)
mapfile -t projects < <(
    for d in "$OUTPUT_DIR"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        [[ "$name" == VRGDG_* ]] && continue
        printf '%s\t%s\n' "$(stat -L -c '%Y' "$d")" "$name"
    done | sort -rn | cut -f2-
)
n=${#projects[@]}
[ "$n" -eq 0 ] && { echo "Проектов не найдено в $OUTPUT_DIR"; exit 0; }

echo "Считаю размеры..."
labels=()
for p in "${projects[@]}"; do
    size=$(du -shL "$OUTPUT_DIR/$p" 2>/dev/null | cut -f1)
    date=$(date -r "$OUTPUT_DIR/$p" '+%d.%m.%Y %H:%M')
    labels+=("$(printf '%-7s %s   %s' "$size" "$date" "$p")")
done

# ---------- меню ----------
sel=0
top=0
tput civis
trap 'tput cnorm' EXIT

draw() {
    local rows=$(( $(tput lines) - 5 ))
    (( rows < 3 )) && rows=3
    (( sel < top )) && top=$sel
    (( sel >= top + rows )) && top=$(( sel - rows + 1 ))

    clear
    echo "Проекты в $OUTPUT_DIR ($n)   ↑/↓ выбор, Enter упаковать, q выход"
    echo
    local i
    for (( i = top; i < n && i < top + rows; i++ )); do
        if (( i == sel )); then
            printf '\e[7m > %s \e[0m\n' "${labels[$i]}"
        else
            printf '   %s\n' "${labels[$i]}"
        fi
    done
    (( n > rows )) && echo && echo "   ... $(( sel + 1 )) из $n"
}

while true; do
    draw
    IFS= read -rsn1 key
    if [[ "$key" == $'\e' ]]; then
        read -rsn2 -t 0.1 key
        case "$key" in
            '[A') (( sel > 0 )) && (( sel-- )) ;;
            '[B') (( sel < n - 1 )) && (( sel++ )) ;;
            '[5') read -rsn1 -t 0.1; (( sel = sel - 10 < 0 ? 0 : sel - 10 )) ;;          # PgUp
            '[6') read -rsn1 -t 0.1; (( sel = sel + 10 > n - 1 ? n - 1 : sel + 10 )) ;;  # PgDn
        esac
    elif [[ "$key" == "" ]]; then
        break
    elif [[ "$key" == "q" || "$key" == "Q" ]]; then
        tput cnorm; clear; echo "Отменено"; exit 0
    fi
done

tput cnorm
clear

# ---------- упаковка ----------
project="${projects[$sel]}"
mkdir -p "$EXPORT_DIR"
archive="$EXPORT_DIR/$project.tar"

echo "Проект: $project"
echo "Архив:  $archive"
echo
echo "Упаковываю..."

# путь внутри архива: output/<проект>, распаковывается из /opt/ComfyUI
# -h: если внутри ссылки, в архив попадают сами файлы, а не ссылки
if tar chf "$archive" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")/$project"; then
    echo "Готово: $(du -h "$archive" | cut -f1)"
    echo
    if [ "$ON_POD" = 1 ]; then
        ip="${RUNPOD_PUBLIC_IP:-<IP>}"
        port="${RUNPOD_TCP_PORT_22:-<ПОРТ>}"
        echo "Забрать на свой сервер (выполнить НА СЕРВЕРЕ):"
        echo "  mkdir -p ~/comfyui-export && scp -P $port \"root@$ip:$archive\" ~/comfyui-export/"
        echo
        echo "Распаковать на сервере (файлы проекта обновятся версией с RunPod):"
        echo "  tar xf \"\$HOME/comfyui-export/$project.tar\" -C /opt/ComfyUI"
        echo
        echo "После скачивания удалите архив на поде, он занимает место на диске:"
        echo "  rm \"$archive\""
    else
        echo "Отправить на RunPod (IP и порт: под → Connect → SSH over exposed TCP):"
        echo "  scp -P <ПОРТ> \"$archive\" root@<IP>:/workspace/"
        echo
        echo "Распаковать на поде:"
        echo "  tar xf \"/workspace/$project.tar\" -C /opt/ComfyUI && rm \"/workspace/$project.tar\""
    fi
else
    echo "Ошибка упаковки"
    rm -f "$archive"
    exit 1
fi
