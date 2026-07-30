# Linux + NVIDIA CUDA 部署（Docker）

把 `Qwen3.5-9B` 模型服务部署到带 NVIDIA GPU 的 Linux 服务器上，用官方 llama.cpp CUDA 镜像，**无需安装 CUDA toolkit、无需编译**。

## 目标环境

本套件按以下环境验证设计：

```text
Ubuntu 22.04.5 LTS (kernel 6.8, x86_64)
NVIDIA Driver 535.309.01 / CUDA 12.2
2x NVIDIA RTX A4000 16GB
```

策略：**单卡（GPU 0）全量 offload**。Qwen3.5-9B Q5_K_M 权重 ~6.5GB + 视觉投影器 mmproj ~0.86GB + KV cache ~1-2GB，单张 16GB A4000 仍富余，第二张卡留作备用。

> **离线 / 内网服务器**（无法 `docker pull`、`hf download`、`apt install`）请看 [`OFFLINE.md`](OFFLINE.md)：在有网机器上把镜像、模型、依赖打包成文件，再上传 `docker load`。本文下面的步骤默认服务器有外网。

## 推荐目录布局（与合同业务解耦）

LLM 推理服务自包含在一个目录里，合同项目单独放、通过 HTTP 调它：

```text
~/app/LLM/
  docker/                              # 本部署套件
    docker-compose.yml
    .env
    setup_docker_gpu.sh
    test_api.sh
    test_vision.sh
  models/
    Qwen3.5-9B/
      Qwen_Qwen3.5-9B-Q5_K_M.gguf
      mmproj-Qwen_Qwen3.5-9B-f16.gguf    # 视觉投影器，与主权重同目录
```

`.env` 里 `MODELS_DIR=../models` 即指向上面的 `models/`（相对 compose 文件解析，不写死用户名）。

## 为什么 Linux 上用 Docker 而不是源码编译

llama.cpp 官方 release **只为 Windows 提供 CUDA 预编译包**，Linux 只给 CPU 版。所以 Linux 上想用 CUDA，要么源码编译，要么用官方 Docker 镜像（如 `ghcr.io/ggml-org/llama.cpp:server-cuda-b10156`）。镜像已内置 CUDA 运行时，宿主机只要有 NVIDIA 驱动 + nvidia-container-toolkit 即可，最省事。

## 步骤

### 1. 准备宿主机（Docker + NVIDIA Container Toolkit）

驱动 535 已就位，脚本不会动驱动，只装 Docker 和容器 GPU 支持：

```bash
bash deploy/docker/setup_docker_gpu.sh
```

脚本最后会跑一个容器内 `nvidia-smi` 自检，看到 GPU 即成功。

### 2. 放模型

把 GGUF 放到 `models/`（与 `docker/` 同级）：

```bash
mkdir -p ~/app/LLM/models/Qwen3.5-9B
# 有网：hf download bartowski/Qwen_Qwen3.5-9B-GGUF Qwen_Qwen3.5-9B-Q5_K_M.gguf \
#         --local-dir ~/app/LLM/models/Qwen3.5-9B
# 无网：在有网机器下载后 scp 上传到该目录（见 OFFLINE.md）

# 视觉投影器（876 MiB，与主权重同仓库）。
# 注意：compose 默认无条件传 --mmproj，不下载这个文件的话必须同时注释掉
# docker-compose.yml 里 --mmproj / 路径 / --image-max-tokens / 值 那 4 行（见下方
# 「关掉视觉」），否则 llama-server 加载阶段就会因为文件缺失而报错、容器起不来——
# 连纯文本也用不了。只有「不下载 mmproj」+「注释掉 4 行」两件事一起做，纯文本才不受影响。
# 有网：hf download bartowski/Qwen_Qwen3.5-9B-GGUF mmproj-Qwen_Qwen3.5-9B-f16.gguf \
#         --local-dir ~/app/LLM/models/Qwen3.5-9B
ls -lh ~/app/LLM/models/Qwen3.5-9B/
```

### 3. 配置并启动

```bash
cd ~/app/LLM/docker
cp .env.docker.example .env     # 默认 MODELS_DIR=../models 已对上面布局，按需改端口
docker compose up -d
docker compose logs -f          # 看加载日志，出现 "server listening" 即就绪
```

### 4. 验证

```bash
cd ~/app/LLM/docker && bash test_api.sh
```

应看到 `/v1/models` 返回、一句话回答，以及 `nvidia-smi` 里 GPU 0 占用 ~9-10GB
（默认已加载视觉投影器，多占约 0.86GB；关掉视觉后降回 ~8-9GB）。

## 常用运维

```bash
docker compose ps               # 状态
docker compose logs -f          # 日志
docker compose restart          # 重启
docker compose down             # 停止并删除容器
docker compose pull             # 拉取镜像新版本后再 up -d 即可升级
```

`restart: unless-stopped` 已配置，崩溃/重启机器后会自动拉起，无需额外 systemd。

## 视觉能力

Qwen3.5-9B 本身支持图文输入。服务已加载 `mmproj-Qwen_Qwen3.5-9B-f16.gguf`（876 MiB），
视觉与文本共用同一个 8080 服务。

### API 契约

**服务端零变更**：还是 `POST /v1/chat/completions`，端口、模型名、`/v1/models`、`/health` 全不变。

**纯文本请求 100% 向后兼容** —— `content` 是字符串时行为与开视觉前完全一致。所以业务后端
不改也能继续跑，视觉可以先上线、后端后续独立接入，不需要同步发版。

传图时把 `content` 从字符串改为 content-part 数组：

```bash
IMG=$(base64 -w0 合同扫描件.jpg)
curl -sS http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"qwen3.5-9b\",
    \"messages\": [{\"role\": \"user\", \"content\": [
      {\"type\": \"text\", \"text\": \"提取这张合同扫描件的甲乙方、金额、签订日期\"},
      {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/jpeg;base64,${IMG}\"}}
    ]}],
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }"
```

### 后端接入约束

1. **必须用 base64 data URI。** llama-server 也支持远程 URL，但那是**服务端**去 fetch，
   本服务在内网、取不到图。本部署未启用 `--media-path`，`file://` 也不可用
   （后端不保证与本容器同机，共享挂载卷不成立）。
2. **base64 膨胀约 33%**：2 MB 的 JPEG → 约 2.7 MB 请求体。llama-server 自身不限体积，
   但**若链路上有 nginx 反代，须调 `client_max_body_size`**。这是最容易踩的坑。
3. **`prompt_tokens` 口径变了**，会包含视觉 token。后端若有 token 统计或限流逻辑需重新校准。
4. **支持格式**：JPEG / PNG / BMP / TGA / GIF。**PDF 需后端自行转图**（如 `pdftoppm -jpeg -r 150`）。
5. 图片 token 上限由 `IMAGE_MAX_TOKENS` 控制（默认 3072）。单张图超限会被降采样，
   不会报错，但小字可能糊掉。

### 两档参数

Qwen-VL 动态分辨率约 **784 px ≈ 1 个视觉 token**，A4 扫描件整页约 **1800–2600 token**。

| 档位 | `.env` 配置 | 每槽上下文 | 适用 |
|---|---|---|---|
| 默认档 | `LLAMA_PARALLEL=2` `CONTEXT_SIZE=16384` `IMAGE_MAX_TOKENS=3072` | 8192 | 整页扫描件够用，保留 2 路并发 |
| 高精度档 | `LLAMA_PARALLEL=1` `CONTEXT_SIZE=16384` `IMAGE_MAX_TOKENS=6144` | 16384 | 密集小字 OCR 更准，但并发归零，业务后端 `READ_CONCURRENCY` 须同步降到 1 |

先跑默认档，用真实扫描件测准确率，不够再切高精度档（改 `.env` 两个值 + `docker compose up -d`）。

### 验证

```bash
bash test_vision.sh          # 单独跑视觉冒烟测试
bash test_api.sh             # 全量（含视觉）
```

用一张四象限纯色图断言模型真读到了图，而不只是"请求没报错"。

### 关掉视觉

注释掉 `docker-compose.yml` 里 `--mmproj` / `--image-max-tokens` 那 4 行，
`docker compose up -d`。服务退回纯文本，显存少占约 0.86 GiB，mmproj 文件留在磁盘上无副作用。

回滚后再跑 `bash test_api.sh`，末尾的视觉冒烟测试**会失败**——这是预期行为（mmproj 已经
关掉了），只要前面的 `/v1/models`、纯文本回答、显存占用检查都通过即可，不用管视觉那步的失败。

## 调参对照（与 Windows 版一致的语义）

| 需求 | 改法 |
|---|---|
| 换量化文件 | `.env` 里改 `MODEL_FILE=Qwen3.5-9B/Qwen_Qwen3.5-9B-Q4_K_M.gguf` |
| 换端口 | `.env` 里改 `LLAMA_SERVER_PORT=8081` |
| 显存吃紧 | 每槽 = `CONTEXT_SIZE / LLAMA_PARALLEL`，别低于 8192：`.env` 里把 `CONTEXT_SIZE` 和 `LLAMA_PARALLEL` 一起降，如 `CONTEXT_SIZE=8192` + `LLAMA_PARALLEL=1`（每槽仍是 8192），不要只降 `CONTEXT_SIZE`；还不够就降 `IMAGE_MAX_TOKENS` 或参考下方「关掉视觉」 |
| 用第二张卡 | `.env` 里改 `GPU_DEVICE_ID=1` |
| 部分 offload | `.env` 里改 `N_GPU_LAYERS=20`（一般无需，9B 可全量） |
| 视觉精度不够 | `.env` 里 `LLAMA_PARALLEL=1` + `IMAGE_MAX_TOKENS=6144`（并发降为 1） |
| 关掉视觉 | 注释掉 compose 里 `--mmproj` / `--image-max-tokens` 4 行 |
| 升级 llama.cpp | `.env` 里改 `LLAMA_IMAGE=...:server-cuda-bNNNNN`（离线需先 save/load 新镜像） |

## 排错

- **`could not select device driver "nvidia"`**：nvidia-container-toolkit 没装好或没 `nvidia-ctk runtime configure`。重跑 `setup_docker_gpu.sh`。
- **容器一直 unhealthy / 拉不起**：`docker compose logs` 看是不是模型路径错了。确认 `MODELS_DIR` 下确实有 `MODEL_FILE` 指向的文件。
- **WSL/局域网访问不到**：服务绑定容器内 `0.0.0.0:8080`，宿主机映射到 `LLAMA_SERVER_PORT`。检查服务器防火墙是否放行该端口。
- **首个 token 慢**：模型加载需时间，`start_period` 已给 120s。加载完后 GPU 推理应为 30-60+ tok/s。
- **视觉请求报 multimodal 相关错误**：`--mmproj` 没生效。`docker compose config | grep mmproj`
  确认参数渲染出来了，再 `ls -lh models/Qwen3.5-9B/mmproj-*` 确认文件在（应为 918165952 字节）。
- **视觉请求 200 但模型说看不到图**：多半是镜像 build 太老。
  `docker exec Qwen3.5-9B /app/llama-server --version` 确认 >= b9222，否则重打包镜像。
- **视觉请求报上下文不够 / 输出被截断**：每槽上下文 = `CONTEXT_SIZE / LLAMA_PARALLEL`，
  要同时装下图片(<=`IMAGE_MAX_TOKENS`)+正文+输出。降 `IMAGE_MAX_TOKENS` 或降 `LLAMA_PARALLEL`。
- **请求体过大被拒（413）**：base64 比原图大约 1/3。若前面有 nginx 反代，调 `client_max_body_size`。
- **`docker compose up -d` 报找不到镜像 / 卡在尝试联网拉取**：`LLAMA_IMAGE` 钉死的 tag
  （默认 `server-cuda-b10156`）在本机 `docker images` 里不存在——最常见的原因是这台服务器
  之前是用浮动 tag `server-cuda` 打包载入的镜像，tag 名对不上钉死名，无外网也拉不下来。
  `docker images | grep llama.cpp` 确认本地实际 tag 名，然后二选一：
  `docker tag` 给现有镜像打别名成 `server-cuda-b10156`，或把 `.env` 里 `LLAMA_IMAGE`
  改成本地实际存在的 tag。

## 备选：纯 docker run（不用 compose）

```bash
docker run -d --name contract_radar_llm --restart unless-stopped \
  --gpus '"device=0"' -p 8080:8080 \
  -v /models:/models:ro \
  ghcr.io/ggml-org/llama.cpp:server-cuda-b10156 \
  -m /models/Qwen3.5-9B/Qwen_Qwen3.5-9B-Q5_K_M.gguf \
  --mmproj /models/Qwen3.5-9B/mmproj-Qwen_Qwen3.5-9B-f16.gguf \
  --image-max-tokens 3072 \
  -ngl 99 -c 16384 --parallel 2 --cont-batching \
  --host 0.0.0.0 --port 8080 \
  --chat-template-kwargs '{"enable_thinking":false}'
```
