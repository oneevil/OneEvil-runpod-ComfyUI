# OneEvil-runpod-ComfyUI

[English](README.md) | **Русский**

Свой Docker-образ ComfyUI для [RunPod](https://www.runpod.io/) с предустановленными кастомными нодами, SageAttention и llama-cpp-python. Собран с нуля на чистой Ubuntu 26.04, без базовых образов RunPod и NVIDIA.

Каждый новый под стартует сразу готовым: ничего не нужно ставить заново, модели и проекты лежат на постоянном диске.

## Что внутри

| Компонент | Версия |
|---|---|
| ОС | Ubuntu 26.04 LTS |
| Python | 3.14 (системный) |
| PyTorch | nightly, CUDA 13.4 (`cu134`) |
| SageAttention | собран под sm_120 (Blackwell) |
| llama-cpp-python | собран с CUDA под sm_120 |
| ComfyUI | последняя версия из `master` при сборке |
| hf CLI, aria2 | для скачивания моделей |

CUDA Toolkit в образ не входит: PyTorch несёт свои библиотеки CUDA, а SageAttention и llama-cpp-python собираются заранее на хосте и ставятся из готовых wheel-файлов.

### Кастомные ноды

Ставятся при сборке в последней версии из GitHub:

| Нода | Репозиторий |
|---|---|
| ComfyMath | [evanspearman/ComfyMath](https://github.com/evanspearman/ComfyMath) |
| Crystools MonitorOnly | [BobRandomNumber/ComfyUI-Crystools-MonitorOnly](https://github.com/BobRandomNumber/ComfyUI-Crystools-MonitorOnly) |
| LTXVideo | [Lightricks/ComfyUI-LTXVideo](https://github.com/Lightricks/ComfyUI-LTXVideo) |
| MMH3 UltimateUpscale | [bbaudio-2025/Comfyui-MMH3-UltimateUpscale](https://github.com/bbaudio-2025/Comfyui-MMH3-UltimateUpscale) |
| MiniMax H3 Latent Upscaler | [LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler](https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler) |
| MiniMax H3 Audio T8 | [T8mars/comfyui-minimax-h3-audio-T8](https://github.com/T8mars/comfyui-minimax-h3-audio-T8) |
| VRGameDevGirl (ветка `Beta2.0`) | [vrgamegirl19/comfyui-vrgamedevgirl](https://github.com/vrgamegirl19/comfyui-vrgamedevgirl/tree/Beta2.0) |
| GGUF | [city96/ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) |
| Pixaroma | [pixaroma/ComfyUI-Pixaroma](https://github.com/pixaroma/ComfyUI-Pixaroma) |
| Impact Pack | [ltdrdata/ComfyUI-Impact-Pack](https://github.com/ltdrdata/ComfyUI-Impact-Pack) |
| KJNodes | [kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) |
| VideoHelperSuite | [Kosinkadink/ComfyUI-VideoHelperSuite](https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite) |
| Memory Cleanup | [LAOGOU-666/Comfyui-Memory_Cleanup](https://github.com/LAOGOU-666/Comfyui-Memory_Cleanup) |
| EulerDiscreteScheduler | [erosDiffusion/ComfyUI-EulerDiscreteScheduler](https://github.com/erosDiffusion/ComfyUI-EulerDiscreteScheduler) |

ComfyUI запускается с параметрами `--enable-manager --use-sage-attention --fast fp16_accumulation`.

## Ограничения

> [!IMPORTANT]
> SageAttention и llama-cpp-python собраны только под архитектуру **sm_120 (Blackwell)**: RTX 5090, RTX PRO 4000/4500/6000 Blackwell. На H100, A100, RTX 4090 и других картах образ работать не будет.

> [!IMPORTANT]
> PyTorch собран под **CUDA 13.4**, на хосте нужен драйвер NVIDIA **615+**. На RunPod при создании пода включайте фильтр **CUDA Version 13.4**.

## Структура репозитория

```
.
├── Dockerfile           # сборка образа
├── build-and-push.sh    # всё одной командой: wheels, сборка, проверка, push
├── build-wheels.sh      # сборка wheel-файлов на хосте (torch, SageAttention, llama-cpp)
├── start.sh             # запуск контейнера: SSH, постоянное хранилище, ComfyUI
├── download-models.sh   # команда download-models
├── models.txt           # список моделей по умолчанию
├── pack-project.sh      # команда pack-project: перенос проектов между сервером и RunPod
├── fs_compat.py         # патч Python: копирование файлов в нодах работает на сетевом томе
└── wheels/              # создаётся build-wheels.sh, в git не хранится
```

## Сборка

### Требования к машине для сборки

- Ubuntu 26.04 с системным Python 3.14 (должен совпадать с образом)
- Драйвер NVIDIA 615+ и CUDA Toolkit 13.4 в `/usr/local/cuda-13.4`
- clang (`apt install clang`): им компилируется llama-cpp-python
- Рабочий ComfyUI в `/opt/ComfyUI` с venv и PyTorch nightly cu134
- Docker и NVIDIA Container Toolkit (для локального теста с GPU)

### Одной командой

```bash
./build-and-push.sh            # тег по дате (2026.10.03-1530) + latest
./build-and-push.sh v2         # свой тег + latest
./build-and-push.sh --wheels   # принудительно пересобрать wheel-файлы
./build-and-push.sh --no-push  # собрать и проверить без отправки
./build-and-push.sh --cached   # не обновлять ComfyUI и ноды, взять из кэша
```

Логин Docker Hub задаётся в начале скрипта (`DOCKERHUB_USER`) или переменной: `DOCKERHUB_USER=login ./build-and-push.sh`. Перед первым запуском выполните `docker login`.

Скрипт сам:
1. сравнивает версию PyTorch на хосте с `wheels/` и пересобирает wheel-файлы, только если они устарели;
2. собирает образ, лог пишет в `build.log` и показывает, какие версии ComfyUI и нод попали в образ;
3. проверяет образ на GPU: torch, SageAttention, llama-cpp, команды `hf`, `download-models`, `pack-project`;
4. если проверка прошла, отправляет образ в Docker Hub с вашим тегом и `latest`.

Если сборка или проверка не прошли, в Docker Hub ничего не уйдёт.

Ниже те же шаги вручную.

### 1. Собрать wheel-файлы

```bash
./build-wheels.sh
```

Скрипт берёт из `/opt/ComfyUI/venv` ровно ту версию PyTorch, что стоит на хосте, скачивает её wheel-файлы и компилирует SageAttention и llama-cpp-python. Всё складывается в `wheels/`.

> [!NOTE]
> После каждого обновления PyTorch на хосте запускайте `build-wheels.sh` заново: SageAttention привязан к конкретной сборке torch.

### 2. Собрать образ

```bash
docker build --progress=plain --build-arg CACHE_BUST=$(date +%s) -t oneevil-runpod-comfyui:test . 2>&1 | tee build.log
```

Проверить лог на предупреждения и посмотреть, какие версии нод попали в образ:

```bash
grep -E '^\+ |!!!' build.log
```

### 3. Проверить локально

```bash
docker run --rm --gpus all oneevil-runpod-comfyui:test python -c "
import torch, sageattention, llama_cpp
print(torch.__version__, torch.cuda.is_available())
print('llama gpu:', llama_cpp.llama_supports_gpu_offload())
"
```

Запустить ComfyUI с моделями и результатами с хоста:

```bash
docker run --rm -it --gpus all -p 8188:8188 \
  -v /opt/ComfyUI/models:/opt/ComfyUI/models \
  -v /opt/ComfyUI/output:/opt/ComfyUI/output \
  oneevil-runpod-comfyui:test
```

Интерфейс откроется на `http://localhost:8188`. Папки, подключённые через `-v`, скрипт запуска не трогает.

### 4. Опубликовать в Docker Hub

Имя образа в Docker должно быть в нижнем регистре. Замените `<login>` на свой логин Docker Hub:

```bash
docker login
docker tag oneevil-runpod-comfyui:test <login>/oneevil-runpod-comfyui:v1
docker push <login>/oneevil-runpod-comfyui:v1
```

## Настройка RunPod

### Шаблон (Templates → New Template)

| Параметр | Значение |
|---|---|
| Container Image | `<login>/oneevil-runpod-comfyui:v1` |
| Container Disk | 30–40 ГБ |
| Volume Disk | 100–200 ГБ (если без Network Volume) |
| Volume Mount Path | `/workspace` (не менять) |
| Expose HTTP Ports | `8188` |
| Expose TCP Ports | `22` |

### Переменные окружения

| Переменная | Значение | Назначение |
|---|---|---|
| `HF_TOKEN` | `{{ RUNPOD_SECRET_HF_TOKEN }}` | токен Hugging Face для закрытых моделей |
| `CIVITAI_TOKEN` | `{{ RUNPOD_SECRET_CIVITAI_TOKEN }}` | токен Civitai (необязательно) |
| `DOWNLOAD_MODELS` | `1` | качать модели из списка при старте (необязательно) |
| `SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA...` | ваш публичный SSH-ключ (рекомендуется, см. ниже) |

Токены создаются в **Secrets**, в шаблон подставляются через иконку ключа.

### SSH

Прокси `ssh.runpod.io` работает всегда, но не умеет передавать файлы. Для `scp` и `pack-project` нужен прямой SSH по IP и порту (**SSH over exposed TCP**), а для него внутри контейнера должен работать sshd. Его запускает `start.sh`, если получил ваш публичный ключ.

Создать ключ, если его нет:

```bash
ssh-keygen -t ed25519 -C "runpod"
cat ~/.ssh/id_ed25519.pub
```

Передать ключ в контейнер можно двумя способами:

1. **Переменная `SSH_PUBLIC_KEY` в шаблоне** (надёжнее): вставьте в значение всю строку из `id_ed25519.pub`. Ключ публичный, хранить его в шаблоне безопасно.
2. **Ключ в аккаунте** (**Settings → SSH Public Keys**): RunPod передаёт его в переменной `PUBLIC_KEY`, но только в поды, созданные после добавления ключа, и только если при запуске пода отмечена галочка **SSH Terminal Access**.

Если заданы обе переменные, используется `PUBLIC_KEY`.

Проверить, что всё работает: в логе пода (**Logs**) должна быть строка `SSH: sshd started on port 22`. Если вместо неё `!!! SSH: no public key provided`, ключ до контейнера не дошёл. Посмотреть, какие переменные получил контейнер, можно через прокси `ssh.runpod.io`:

```bash
cat /proc/1/environ | tr '\0' '\n' | grep -E '^(PUBLIC_KEY|SSH_PUBLIC_KEY)='
```

Подключение: под → **Connect** → **SSH over exposed TCP**:

```bash
ssh root@<ip> -p <порт>
```

Если ComfyUI недоступен через прокси RunPod, его всегда можно открыть через SSH-туннель:

```bash
ssh -N -L 8188:127.0.0.1:8188 root@<ip> -p <порт>
# затем http://localhost:8188
```

## Постоянное хранилище

При запуске на RunPod `start.sh` переносит папки ComfyUI в `/workspace`:

| В ComfyUI | На диске |
|---|---|
| `/opt/ComfyUI/models` | `/workspace/models` |
| `/opt/ComfyUI/output` | `/workspace/output` |
| `/opt/ComfyUI/input` | `/workspace/input` |
| `/opt/ComfyUI/user` | `/workspace/user` (workflow и настройки) |

С **Network Volume** данные живут независимо от пода и переживают его удаление. Без него `/workspace` — это Volume Disk пода: данные сохраняются при остановке, но удаляются вместе с подом.

Network Volume не разрешает менять права и время файлов даже root. Из-за этого `shutil.copy2` в нодах падал бы с ошибкой `[Errno 1] Operation not permitted`, когда данные уже скопированы. В образе есть `fs_compat.py`: он заставляет Python пропускать копирование этих атрибутов, если диск его запрещает, а сами файлы копируются как обычно.

> [!TIP]
> Network Volume привязан к дата-центру. Выбирайте тот, где есть Blackwell-карты с CUDA 13.4. Модели удобно качать на самом дешёвом поде (даже CPU) с этим volume, а потом запускать GPU-под.

## Модели: `download-models`

Список моделей лежит в `/workspace/models.txt` (при первом запуске копируется из образа), его можно править прямо на поде без пересборки.

Формат строки: `<папка в models> <источник> [имя файла]`

```
# Hugging Face: hf:<репозиторий>:<путь к файлу>
diffusion_models  hf:Comfy-Org/MiniMax-H3:diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors

# Прямая ссылка (для Civitai имя файла обязательно)
loras             https://civitai.com/api/download/models/123456   my_lora.safetensors
```

Для Hugging Face подходит любая запись: `hf:автор/репо:путь/файл`, `hf:автор/репо/путь/файл` или просто ссылка из браузера `https://huggingface.co/автор/репо/blob/main/путь/файл`.

```bash
nano /workspace/models.txt
download-models
```

Уже скачанные файлы пропускаются, оборванные закачки продолжаются (недокачанные файлы с Hugging Face хранятся в `models/.download-tmp`). Одновременно работает только один `download-models`: если запустить его, пока идёт скачивание при старте, он дождётся окончания и докачает только недостающее. При `DOWNLOAD_MODELS=1` скачивание идёт в фоне при старте, лог в `/workspace/download-models.log`:

```bash
tail -f /workspace/download-models.log
```

## Проекты: `pack-project`

Перенос проектов из `/opt/ComfyUI/output/<проект>` между своим сервером и RunPod. Скрипт показывает список проектов (папки `VRGDG_*` скрыты), выбор стрелками ↑/↓, Enter упаковывает в `.tar`. `pack-project <проект>.tar` распаковывает архив в output. Работает одинаково на сервере и на поде и сам подсказывает следующие команды.

При распаковке на поде tar не может выставить права и время файлов на сетевом томе и сообщает об этом; скрипт отфильтровывает эти безвредные сообщения и показывает только настоящие ошибки. На поде архив удаляется после успешной распаковки, на сервере остаётся.

Установка на сервер:

```bash
cp pack-project.sh /usr/local/bin/pack-project
chmod +x /usr/local/bin/pack-project
```

### Сервер → RunPod

```bash
# на сервере
pack-project
scp -P <порт> ~/comfyui-export/<проект>.tar root@<ip>:/workspace/

# на поде
pack-project /workspace/<проект>.tar
```

### RunPod → сервер

```bash
# на поде (скрипт выведет готовую команду scp с IP и портом пода)
pack-project

# на сервере
mkdir -p ~/comfyui-export && scp -P <порт> root@<ip>:/workspace/export/<проект>.tar ~/comfyui-export/
pack-project ~/comfyui-export/<проект>.tar
```

> [!WARNING]
> Распаковка на сервере перезаписывает файлы проекта версией с RunPod. После скачивания удалите архив на поде, чтобы не занимать место.

## Изменение набора нод

Ноды перечислены в `Dockerfile` в блоке «PHASE 5»:

```dockerfile
node https://github.com/автор/репозиторий.git   имя-папки   [ветка]; \
```

Ветка необязательна, без неё берётся ветка по умолчанию. Зависимости всех нод ставятся автоматически, при этом версия PyTorch зафиксирована через `constraints.txt`, так что ни одна нода не сможет её заменить.

## Обновление

Слои в `Dockerfile` разделены на две части. Нижняя (Ubuntu, torch, SageAttention, llama-cpp) берётся из кэша Docker и пересобирается, только если изменились wheel-файлы. Верхняя (ComfyUI и все ноды) пересобирается при каждом запуске `build-and-push.sh`: скрипт передаёт `CACHE_BUST` с текущим временем, и ComfyUI с нодами скачиваются свежими из GitHub.

| Что обновилось | Что делать |
|---|---|
| ComfyUI или ноды | `./build-and-push.sh v2`, они берутся свежими автоматически |
| PyTorch на хосте | `./build-and-push.sh v2`, скрипт сам заметит и пересоберёт wheel-файлы |
| Список нод | правка `Dockerfile`, затем `./build-and-push.sh v2` |
| Список моделей | правка `/workspace/models.txt` на поде, пересборка не нужна |

После сборки поменяйте тег в шаблоне RunPod на новый и перезапустите под.

> [!NOTE]
> Обновления через ComfyUI Manager на поде записываются в контейнер и пропадают при перезапуске. Постоянно обновлять ComfyUI и ноды нужно пересборкой образа.
