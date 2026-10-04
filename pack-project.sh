#!/bin/bash
# Pick a project from /opt/ComfyUI/output with the arrow keys and pack it into a tar for transfer to RunPod.
# Folders starting with VRGDG_ are hidden.
#   ↑/↓ — select, Enter — pack, q — quit

OUTPUT_DIR="${OUTPUT_DIR:-/opt/ComfyUI/output}"

# Where the script runs: in the cloud (RunPod / Vast.ai, /workspace exists) or on your own server
[ -f /etc/rp_environment ] && source /etc/rp_environment
if [ -d /workspace ]; then
    ON_POD=1
    if [ -n "$PUBLIC_IPADDR" ] || [ -n "$VAST_CONTAINERLABEL" ]; then CLOUD="Vast.ai"; else CLOUD="RunPod"; fi
    EXPORT_DIR="${EXPORT_DIR:-/workspace/export}"     # on the persistent disk
else
    ON_POD=0
    EXPORT_DIR="${EXPORT_DIR:-$HOME/comfyui-export}"
fi

[ -d "$OUTPUT_DIR" ] || { echo "Folder not found: $OUTPUT_DIR"; exit 1; }

# Projects: newest first. Glob rather than find, so symlinks work too
# (if output or project folders are links to another disk)
mapfile -t projects < <(
    for d in "$OUTPUT_DIR"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        [[ "$name" == VRGDG_* ]] && continue
        printf '%s\t%s\n' "$(stat -L -c '%Y' "$d")" "$name"
    done | sort -rn | cut -f2-
)
n=${#projects[@]}
[ "$n" -eq 0 ] && { echo "No projects found in $OUTPUT_DIR"; exit 0; }

echo "Calculating sizes..."
labels=()
for p in "${projects[@]}"; do
    size=$(du -shL "$OUTPUT_DIR/$p" 2>/dev/null | cut -f1)
    date=$(date -r "$OUTPUT_DIR/$p" '+%d.%m.%Y %H:%M')
    labels+=("$(printf '%-7s %s   %s' "$size" "$date" "$p")")
done

# ---------- menu ----------
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
    echo "Projects in $OUTPUT_DIR ($n)   ↑/↓ select, Enter pack, q quit"
    echo
    local i
    for (( i = top; i < n && i < top + rows; i++ )); do
        if (( i == sel )); then
            printf '\e[7m > %s \e[0m\n' "${labels[$i]}"
        else
            printf '   %s\n' "${labels[$i]}"
        fi
    done
    (( n > rows )) && echo && echo "   ... $(( sel + 1 )) of $n"
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
        tput cnorm; clear; echo "Cancelled"; exit 0
    fi
done

tput cnorm
clear

# ---------- packing ----------
project="${projects[$sel]}"
mkdir -p "$EXPORT_DIR"
archive="$EXPORT_DIR/$project.tar"

echo "Project: $project"
echo "Archive: $archive"
echo
echo "Packing..."

# path inside the archive: output/<project>, extracted from /opt/ComfyUI
# -h: if there are links inside, the actual files go into the archive, not the links
if tar chf "$archive" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")/$project"; then
    echo "Done: $(du -h "$archive" | cut -f1)"
    echo
    if [ "$ON_POD" = 1 ]; then
        ip="${RUNPOD_PUBLIC_IP:-${PUBLIC_IPADDR:-<IP>}}"
        port="${RUNPOD_TCP_PORT_22:-${VAST_TCP_PORT_22:-<PORT>}}"
        echo "[$CLOUD] Fetch to your server (run ON THE SERVER):"
        echo "  mkdir -p ~/comfyui-export && scp -P $port \"root@$ip:$archive\" ~/comfyui-export/"
        echo
        echo "Extract on the server (project files will be updated with the cloud version):"
        echo "  tar xf \"\$HOME/comfyui-export/$project.tar\" -C /opt/ComfyUI"
        echo
        echo "After downloading, delete the archive in the cloud, it takes up disk space:"
        echo "  rm \"$archive\""
    else
        echo "Send to RunPod / Vast.ai (IP and external SSH port from the instance panel):"
        echo "  scp -P <PORT> \"$archive\" root@<IP>:/workspace/"
        echo
        echo "Extract in the cloud:"
        echo "  tar xf \"/workspace/$project.tar\" -C /opt/ComfyUI && rm \"/workspace/$project.tar\""
    fi
else
    echo "Packing failed"
    rm -f "$archive"
    exit 1
fi
