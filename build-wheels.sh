#!/bin/bash
# Собирает wheel-файлы на хосте для Docker-образа.
# Запускать на рабочей машине (Ubuntu 26.04, CUDA 13.2, /opt/ComfyUI/venv).
# Перезапускайте после каждого обновления torch на хосте.
set -e

OUT="$(cd "$(dirname "$0")" && pwd)/wheels"
ARCH="12.0"        # TORCH_CUDA_ARCH_LIST для SageAttention
CMAKE_ARCH="120"   # CMAKE_CUDA_ARCHITECTURES для llama.cpp
JOBS=32

source /opt/ComfyUI/venv/bin/activate
export PATH=/usr/local/cuda-13.2/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-13.2/lib64:$LD_LIBRARY_PATH

rm -rf "$OUT" && mkdir -p "$OUT"

echo "=== 1. torch: версии с хоста ==="
pip freeze | grep -E '^(torch|torchvision|torchaudio|pytorch-triton|triton)==' > "$OUT/torch-versions.txt"
cat "$OUT/torch-versions.txt"
pip download --no-deps --pre -r "$OUT/torch-versions.txt" \
    --index-url https://download.pytorch.org/whl/nightly/cu132 -d "$OUT"

echo "=== 2. SageAttention ==="
if [ ! -d /opt/SageAttention ]; then
    git clone https://github.com/thu-ml/SageAttention.git /opt/SageAttention
fi
cd /opt/SageAttention
export CXX_APPEND_FLAGS="-std=c++20" NVCC_APPEND_FLAGS="-std=c++20" \
       TORCH_CUDA_ARCH_LIST="$ARCH" MAX_JOBS="$JOBS" NVCC_THREADS=1
pip wheel . --no-build-isolation --no-deps -w "$OUT"

echo "=== 3. llama-cpp-python ==="
CMAKE_ARGS="-DGGML_CUDA=on -DCMAKE_CUDA_ARCHITECTURES=$CMAKE_ARCH -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++" \
    pip wheel llama-cpp-python --no-deps --no-cache-dir -w "$OUT"

echo "=== Готово ==="
ls -lh "$OUT"
