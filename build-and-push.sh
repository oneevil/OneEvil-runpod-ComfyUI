#!/bin/bash
# Full build of OneEvil-runpod-ComfyUI and publishing to Docker Hub.
#
#   ./build-and-push.sh              - date-based tag (e.g. 2026.10.03-1530) + latest
#   ./build-and-push.sh v2           - custom tag + latest
#   ./build-and-push.sh v2 --wheels  - force a rebuild of the wheel files
#   ./build-and-push.sh --no-push    - only build and test, don't push
#   ./build-and-push.sh --cached     - don't update ComfyUI and nodes (take them from cache)
#
# By default ComfyUI and all nodes are pulled fresh from GitHub on every build,
# while torch, SageAttention and llama-cpp come from cache (if the wheel files haven't changed).
#
# The Docker Hub login can be set here or via a variable: DOCKERHUB_USER=login ./build-and-push.sh
set -e

DOCKERHUB_USER="${DOCKERHUB_USER:-oneevil}"
IMAGE_NAME="oneevil-runpod-comfyui"
HOST_VENV="/opt/ComfyUI/venv"

# ---------- arguments ----------
TAG=""
FORCE_WHEELS=0
PUSH=1
CACHED=0
CACHE_BUST="$(date +%s)"
for arg in "$@"; do
    case "$arg" in
        --wheels)  FORCE_WHEELS=1 ;;
        --no-push) PUSH=0 ;;
        --cached)  CACHED=1; CACHE_BUST="$(cat "$(dirname "$0")/.last-cache-bust" 2>/dev/null || echo 0)" ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        -*)        echo "Unknown option: $arg"; exit 1 ;;
        *)         TAG="$arg" ;;
    esac
done
[ -z "$TAG" ] && TAG="$(date '+%Y.%m.%d-%H%M')"

cd "$(dirname "$0")"
REPO="$DOCKERHUB_USER/$IMAGE_NAME"
LOCAL="$IMAGE_NAME:build"
START=$(date +%s)

step() { echo; echo "=================== $* ==================="; }
fail() { echo; echo "!!! $*"; exit 1; }

echo "Image:  $REPO:$TAG (+ latest)"
[ "$PUSH" = 0 ] && echo "Mode:   no push to Docker Hub"

# ---------- checks ----------
for f in Dockerfile start.sh build-wheels.sh download-models.sh models.txt pack-project.sh; do
    [ -f "$f" ] || fail "Missing file $f"
done
command -v docker >/dev/null || fail "Docker is not installed"

if [ "$PUSH" = 1 ] && ! grep -q 'index.docker.io' ~/.docker/config.json 2>/dev/null; then
    fail "Not logged in to Docker Hub. Run: docker login"
fi

# ---------- 1. wheel files ----------
step "1/4 Wheel files"
host_torch="$("$HOST_VENV/bin/pip" freeze 2>/dev/null | grep -E '^torch==' || true)"
wheels_torch="$(grep -E '^torch==' wheels/torch-versions.txt 2>/dev/null || true)"
echo "torch on host:    ${host_torch:-not found}"
echo "torch in wheels/: ${wheels_torch:-none}"

if [ "$FORCE_WHEELS" = 1 ]; then
    echo "Rebuilding because of --wheels"
    ./build-wheels.sh
elif [ -z "$wheels_torch" ] || [ "$host_torch" != "$wheels_torch" ]; then
    echo "Wheel files are missing or outdated, rebuilding"
    ./build-wheels.sh
elif ! ls wheels/sageattention-*.whl wheels/llama_cpp_python-*.whl >/dev/null 2>&1; then
    echo "SageAttention or llama-cpp is missing, rebuilding"
    ./build-wheels.sh
else
    echo "Up to date, skipping"
fi

# ---------- 2. image build ----------
step "2/4 Building image"
[ "$CACHED" = 1 ] && echo "ComfyUI and nodes: from cache (--cached)" || echo "ComfyUI and nodes: fresh from GitHub"
docker build --progress=plain --build-arg CACHE_BUST="$CACHE_BUST" -t "$LOCAL" . 2>&1 | tee build.log
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "Build failed, see build.log"
echo "$CACHE_BUST" > .last-cache-bust     # so that --cached reuses this same cache next time

# take only command output from the log (#N 1.234 ...), not the Dockerfile text itself
log_out() { grep -E "^#[0-9]+ [0-9]+\.[0-9]+ $1" build.log | sed -E 's/^#[0-9]+ [0-9.]+ /  /'; }
echo
echo "Versions in the image:"
log_out '\+ ' || true
if grep -qE '^#[0-9]+ [0-9]+\.[0-9]+ !!!' build.log; then
    echo
    echo "Warnings:"
    log_out '!!!'
fi

# ---------- 3. test ----------
step "3/4 Testing"
if ! docker run --rm --gpus all "$LOCAL" python -c "
import torch, sageattention, llama_cpp
assert torch.cuda.is_available(), 'CUDA is not available'
assert llama_cpp.llama_supports_gpu_offload(), 'llama-cpp has no GPU support'
print('torch      ', torch.__version__)
print('GPU        ', torch.cuda.get_device_name(0))
print('llama gpu   OK')
"; then
    fail "Test failed, image not pushed"
fi

docker run --rm "$LOCAL" bash -c 'command -v hf >/dev/null && command -v download-models >/dev/null && command -v pack-project >/dev/null' \
    || fail "hf, download-models or pack-project is missing in the image"
echo "hf, download-models, pack-project: OK"

# ---------- 4. push ----------
docker tag "$LOCAL" "$REPO:$TAG"
docker tag "$LOCAL" "$REPO:latest"

if [ "$PUSH" = 1 ]; then
    step "4/4 Pushing to Docker Hub"
    docker push "$REPO:$TAG"
    docker push "$REPO:latest"
else
    step "4/4 Push skipped (--no-push)"
fi

# ---------- summary ----------
mins=$(( ($(date +%s) - START) / 60 ))
echo
echo "Done in $mins min."
echo "  $REPO:$TAG"
echo "  $REPO:latest"
[ "$PUSH" = 1 ] && echo && echo "For the RunPod / Vast template (Container Image):  $REPO:$TAG"
echo
echo "Clean up old layers if needed:  docker image prune -f && docker builder prune -f"
