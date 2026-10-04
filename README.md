# OneEvil-runpod-ComfyUI

**English** | [Русский](README.ru.md)

A custom ComfyUI Docker image for [RunPod](https://www.runpod.io/) with preinstalled custom nodes, SageAttention and llama-cpp-python. Built from scratch on a clean Ubuntu 26.04, without RunPod or NVIDIA base images.

Every new pod starts ready to go: nothing needs to be reinstalled, models and projects live on persistent storage.

## What's inside

| Component | Version |
|---|---|
| OS | Ubuntu 26.04 LTS |
| Python | 3.14 (system) |
| PyTorch | nightly, CUDA 13.2 (`cu132`) |
| SageAttention | built for sm_120 (Blackwell) |
| llama-cpp-python | built with CUDA for sm_120 |
| ComfyUI | latest `master` at build time |
| hf CLI, aria2 | for downloading models |

The CUDA Toolkit is not included in the image: PyTorch ships its own CUDA libraries, while SageAttention and llama-cpp-python are built ahead of time on the host and installed from prebuilt wheel files.

### Custom nodes

Installed at build time from the latest version on GitHub:

| Node | Repository |
|---|---|
| ComfyMath | [evanspearman/ComfyMath](https://github.com/evanspearman/ComfyMath) |
| Crystools MonitorOnly | [BobRandomNumber/ComfyUI-Crystools-MonitorOnly](https://github.com/BobRandomNumber/ComfyUI-Crystools-MonitorOnly) |
| LTXVideo | [Lightricks/ComfyUI-LTXVideo](https://github.com/Lightricks/ComfyUI-LTXVideo) |
| MMH3 UltimateUpscale | [bbaudio-2025/Comfyui-MMH3-UltimateUpscale](https://github.com/bbaudio-2025/Comfyui-MMH3-UltimateUpscale) |
| MiniMax H3 Latent Upscaler | [LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler](https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler) |
| MiniMax H3 Audio T8 | [T8mars/comfyui-minimax-h3-audio-T8](https://github.com/T8mars/comfyui-minimax-h3-audio-T8) |
| VRGameDevGirl (branch `Beta2.0`) | [vrgamegirl19/comfyui-vrgamedevgirl](https://github.com/vrgamegirl19/comfyui-vrgamedevgirl/tree/Beta2.0) |
| GGUF | [city96/ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) |
| Pixaroma | [pixaroma/ComfyUI-Pixaroma](https://github.com/pixaroma/ComfyUI-Pixaroma) |
| Impact Pack | [ltdrdata/ComfyUI-Impact-Pack](https://github.com/ltdrdata/ComfyUI-Impact-Pack) |
| KJNodes | [kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) |
| VideoHelperSuite | [Kosinkadink/ComfyUI-VideoHelperSuite](https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite) |
| Memory Cleanup | [LAOGOU-666/Comfyui-Memory_Cleanup](https://github.com/LAOGOU-666/Comfyui-Memory_Cleanup) |
| EulerDiscreteScheduler | [erosDiffusion/ComfyUI-EulerDiscreteScheduler](https://github.com/erosDiffusion/ComfyUI-EulerDiscreteScheduler) |

ComfyUI is launched with `--enable-manager --use-sage-attention --fast fp16_accumulation`.

## Limitations

> [!IMPORTANT]
> SageAttention and llama-cpp-python are built only for the **sm_120 (Blackwell)** architecture: RTX 5090, RTX PRO 4000/4500/6000 Blackwell. The image will not work on H100, A100, RTX 4090 or other GPUs.

> [!IMPORTANT]
> PyTorch is built for **CUDA 13.2**, the host needs NVIDIA driver **595+**. On RunPod, enable the **CUDA Version 13.2** filter when creating a pod.

## Repository layout

```
.
├── Dockerfile           # image build
├── build-and-push.sh    # everything in one command: wheels, build, test, push
├── build-wheels.sh      # builds wheel files on the host (torch, SageAttention, llama-cpp)
├── start.sh             # container startup: SSH, persistent storage, ComfyUI
├── download-models.sh   # the download-models command
├── models.txt           # default model list
├── pack-project.sh      # the pack-project command: moving projects between your server and RunPod
└── wheels/              # created by build-wheels.sh, not stored in git
```

## Building

### Build machine requirements

- Ubuntu 26.04 with system Python 3.14 (must match the image)
- NVIDIA driver 595+ and CUDA Toolkit 13.2 in `/usr/local/cuda-13.2`
- A working ComfyUI in `/opt/ComfyUI` with a venv and PyTorch nightly cu132
- Docker and NVIDIA Container Toolkit (for local GPU testing)

### One command

```bash
./build-and-push.sh            # date-based tag (2026.10.03-1530) + latest
./build-and-push.sh v2         # custom tag + latest
./build-and-push.sh --wheels   # force a rebuild of the wheel files
./build-and-push.sh --no-push  # build and test without pushing
./build-and-push.sh --cached   # don't update ComfyUI and nodes, take them from cache
```

The Docker Hub login is set at the top of the script (`DOCKERHUB_USER`) or via a variable: `DOCKERHUB_USER=login ./build-and-push.sh`. Run `docker login` before the first run.

The script:
1. compares the PyTorch version on the host with `wheels/` and rebuilds the wheel files only if they are outdated;
2. builds the image, writes the log to `build.log` and shows which ComfyUI and node versions ended up in the image;
3. tests the image on the GPU: torch, SageAttention, llama-cpp, the `hf`, `download-models` and `pack-project` commands;
4. if the test passes, pushes the image to Docker Hub with your tag and `latest`.

If the build or the test fails, nothing is pushed to Docker Hub.

The same steps done manually are below.

### 1. Build the wheel files

```bash
./build-wheels.sh
```

The script takes exactly the PyTorch version installed in `/opt/ComfyUI/venv` on the host, downloads its wheel files and compiles SageAttention and llama-cpp-python. Everything goes into `wheels/`.

> [!NOTE]
> Re-run `build-wheels.sh` after every PyTorch update on the host: SageAttention is tied to a specific torch build.

### 2. Build the image

```bash
docker build --progress=plain --build-arg CACHE_BUST=$(date +%s) -t oneevil-runpod-comfyui:test . 2>&1 | tee build.log
```

Check the log for warnings and see which node versions ended up in the image:

```bash
grep -E '^\+ |!!!' build.log
```

### 3. Test locally

```bash
docker run --rm --gpus all oneevil-runpod-comfyui:test python -c "
import torch, sageattention, llama_cpp
print(torch.__version__, torch.cuda.is_available())
print('llama gpu:', llama_cpp.llama_supports_gpu_offload())
"
```

Run ComfyUI with models and outputs from the host:

```bash
docker run --rm -it --gpus all -p 8188:8188 \
  -v /opt/ComfyUI/models:/opt/ComfyUI/models \
  -v /opt/ComfyUI/output:/opt/ComfyUI/output \
  oneevil-runpod-comfyui:test
```

The UI opens at `http://localhost:8188`. The startup script leaves folders mounted via `-v` untouched.

### 4. Publish to Docker Hub

Docker image names must be lowercase. Replace `<login>` with your Docker Hub login:

```bash
docker login
docker tag oneevil-runpod-comfyui:test <login>/oneevil-runpod-comfyui:v1
docker push <login>/oneevil-runpod-comfyui:v1
```

## RunPod setup

### Template (Templates → New Template)

| Setting | Value |
|---|---|
| Container Image | `<login>/oneevil-runpod-comfyui:v1` |
| Container Disk | 30–40 GB |
| Volume Disk | 100–200 GB (if no Network Volume) |
| Volume Mount Path | `/workspace` (don't change) |
| Expose HTTP Ports | `8188` |
| Expose TCP Ports | `22` |

### Environment variables

| Variable | Value | Purpose |
|---|---|---|
| `HF_TOKEN` | `{{ RUNPOD_SECRET_HF_TOKEN }}` | Hugging Face token for gated models |
| `CIVITAI_TOKEN` | `{{ RUNPOD_SECRET_CIVITAI_TOKEN }}` | Civitai token (optional) |
| `DOWNLOAD_MODELS` | `1` | download models from the list on startup (optional) |
| `SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA...` | your public SSH key (recommended, see below) |

Tokens are created under **Secrets** and inserted into the template via the key icon.

### SSH

The `ssh.runpod.io` proxy always works, but it can't transfer files. `scp` and `pack-project` need direct SSH by IP and port (**SSH over exposed TCP**), which requires sshd running inside the container. `start.sh` starts it if it receives your public key.

Create a key if you don't have one:

```bash
ssh-keygen -t ed25519 -C "runpod"
cat ~/.ssh/id_ed25519.pub
```

There are two ways to pass the key to the container:

1. **`SSH_PUBLIC_KEY` variable in the template** (more reliable): paste the whole line from `id_ed25519.pub` as the value. The key is public, so storing it in the template is safe.
2. **Key in the account** (**Settings → SSH Public Keys**): RunPod passes it in the `PUBLIC_KEY` variable, but only to pods created after the key was added, and only if the **SSH Terminal Access** checkbox is enabled when launching the pod.

If both variables are set, `PUBLIC_KEY` is used.

To verify it works: the pod log (**Logs**) should contain the line `SSH: sshd started on port 22`. If you see `!!! SSH: no public key provided` instead, the key didn't reach the container. You can check which variables the container received via the `ssh.runpod.io` proxy:

```bash
cat /proc/1/environ | tr '\0' '\n' | grep -E '^(PUBLIC_KEY|SSH_PUBLIC_KEY)='
```

Connecting: pod → **Connect** → **SSH over exposed TCP**:

```bash
ssh root@<ip> -p <port>
```

If ComfyUI isn't reachable through the RunPod proxy, you can always open it via an SSH tunnel:

```bash
ssh -N -L 8188:127.0.0.1:8188 root@<ip> -p <port>
# then http://localhost:8188
```

## Persistent storage

When running on RunPod, `start.sh` moves the ComfyUI folders to `/workspace`:

| In ComfyUI | On disk |
|---|---|
| `/opt/ComfyUI/models` | `/workspace/models` |
| `/opt/ComfyUI/output` | `/workspace/output` |
| `/opt/ComfyUI/input` | `/workspace/input` |
| `/opt/ComfyUI/user` | `/workspace/user` (workflows and settings) |

With a **Network Volume**, data lives independently of the pod and survives its deletion. Without one, `/workspace` is the pod's Volume Disk: data is kept when the pod is stopped but deleted together with the pod.

> [!TIP]
> A Network Volume is tied to a data center. Pick one that has Blackwell GPUs with CUDA 13.2. It's convenient to download models on the cheapest pod (even a CPU one) with this volume attached, and then launch a GPU pod.

## Models: `download-models`

The model list lives in `/workspace/models.txt` (copied from the image on first start) and can be edited right on the pod without rebuilding.

Line format: `<folder in models> <source> [file name]`

```
# Hugging Face: hf:<repository>:<path to file>
diffusion_models  hf:Comfy-Org/MiniMax-H3:diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors

# Direct link (for Civitai the file name is required)
loras             https://civitai.com/api/download/models/123456   my_lora.safetensors
```

For Hugging Face any of these forms works: `hf:author/repo:path/file`, `hf:author/repo/path/file`, or just a browser link `https://huggingface.co/author/repo/blob/main/path/file`.

```bash
nano /workspace/models.txt
download-models
```

Already downloaded files are skipped, interrupted downloads are resumed. With `DOWNLOAD_MODELS=1` the download runs in the background on startup, logging to `/workspace/download-models.log`:

```bash
tail -f /workspace/download-models.log
```

## Projects: `pack-project`

Moves projects from `/opt/ComfyUI/output/<project>` between your own server and RunPod. The script lists projects (`VRGDG_*` folders are hidden), you pick one with ↑/↓, Enter packs it into a `.tar`. It works the same on the server and on the pod and prints the next commands to run.

Installing on the server:

```bash
cp pack-project.sh /usr/local/bin/pack-project
chmod +x /usr/local/bin/pack-project
```

### Server → RunPod

```bash
# on the server
pack-project
scp -P <port> ~/comfyui-export/<project>.tar root@<ip>:/workspace/

# on the pod
tar xf /workspace/<project>.tar -C /opt/ComfyUI && rm /workspace/<project>.tar
```

### RunPod → server

```bash
# on the pod (the script prints a ready-made scp command with the pod's IP and port)
pack-project

# on the server
mkdir -p ~/comfyui-export && scp -P <port> root@<ip>:/workspace/export/<project>.tar ~/comfyui-export/
tar xf ~/comfyui-export/<project>.tar -C /opt/ComfyUI
```

> [!WARNING]
> Extracting on the server overwrites the project files with the RunPod version. After downloading, delete the archive on the pod so it doesn't take up space.

## Changing the node set

Nodes are listed in the `Dockerfile` in the "PHASE 5" block:

```dockerfile
node https://github.com/author/repository.git   folder-name   [branch]; \
```

The branch is optional; without it the default branch is used. Dependencies of all nodes are installed automatically, while the PyTorch version is pinned via `constraints.txt`, so no node can replace it.

## Updating

The `Dockerfile` layers are split into two parts. The lower part (Ubuntu, torch, SageAttention, llama-cpp) comes from the Docker cache and is rebuilt only if the wheel files changed. The upper part (ComfyUI and all nodes) is rebuilt on every `build-and-push.sh` run: the script passes `CACHE_BUST` with the current time, so ComfyUI and the nodes are pulled fresh from GitHub.

| What changed | What to do |
|---|---|
| ComfyUI or nodes | `./build-and-push.sh v2`, they are pulled fresh automatically |
| PyTorch on the host | `./build-and-push.sh v2`, the script detects it and rebuilds the wheel files |
| Node list | edit the `Dockerfile`, then `./build-and-push.sh v2` |
| Model list | edit `/workspace/models.txt` on the pod, no rebuild needed |

After building, change the tag in the RunPod template to the new one and restart the pod.

> [!NOTE]
> Updates made through ComfyUI Manager on the pod are written into the container and are lost on restart. To update ComfyUI and nodes permanently, rebuild the image.
