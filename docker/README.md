# Linux + NVIDIA CUDA 部署（Docker）

把 `Qwen3.5-9B` 模型服务部署到带 NVIDIA GPU 的 Linux 服务器上，用官方 llama.cpp CUDA 镜像，**无需安装 CUDA toolkit、无需编译**。

## 目标环境

本套件按以下环境验证设计：

```text
Ubuntu 22.04.5 LTS (kernel 6.8, x86_64)
NVIDIA Driver 535.309.01 / CUDA 12.2
2x NVIDIA RTX A4000 16GB
```

策略：**单卡（GPU 0）全量 offload**。Qwen3.5-9B Q5_K_M 权重 ~6.5GB + KV cache ~1-2GB，单张 16GB A4000 富余，第二张卡留作备用。

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
  models/
    Qwen3.5-9B/
      Qwen_Qwen3.5-9B-Q5_K_M.gguf
```

`.env` 里 `MODELS_DIR=../models` 即指向上面的 `models/`（相对 compose 文件解析，不写死用户名）。

## 为什么 Linux 上用 Docker 而不是源码编译

llama.cpp 官方 release **只为 Windows 提供 CUDA 预编译包**，Linux 只给 CPU 版。所以 Linux 上想用 CUDA，要么源码编译，要么用官方 Docker 镜像（`ghcr.io/ggml-org/llama.cpp:server-cuda`）。镜像已内置 CUDA 运行时，宿主机只要有 NVIDIA 驱动 + nvidia-container-toolkit 即可，最省事。

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

应看到 `/v1/models` 返回、一句话回答，以及 `nvidia-smi` 里 GPU 0 占用 ~8-9GB。

## 常用运维

```bash
docker compose ps               # 状态
docker compose logs -f          # 日志
docker compose restart          # 重启
docker compose down             # 停止并删除容器
docker compose pull             # 拉取镜像新版本后再 up -d 即可升级
```

`restart: unless-stopped` 已配置，崩溃/重启机器后会自动拉起，无需额外 systemd。

## 调参对照（与 Windows 版一致的语义）

| 需求 | 改法 |
|---|---|
| 换量化文件 | `.env` 里改 `MODEL_FILE=Qwen3.5-9B/Qwen_Qwen3.5-9B-Q4_K_M.gguf` |
| 换端口 | `.env` 里改 `LLAMA_SERVER_PORT=8081` |
| 显存吃紧 | `.env` 里降 `CONTEXT_SIZE=4096` |
| 用第二张卡 | `.env` 里改 `GPU_DEVICE_ID=1` |
| 部分 offload | `.env` 里改 `N_GPU_LAYERS=20`（一般无需，9B 可全量） |

## 排错

- **`could not select device driver "nvidia"`**：nvidia-container-toolkit 没装好或没 `nvidia-ctk runtime configure`。重跑 `setup_docker_gpu.sh`。
- **容器一直 unhealthy / 拉不起**：`docker compose logs` 看是不是模型路径错了。确认 `MODELS_DIR` 下确实有 `MODEL_FILE` 指向的文件。
- **WSL/局域网访问不到**：服务绑定容器内 `0.0.0.0:8080`，宿主机映射到 `LLAMA_SERVER_PORT`。检查服务器防火墙是否放行该端口。
- **首个 token 慢**：模型加载需时间，`start_period` 已给 120s。加载完后 GPU 推理应为 30-60+ tok/s。

## 备选：纯 docker run（不用 compose）

```bash
docker run -d --name contract_radar_llm --restart unless-stopped \
  --gpus '"device=0"' -p 8080:8080 \
  -v /models:/models:ro \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
  -m /models/Qwen3.5-9B/Qwen_Qwen3.5-9B-Q5_K_M.gguf \
  -ngl 99 -c 8192 --host 0.0.0.0 --port 8080 \
  --chat-template-kwargs '{"enable_thinking":false}'
```
