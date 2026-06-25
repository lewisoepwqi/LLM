# 离线 / 内网部署（服务器无外网）

服务器无法 `docker pull` / `hf download` / `apt install` 时，思路统一为：
**在一台有外网 + Docker 的机器上把所有东西打包成文件 → 上传 → 在服务器上加载。**

需要准备 3 类产物，按服务器现状决定要不要第 3 类：

| 产物 | 必须？ | 大小（约） |
|---|---|---|
| 1. llama.cpp CUDA 镜像 tar | 是 | 2–4 GB |
| 2. 模型 GGUF | 是 | ~6.5 GB |
| 3. Docker Engine + NVIDIA Container Toolkit 离线包 | 仅当服务器没装 | ~300 MB |

> 先在服务器上判断要不要产物 3：
> ```bash
> docker --version            # 没有 → 需要离线装 docker engine
> nvidia-ctk --version        # 没有 → 需要离线装 nvidia-container-toolkit
> nvidia-smi                  # 驱动（535）应已就位，不需离线装
> ```

---

## A. 在「有网 + Docker」的机器上打包

> Windows 装了 Docker Desktop 也可以做。务必拉 linux/amd64 平台。

### A1. 镜像
```bash
docker pull --platform linux/amd64 ghcr.io/ggml-org/llama.cpp:server-cuda
docker save ghcr.io/ggml-org/llama.cpp:server-cuda -o llama-server-cuda.tar
# 可选压缩：gzip llama-server-cuda.tar   （得到 .tar.gz，传输更小）
```

### A2. 模型
```bash
pip install -U "huggingface_hub[cli]"
hf download bartowski/Qwen_Qwen3.5-9B-GGUF Qwen_Qwen3.5-9B-Q5_K_M.gguf --local-dir ./gguf
# 产物：./gguf/Qwen_Qwen3.5-9B-Q5_K_M.gguf
```

### A3.（按需）NVIDIA Container Toolkit 离线包
> 本项目目标服务器已自带 Docker，只缺 toolkit。toolkit 的 4 个 .deb 是 NVIDIA 官网**静态文件**，
> 相互依赖、不依赖外网其他包，**任何机器（含 Windows）都能直接下载**，无需另找 Ubuntu。

当前最新版 `1.19.1-1`，4 个文件（版本号按需在 Packages 索引里核对最新）：
```text
https://nvidia.github.io/libnvidia-container/stable/deb/amd64/
  libnvidia-container1_1.19.1-1_amd64.deb
  libnvidia-container-tools_1.19.1-1_amd64.deb
  nvidia-container-toolkit-base_1.19.1-1_amd64.deb
  nvidia-container-toolkit_1.19.1-1_amd64.deb
```
Windows PowerShell 下载：
```powershell
$base = "https://nvidia.github.io/libnvidia-container/stable/deb/amd64"
$debs = @(
  "libnvidia-container1_1.19.1-1_amd64.deb",
  "libnvidia-container-tools_1.19.1-1_amd64.deb",
  "nvidia-container-toolkit-base_1.19.1-1_amd64.deb",
  "nvidia-container-toolkit_1.19.1-1_amd64.deb"
)
New-Item -ItemType Directory -Force E:\nvct-debs | Out-Null
foreach ($d in $debs) { Invoke-WebRequest "$base/$d" -OutFile "E:\nvct-debs\$d" }
```
> 若服务器连 Docker Engine 都没有，才需要在一台同版本 Ubuntu 22.04 上
> `apt-get install -y --download-only docker-ce docker-ce-cli containerd.io docker-compose-plugin`
> 把 `/var/cache/apt/archives/*.deb` 一并打包。本项目服务器已有 Docker，无需这步。

---

## B. 上传到服务器

```powershell
# 从 Windows（PowerShell），或有网机器上用 scp
scp llama-server-cuda.tar          ubuntu@服务器IP:~/app/LLM/
scp ./gguf/Qwen_Qwen3.5-9B-Q5_K_M.gguf  ubuntu@服务器IP:~/app/LLM/models/Qwen3.5-9B/
# 如需第 3 类：
scp docker-offline-debs.tar.gz     ubuntu@服务器IP:~/app/LLM/
```
> 大文件断了可续传：`rsync --partial --progress -e ssh 文件 ubuntu@服务器IP:目标/`

---

## C. 在服务器上加载

### C1.（按需）离线装 NVIDIA Container Toolkit
> 已上传 `nvct-debs/` 到 `~/app/LLM/`。Docker 已有时只需装这 4 个包：
```bash
cd ~/app/LLM/nvct-debs
sudo dpkg -i *.deb                 # 4 个包相互依赖，一次性安装即可，无需联网修依赖
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
nvidia-ctk --version               # 有版本号 = 装好
```

### C2. 载入镜像
```bash
cd ~/app/LLM
docker load -i llama-server-cuda.tar          # 若压过：gunzip -c llama-server-cuda.tar.gz | docker load
docker images | grep llama.cpp                # 确认 server-cuda 标签在
```

### C3. 确认模型就位
```bash
ls -lh ~/app/LLM/models/Qwen3.5-9B/Qwen_Qwen3.5-9B-Q5_K_M.gguf
```

### C4. 启动（compose 见镜像已在本地，不会联网拉取）
```bash
cd ~/app/LLM/docker
cp .env.docker.example .env        # 默认 MODELS_DIR=../models 已对布局
docker compose up -d
docker compose logs -f
bash test_api.sh
```

---

## 校验完整性（避免传输损坏）
大文件上传后两端比对哈希：
```bash
# 打包机：
sha256sum llama-server-cuda.tar Qwen_Qwen3.5-9B-Q5_K_M.gguf
# 服务器：
sha256sum ~/app/LLM/llama-server-cuda.tar ~/app/LLM/models/Qwen3.5-9B/Qwen_Qwen3.5-9B-Q5_K_M.gguf
```
两边一致才算传完整。GGUF 损坏会表现为加载报错或输出乱码。
