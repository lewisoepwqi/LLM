# 离线 / 内网部署（服务器无外网）

服务器无法 `docker pull` / `hf download` / `apt install` 时，思路统一为：
**在一台有外网 + Docker 的机器上把所有东西打包成文件 → 上传 → 在服务器上加载。**

需要准备 4 类产物，按服务器现状决定要不要第 3 类：

| 产物 | 必须？ | 大小（约） |
|---|---|---|
| 1. llama.cpp CUDA 镜像 tar | 是 | 2–4 GB |
| 2. 模型 GGUF | 是 | ~6.5 GB |
| 2b. 视觉投影器 mmproj | 想要视觉能力则必须 | ~876 MB |
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
# tag 钉死 build 号，否则每次打包拿到的 build 不确定，离线环境无法复现。
# 视觉能力要求 >= b9222。这个 tag 要与 .env 里的 LLAMA_IMAGE 一致。
docker pull --platform linux/amd64 ghcr.io/ggml-org/llama.cpp:server-cuda-b10156
docker save ghcr.io/ggml-org/llama.cpp:server-cuda-b10156 -o llama-server-cuda-b10156.tar
# 可选压缩：gzip llama-server-cuda-b10156.tar
```

### A2. 模型
```bash
pip install -U "huggingface_hub[cli]"
hf download bartowski/Qwen_Qwen3.5-9B-GGUF Qwen_Qwen3.5-9B-Q5_K_M.gguf --local-dir ./gguf
# 产物：./gguf/Qwen_Qwen3.5-9B-Q5_K_M.gguf

# 视觉投影器（与主权重同仓库）。
# 注意：compose 默认无条件传 --mmproj。如果不打包/不上传这个文件，必须同时注释掉
# docker-compose.yml 里 --mmproj / 路径 / --image-max-tokens / 值 那 4 行，否则文件缺失
# 会导致 llama-server 加载阶段直接失败、容器起不来——纯文本也用不了。两者要一起做。
hf download bartowski/Qwen_Qwen3.5-9B-GGUF mmproj-Qwen_Qwen3.5-9B-f16.gguf --local-dir ./gguf
# 产物：./gguf/mmproj-Qwen_Qwen3.5-9B-f16.gguf（918165952 字节）
# 注意选 f16 不要 bf16 —— 两者只差 3MB，但 CUDA 后端走 f16 是常规路径。
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
scp llama-server-cuda-b10156.tar   ubuntu@服务器IP:~/app/LLM/
scp ./gguf/Qwen_Qwen3.5-9B-Q5_K_M.gguf  ubuntu@服务器IP:~/app/LLM/models/Qwen3.5-9B/
scp ./gguf/mmproj-Qwen_Qwen3.5-9B-f16.gguf  ubuntu@服务器IP:~/app/LLM/models/Qwen3.5-9B/
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
docker load -i llama-server-cuda-b10156.tar   # 若压过：gunzip -c llama-server-cuda-b10156.tar.gz | docker load
docker images | grep llama.cpp                # 确认 server-cuda-b10156 标签在
```

> **如果服务器上早先是用浮动 tag `server-cuda` 打包载入的镜像**（改动前的本文档就是这么
> 写的，那台服务器上很可能就是这个状态）：`docker images` 里看到的 tag 名会是裸的
> `server-cuda`，跟 compose 现在钉死的 `server-cuda-b10156` 对不上。即使这个旧镜像的
> build 号已经够新、视觉功能能用，tag 名不对，`docker compose up -d` 照样会因为找不到
> `server-cuda-b10156` 这个本地镜像而失败（服务器无外网，拉不到）。三选一处理：
> - 按上面 A1 重新打包 `server-cuda-b10156` 并 `docker load`；
> - 或者给已有镜像打个别名：`docker tag ghcr.io/ggml-org/llama.cpp:server-cuda ghcr.io/ggml-org/llama.cpp:server-cuda-b10156`；
> - 或者把 `.env` 里的 `LLAMA_IMAGE` 改成本地实际存在的 tag（如 `server-cuda`），不用钉死名。

### C3. 确认模型就位
```bash
ls -lh ~/app/LLM/models/Qwen3.5-9B/
# 应看到两个文件：
#   Qwen_Qwen3.5-9B-Q5_K_M.gguf        7111487520 字节
#   mmproj-Qwen_Qwen3.5-9B-f16.gguf     918165952 字节
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
sha256sum llama-server-cuda-b10156.tar Qwen_Qwen3.5-9B-Q5_K_M.gguf mmproj-Qwen_Qwen3.5-9B-f16.gguf
# 服务器：
sha256sum ~/app/LLM/llama-server-cuda-b10156.tar ~/app/LLM/models/Qwen3.5-9B/Qwen_Qwen3.5-9B-Q5_K_M.gguf ~/app/LLM/models/Qwen3.5-9B/mmproj-Qwen_Qwen3.5-9B-f16.gguf
```
两边一致才算传完整。GGUF 损坏会表现为加载报错或输出乱码。
