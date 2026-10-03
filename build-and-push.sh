#!/bin/bash
# Полная сборка OneEvil-runpod-ComfyUI и публикация в Docker Hub.
#
#   ./build-and-push.sh              - тег по дате (например 2026.10.03-1530) + latest
#   ./build-and-push.sh v2           - свой тег + latest
#   ./build-and-push.sh v2 --wheels  - принудительно пересобрать wheel-файлы
#   ./build-and-push.sh --no-push    - только собрать и проверить, без отправки
#
# Логин Docker Hub можно задать здесь или переменной: DOCKERHUB_USER=login ./build-and-push.sh
set -e

DOCKERHUB_USER="${DOCKERHUB_USER:-oneevil}"
IMAGE_NAME="oneevil-runpod-comfyui"
HOST_VENV="/opt/ComfyUI/venv"

# ---------- параметры ----------
TAG=""
FORCE_WHEELS=0
PUSH=1
for arg in "$@"; do
    case "$arg" in
        --wheels)  FORCE_WHEELS=1 ;;
        --no-push) PUSH=0 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        -*)        echo "Неизвестный параметр: $arg"; exit 1 ;;
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

echo "Образ:  $REPO:$TAG (+ latest)"
[ "$PUSH" = 0 ] && echo "Режим:  без отправки в Docker Hub"

# ---------- проверки ----------
for f in Dockerfile start.sh build-wheels.sh download-models.sh models.txt pack-project.sh; do
    [ -f "$f" ] || fail "Нет файла $f"
done
command -v docker >/dev/null || fail "Docker не установлен"

if [ "$PUSH" = 1 ] && ! grep -q 'index.docker.io' ~/.docker/config.json 2>/dev/null; then
    fail "Нет входа в Docker Hub. Выполните: docker login"
fi

# ---------- 1. wheel-файлы ----------
step "1/4 Wheel-файлы"
host_torch="$("$HOST_VENV/bin/pip" freeze 2>/dev/null | grep -E '^torch==' || true)"
wheels_torch="$(grep -E '^torch==' wheels/torch-versions.txt 2>/dev/null || true)"
echo "torch на хосте:  ${host_torch:-не найден}"
echo "torch в wheels/: ${wheels_torch:-нет}"

if [ "$FORCE_WHEELS" = 1 ]; then
    echo "Пересборка по флагу --wheels"
    ./build-wheels.sh
elif [ -z "$wheels_torch" ] || [ "$host_torch" != "$wheels_torch" ]; then
    echo "Wheel-файлы отсутствуют или устарели, пересобираю"
    ./build-wheels.sh
elif ! ls wheels/sageattention-*.whl wheels/llama_cpp_python-*.whl >/dev/null 2>&1; then
    echo "Не хватает SageAttention или llama-cpp, пересобираю"
    ./build-wheels.sh
else
    echo "Актуальны, пропускаю"
fi

# ---------- 2. сборка образа ----------
step "2/4 Сборка образа"
docker build --progress=plain -t "$LOCAL" . 2>&1 | tee build.log
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "Сборка не удалась, смотрите build.log"

# в логе берём только вывод команд (#N 1.234 ...), а не текст самого Dockerfile
log_out() { grep -E "^#[0-9]+ [0-9]+\.[0-9]+ $1" build.log | sed -E 's/^#[0-9]+ [0-9.]+ /  /'; }
echo
echo "Ноды в образе:"
log_out '\+ ' || true
if grep -qE '^#[0-9]+ [0-9]+\.[0-9]+ !!!' build.log; then
    echo
    echo "Предупреждения:"
    log_out '!!!'
fi

# ---------- 3. проверка ----------
step "3/4 Проверка"
if ! docker run --rm --gpus all "$LOCAL" python -c "
import torch, sageattention, llama_cpp
assert torch.cuda.is_available(), 'CUDA недоступна'
assert llama_cpp.llama_supports_gpu_offload(), 'llama-cpp без GPU'
print('torch      ', torch.__version__)
print('GPU        ', torch.cuda.get_device_name(0))
print('llama gpu   OK')
"; then
    fail "Проверка не прошла, образ не отправлен"
fi

docker run --rm "$LOCAL" bash -c 'command -v hf >/dev/null && command -v download-models >/dev/null && command -v pack-project >/dev/null' \
    || fail "В образе нет hf, download-models или pack-project"
echo "hf, download-models, pack-project: OK"

# ---------- 4. отправка ----------
docker tag "$LOCAL" "$REPO:$TAG"
docker tag "$LOCAL" "$REPO:latest"

if [ "$PUSH" = 1 ]; then
    step "4/4 Отправка в Docker Hub"
    docker push "$REPO:$TAG"
    docker push "$REPO:latest"
else
    step "4/4 Отправка пропущена (--no-push)"
fi

# ---------- итог ----------
mins=$(( ($(date +%s) - START) / 60 ))
echo
echo "Готово за $mins мин."
echo "  $REPO:$TAG"
echo "  $REPO:latest"
[ "$PUSH" = 1 ] && echo && echo "Для шаблона RunPod (Container Image):  $REPO:$TAG"
echo
echo "Почистить старые слои при необходимости:  docker image prune -f && docker builder prune -f"
