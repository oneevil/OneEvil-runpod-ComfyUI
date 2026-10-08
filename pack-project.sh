#!/bin/bash
# Moving projects from /opt/ComfyUI/output between your server and RunPod / Vast.ai.
#   pack-project                 - pick a project with the arrow keys and pack it into a tar
#                                  (↑/↓ — select, Enter — pack, q — quit; folders VRGDG_* are hidden)
#   pack-project <project>.tar   - unpack an archive made by pack-project into output

OUTPUT_DIR="${OUTPUT_DIR:-/opt/ComfyUI/output}"

# Where the script runs: in the cloud or on your own server. Detected by the platform variables
# (start.sh saves them to /etc/rp_environment), not by /workspace, which a server may have too
[ -f /etc/rp_environment ] && source /etc/rp_environment
CLOUD=""
if [ -n "$RUNPOD_POD_ID" ]; then
    CLOUD="RunPod"
elif [ -n "$PUBLIC_IPADDR" ] || [ -n "$VAST_CONTAINERLABEL" ]; then
    CLOUD="Vast.ai"
fi
if [ -n "$CLOUD" ]; then
    ON_POD=1
    EXPORT_DIR="${EXPORT_DIR:-/workspace/export}"     # on the persistent disk
else
    ON_POD=0
    EXPORT_DIR="${EXPORT_DIR:-$HOME/comfyui-export}"
fi

[ -d "$OUTPUT_DIR" ] || { echo "Folder not found: $OUTPUT_DIR"; exit 1; }

# ---------- unpacking ----------
if [ -n "$1" ]; then
    archive="$1"
    [ -f "$archive" ] || { echo "Archive not found: $archive"; exit 1; }
    project="$(tar tf "$archive" 2>/dev/null | head -1 | cut -d/ -f2)"
    [ -n "$project" ] || { echo "Not a pack-project archive: $archive"; exit 1; }

    # Paths inside the archive are output/<project>. Extract with --strip-components=1 straight into
    # the real output folder: newer GNU tar refuses to write through a symlink that leads outside -C
    # ("Invalid cross-device link"), and on the pod /opt/ComfyUI/output is a link to /workspace/output
    dest="$(readlink -f "$OUTPUT_DIR")"
    echo "Archive: $archive"
    echo "Project: $dest/$project"
    echo
    echo "Unpacking..."

    # The network volume forbids chown/chmod/utime even for root: tar doesn't restore them where it can
    # be told not to, and complains about directory modes anyway. The data is extracted by then,
    # so those messages are filtered out and only real errors count.
    errlog="$(mktemp)"
    tar xf "$archive" --strip-components=1 --no-same-owner --no-same-permissions -m -C "$dest" 2> "$errlog"
    rc=$?
    errors="$(grep -vE 'Cannot (change mode|change ownership|utime)|Exiting with failure status due to previous errors' "$errlog")"
    # a failure counts as harmless only if tar explained it and every message is about metadata
    if [ "$rc" -ne 0 ] && { [ -n "$errors" ] || [ ! -s "$errlog" ]; }; then
        rm -f "$errlog"
        [ -n "$errors" ] && echo "$errors"
        echo
        echo "Unpacking failed, the archive is kept: $archive"
        exit 1
    fi
    rm -f "$errlog"

    echo "Done: $(du -sh "$dest/$project" 2>/dev/null | cut -f1)"
    if [ "$ON_POD" = 1 ]; then
        rm -f "$archive" && echo "Archive removed to free disk space"
    else
        echo "Remove the archive if you no longer need it:  rm \"$archive\""
    fi
    exit 0
fi

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

# the menu needs a terminal: without one `read` gets EOF, which looks like Enter and packs the first project
[ -t 0 ] || { echo "Interactive terminal required (use ssh -t)"; exit 1; }

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

# path inside the archive: output/<project>; `pack-project <archive>` unpacks it
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
        echo "Unpack on the server (project files will be updated with the cloud version):"
        echo "  pack-project \"\$HOME/comfyui-export/$project.tar\""
        echo
        echo "After downloading, delete the archive in the cloud, it takes up disk space:"
        echo "  rm \"$archive\""
    else
        echo "Send to RunPod / Vast.ai (IP and external SSH port from the instance panel):"
        echo "  scp -P <PORT> \"$archive\" root@<IP>:/workspace/"
        echo
        echo "Unpack in the cloud (the archive is removed afterwards):"
        echo "  pack-project \"/workspace/$project.tar\""
    fi
else
    echo "Packing failed"
    rm -f "$archive"
    exit 1
fi
