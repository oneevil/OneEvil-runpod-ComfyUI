#!/bin/bash
# Download models from a list.
#   download-models               - list /workspace/models.txt (or /opt/models.txt)
#   download-models my_list.txt
#   download-models --size [list] - only calculate the size, download nothing
# Already downloaded files are skipped, interrupted downloads are resumed.

HF=/opt/ComfyUI/venv/bin/hf
PY=/opt/ComfyUI/venv/bin/python
MODELS_DIR=/opt/ComfyUI/models          # on RunPod this is a symlink to /workspace/models

SIZE_MODE=0
if [ "$1" = "--size" ]; then SIZE_MODE=1; shift; fi

LIST="$1"
if [ -z "$LIST" ]; then
    if [ -f /workspace/models.txt ]; then LIST=/workspace/models.txt; else LIST=/opt/models.txt; fi
fi
[ -f "$LIST" ] || { echo "List not found: $LIST"; exit 1; }

[ -f /etc/rp_environment ] && source /etc/rp_environment

echo "List:   $LIST"
echo "Folder: $MODELS_DIR"
[ -n "$HF_TOKEN" ] && echo "HF_TOKEN: set" || echo "HF_TOKEN: not set (gated repositories won't download)"
echo

# One download at a time: a second run (e.g. a manual one while the startup one is still going)
# waits for the first and then only fetches what is missing. The lock is local to the container,
# so it lives in /tmp rather than on the network volume.
if [ "$SIZE_MODE" = 0 ]; then
    exec 9>/tmp/download-models.lock
    if ! flock -n 9; then
        echo "Another download-models is running, waiting for it to finish..."
        flock 9
    fi
fi

ok=0; skip=0; fail=0
TMP_ROOT="$MODELS_DIR/.download-tmp"
total=0; need=0

human() { numfmt --to=iec --suffix=B --format='%.1f' "$1" 2>/dev/null || echo "$1 B"; }

# file size on Hugging Face without downloading (-1 if it couldn't be determined)
hf_size() {
    "$PY" - "$1" "$2" "$3" <<'PYEOF' 2>/dev/null || echo -1
import sys
from huggingface_hub import HfApi
repo, path, rev = sys.argv[1:4]
info = HfApi().get_paths_info(repo, [path], revision=rev)
print(info[0].size if info and getattr(info[0], "size", None) is not None else -1)
PYEOF
}

# size of a direct link from the Content-Length header
url_size() {
    local h=()
    [[ "$1" == *civitai.com* ]] && [ -n "$CIVITAI_TOKEN" ] && h=(-H "Authorization: Bearer $CIVITAI_TOKEN")
    curl -sIL "${h[@]}" "$1" | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print (v==""?-1:v)}'
}

while read -r folder source name <&3 || [ -n "$folder" ]; do
    # skip empty lines and comments
    [ -z "$folder" ] && continue
    case "$folder" in \#*) continue ;; esac

    # Detect the source. Three Hugging Face forms are supported:
    #   hf:author/repo:path/to/file
    #   hf:author/repo/path/to/file
    #   https://huggingface.co/author/repo/blob/main/path/to/file  (or /resolve/)
    kind=url; repo=""; path=""; rev="main"
    if [[ "$source" =~ ^https?://huggingface\.co/([^/]+/[^/]+)/(blob|resolve)/([^/]+)/(.+)$ ]]; then
        kind=hf
        repo="${BASH_REMATCH[1]}"
        rev="${BASH_REMATCH[3]}"
        path="${BASH_REMATCH[4]%%\?*}"
    elif [[ "$source" == hf:* ]]; then
        kind=hf
        spec="${source#hf:}"
        if [[ "$spec" == *:* ]]; then
            repo="${spec%%:*}"
            path="${spec#*:}"
        else
            repo="$(echo "$spec" | cut -d/ -f1-2)"
            path="$(echo "$spec" | cut -d/ -f3-)"
        fi
    fi

    if [ "$kind" = hf ]; then
        if [ -z "$path" ] || [[ "$repo" != */* ]]; then
            echo "! can't parse line: $folder $source"; fail=$((fail+1)); continue
        fi
        [ -z "$name" ] && name="$(basename "$path")"
    else
        url="$source"
        [ -z "$name" ] && name="$(basename "${url%%\?*}")"
    fi

    dest="$MODELS_DIR/$folder/$name"

    if [ "$SIZE_MODE" = 1 ]; then
        if [ "$kind" = hf ]; then size=$(hf_size "$repo" "$path" "$rev"); else size=$(url_size "$url"); fi
        if [ "$size" -lt 0 ] 2>/dev/null || [ -z "$size" ]; then
            printf '%10s   %s/%s\n' "?" "$folder" "$name"; fail=$((fail+1)); continue
        fi
        total=$((total+size))
        if [ -s "$dest" ] && [ ! -f "$dest.aria2" ]; then
            mark="exists"; skip=$((skip+1))
        else
            mark=""; need=$((need+size)); ok=$((ok+1))
        fi
        printf '%10s   %s/%s %s\n' "$(human "$size")" "$folder" "$name" "${mark:+  [$mark]}"
        continue
    fi
    mkdir -p "$MODELS_DIR/$folder"

    if [ -s "$dest" ] && [ ! -f "$dest.aria2" ]; then
        echo "= exists  $folder/$name"
        skip=$((skip+1)); continue
    fi

    echo "↓ fetch   $folder/$name"
    if [ "$kind" = hf ]; then
        # a separate temp folder per file, kept on failure: hf resumes the partial download from it next time
        tmp="$TMP_ROOT/$folder/$name"
        mkdir -p "$tmp"
        rev_arg=()
        [ "$rev" != "main" ] && rev_arg=(--revision "$rev")
        # the "Could not set the permissions" warning on a network disk is harmless, hide it
        if "$HF" download "$repo" "$path" "${rev_arg[@]}" --local-dir "$tmp" \
                2> >(grep -vE "Could not set the permissions|Continuing without setting permissions" >&2) \
           && [ -f "$tmp/$path" ] && mv "$tmp/$path" "$dest"; then
            ok=$((ok+1))
            rm -rf "$tmp"
        else
            echo "! error   $folder/$name"; fail=$((fail+1))
        fi
    else
        hdr=()
        if [[ "$url" == *civitai.com* ]] && [ -n "$CIVITAI_TOKEN" ]; then
            hdr=(--header="Authorization: Bearer $CIVITAI_TOKEN")
        fi
        if aria2c -x 16 -s 16 -c --console-log-level=warn --summary-interval=10 \
                "${hdr[@]}" -d "$MODELS_DIR/$folder" -o "$name" "$url"; then
            ok=$((ok+1))
        else
            echo "! error   $folder/$name"; fail=$((fail+1))
        fi
    fi
done 3< "$LIST"

echo
if [ "$SIZE_MODE" = 1 ]; then
    free=$(df -B1 --output=avail "$MODELS_DIR/" 2>/dev/null | tail -1 | tr -d ' ')
    echo "Total in list:     $(human $total)"
    echo "Left to download:  $(human $need)  ($ok files, already present: $skip)"
    [ -n "$free" ] && echo "Free disk space:   $(human $free)"
    [ "$fail" -gt 0 ] && echo "Size unknown for: $fail (check the lines marked with ?)"
    if [ -n "$free" ] && [ "$need" -gt "$free" ]; then
        echo "!!! Not enough space, need $(human $((need-free))) more"
    fi
    exit 0
fi
echo "Done: downloaded $ok, already present $skip, errors $fail"
[ "$fail" -eq 0 ]
