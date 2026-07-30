# 上线清单：给 Qwen3.5-9B 开启视觉能力

对照着敲的操作清单。每步给出**命令、预期输出、不符合怎么办**。按顺序执行，不要跳步。

- 背景和原理见 [`README.md`](README.md) 的「视觉能力」章节
- 离线打包/上传的通用流程见 [`OFFLINE.md`](OFFLINE.md)

**总耗时估计**：有网机器上下载 ~876 MiB（视带宽）+ 上传 + 服务器操作约 20 分钟。
**服务中断**：只有 Step 3.2 重启容器那一下，约 1–2 分钟（模型加载）。

---

## 阶段 0：变量（两台机器上各自先设一次）

后面所有命令都用这些变量，设一次即可全程复制粘贴。

**有网机器上：**

```bash
export SRV=ubuntu@服务器IP          # ← 改成实际的
export WORK=~/qwen-vision-pkg
mkdir -p $WORK && cd $WORK
```

**服务器上：**

```bash
export APP=~/app/LLM               # ← 改成实际部署路径
export MDIR=$APP/models/Qwen3.5-9B
```

---

## 阶段 1：在有网机器上准备

### 1.1 下载 mmproj

**推荐：直接 curl，不装任何 Python 包。** 只下一个文件，没必要引入 `huggingface_hub`。

```bash
cd $WORK
curl -L --fail --retry 3 --retry-delay 2 -C - \
  -o mmproj-Qwen_Qwen3.5-9B-f16.gguf \
  "https://huggingface.co/bartowski/Qwen_Qwen3.5-9B-GGUF/resolve/main/mmproj-Qwen_Qwen3.5-9B-f16.gguf"
```

`-C -` 是断点续传：876 MiB 断了重跑同一条命令即可接着下，不用从头开始。

<details>
<summary>如果你更想用 hf CLI（注意 PEP 668）</summary>

Ubuntu 24.04 / Debian 12 起，`pip install` 往系统 Python 装包会被拒绝，报
`error: externally-managed-environment`。这是 PEP 668 的预期行为，**不要**用
`--break-system-packages` 绕过。用 venv：

```bash
python3 -m venv ~/.venv/hf                       # 需要 python3-venv，没有就 sudo apt install python3-venv
~/.venv/hf/bin/pip install -U "huggingface_hub[cli]"
~/.venv/hf/bin/hf download bartowski/Qwen_Qwen3.5-9B-GGUF \
  mmproj-Qwen_Qwen3.5-9B-f16.gguf --local-dir $WORK
```

或者 `sudo apt install pipx && pipx install "huggingface_hub[cli]"`。
</details>

**选 f16，不要 bf16。** 两者只差 3 MB，但 CUDA 后端走 f16 是常规路径。

### 1.2 校验（对上游官方哈希，不是自己和自己比）

```bash
ls -l mmproj-Qwen_Qwen3.5-9B-f16.gguf
sha256sum mmproj-Qwen_Qwen3.5-9B-f16.gguf
```

**预期**——两项都必须完全吻合：

```text
size   = 918165952
sha256 = 97f420245a85ce129bb764e86a5e21e27d782fe6d6056c6839b9c5fdb8f38289
```

> 这是 HuggingFace 仓库 LFS 元数据里的官方值。**对不上就重新下载，不要继续。**
> GGUF 损坏的表现是加载报错或输出乱码，事后排查极费时间。

### 1.3 打包更新后的 docker/ 目录

本次改动**新增了 `test_vision.sh` 这个文件**，服务器上如果还是旧的 `docker/`，
后面 Step 4.1 的 `bash test_api.sh` 会直接报找不到它。所以 `docker/` 必须一起更新。

```bash
cd /path/to/LLM              # ← 本仓库 clone 的位置
git pull                     # 确保是合并后的 main
tar czf $WORK/docker-vision.tar.gz docker/
cd $WORK && ls -l docker-vision.tar.gz
```

### 1.4 （按需）打包镜像

**先做完阶段 3 的 Step 3.1，确认服务器上镜像 build < b9222 时才需要这步。**
build 够新只是 tag 名对不上的话，用 `docker tag` 打别名就行，不必重新打包 2–4 GB 的镜像。

```bash
docker pull --platform linux/amd64 ghcr.io/ggml-org/llama.cpp:server-cuda-b10156
docker save ghcr.io/ggml-org/llama.cpp:server-cuda-b10156 -o $WORK/llama-server-cuda-b10156.tar
```

---

## 阶段 2：上传

```bash
cd $WORK
ssh $SRV "mkdir -p ~/app/LLM/models/Qwen3.5-9B"     # 目录可能不存在，先建
rsync --partial --progress -e ssh mmproj-Qwen_Qwen3.5-9B-f16.gguf $SRV:~/app/LLM/models/Qwen3.5-9B/
rsync --partial --progress -e ssh docker-vision.tar.gz            $SRV:~/app/LLM/
# 仅当 1.4 打包了镜像：
# rsync --partial --progress -e ssh llama-server-cuda-b10156.tar  $SRV:~/app/LLM/
```

> 用 `rsync --partial` 而不是 `scp`：876 MiB 传一半断了可以续，不用从头再来。

---

## 阶段 3：服务器上的前置检查与启动

```bash
ssh $SRV
export APP=~/app/LLM
export MDIR=$APP/models/Qwen3.5-9B
```

### 3.1 检查镜像 —— build 号 和 tag 名是两件独立的事，都要查

```bash
docker exec Qwen3.5-9B /app/llama-server --version
docker images | grep llama.cpp
```

> **build 号决定视觉能不能用，tag 名决定容器能不能起来。** 两个判据互不替代：
> build 够新不代表 tag 名对得上，反之亦然。这是本次上线最容易踩的坑。

**判据 1 — build 号 ≥ b9222**

| 结果 | 怎么办 |
|---|---|
| ≥ b9222 | 通过，看判据 2 |
| < b9222 | 回阶段 1.4 打包 `server-cuda-b10156`，上传后 `docker load -i $APP/llama-server-cuda-b10156.tar` |

> 参考推论：这批 GGUF 依赖的 MTP 层自 b9180 起支持，**现在的服务如果本来就能正常
> 加载并产出正常输出，说明镜像已 ≥ b9180**，视觉栈大概率已在其中。需要重打包的概率不高
> ——但命令必须真跑，不要靠推断。

**判据 2 — 本地存在 `server-cuda-b10156` 这个 tag 名**

compose 已把 `LLAMA_IMAGE` 默认值钉死为 `ghcr.io/ggml-org/llama.cpp:server-cuda-b10156`。
这台服务器改动前是用**浮动 tag** `server-cuda` 打包载入的（改动前的 OFFLINE.md 就是这么写的），
本地 tag 名大概率是裸的 `server-cuda`。

**即便判据 1 已判定 build 够新、不需要重打包，只要本地没有 `server-cuda-b10156` 这个名字，
`docker compose up -d` 一样会尝试联网拉取 —— 服务器无外网，直接启动失败。**

| 结果 | 怎么办 |
|---|---|
| 有 `server-cuda-b10156` | 通过 |
| 只有 `server-cuda` 或别的名字 | 二选一，见下 |

```bash
# 出路 A（推荐，最快）：给现有本地镜像打个别名，不下载任何东西
docker tag ghcr.io/ggml-org/llama.cpp:server-cuda ghcr.io/ggml-org/llama.cpp:server-cuda-b10156

# 出路 B：改 .env 用本地实际存在的 tag 名，放弃钉死
#   在 $APP/docker/.env 里设 LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda
```

### 3.2 更新 docker/ 目录

```bash
cd $APP
cp -r docker docker.bak.$(date +%Y%m%d)     # 先备份，回滚时要用
tar xzf docker-vision.tar.gz                 # 覆盖出新的 docker/
ls -l docker/test_vision.sh                  # 新文件，必须在
```

**`.env` 要手工对一遍，不要直接拿备份覆盖。** `docker/.env` 是本地配置、不受 git 管，
解包会用仓库版本盖掉它。但备份里的旧 `.env` 又**没有**本次新增的三个变量，直接盖回去
等于把改动废掉。正确做法是看差异、只把你自己改过的值挪过来：

```bash
diff docker.bak.*/.env docker/.env
```

重点看你在服务器上改过的项（`MODELS_DIR`、`LLAMA_SERVER_PORT`、`GPU_DEVICE_ID`、
`MODEL_FILE`），把它们的值手工填进新的 `docker/.env`。下一步会逐项核对结果。

### 3.3 核对 .env

```bash
cd $APP/docker
grep -E '^(CONTEXT_SIZE|LLAMA_PARALLEL|IMAGE_MAX_TOKENS|MMPROJ_FILE|LLAMA_IMAGE)=' .env
```

**预期**（五行，顺序可能不同；`^...=` 是为了滤掉注释行，别去掉那个 `^`）：

```text
CONTEXT_SIZE=16384
LLAMA_PARALLEL=2
LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda-b10156
MMPROJ_FILE=Qwen3.5-9B/mmproj-Qwen_Qwen3.5-9B-f16.gguf
IMAGE_MAX_TOKENS=3072
```

少于五行就是缺变量。

缺哪个补哪个。**特别注意 `LLAMA_PARALLEL`**：老版本 `.env` 没有这一项，
而 `CONTEXT_SIZE` 又是 8192，实际渲染出来每槽只有 4096，装不下 3072 的图 + 正文 + 输出。

如果 3.1 走了「出路 B」，这里 `LLAMA_IMAGE` 应是你本地实际的 tag 名，不是 b10156。

### 3.4 校验 mmproj 已就位

```bash
ls -l $MDIR/
sha256sum $MDIR/mmproj-Qwen_Qwen3.5-9B-f16.gguf
```

**预期**：目录下两个文件，且 mmproj 的哈希与阶段 1.2 的官方值一致：

```text
Qwen_Qwen3.5-9B-Q5_K_M.gguf         7111487520 字节
mmproj-Qwen_Qwen3.5-9B-f16.gguf      918165952 字节
sha256 = 97f420245a85ce129bb764e86a5e21e27d782fe6d6056c6839b9c5fdb8f38289
```

**对不上不要继续**，回阶段 2 重传。

### 3.5 启动前先看渲染结果

```bash
cd $APP/docker
docker compose config | sed -n '/^    command:/,/^    container_name:/p'
docker compose config | grep 'image:'
```

**预期**（逐项核对，尤其是这四项）：

```text
image: ghcr.io/ggml-org/llama.cpp:server-cuda-b10156
      - -c
      - "16384"
      - --parallel
      - "2"
      - --mmproj
      - /models/Qwen3.5-9B/mmproj-Qwen_Qwen3.5-9B-f16.gguf
      - --image-max-tokens
      - "3072"
```

> 这一步是免费的——不启动容器、不占显存。渲染不对就别启动，回 3.3 查 `.env`。

### 3.6 启动

```bash
docker compose up -d
docker compose logs -f
```

**预期**：日志里出现 mmproj / clip / vision 相关的加载行，最终 `server listening`。
按 `Ctrl-C` 退出日志跟随（不会停容器）。

| 日志报什么 | 原因 | 回到哪一步 |
|---|---|---|
| 找不到镜像 / 尝试联网拉取 | tag 名对不上 | 3.1 判据 2 |
| 找不到 mmproj 文件 | 路径或文件没传对 | 3.4 |
| 不认识 `--image-max-tokens` 参数 | build 太老 | 3.1 判据 1 |
| CUDA out of memory | 显存不够 | 见下方「显存不够怎么调」 |

---

## 阶段 4：验收（五项，一项都别省）

### 4.1 全量测试（含纯文本回归）

```bash
cd $APP/docker && bash test_api.sh
```

**预期**：`/v1/models` 有返回 → 纯文本一句话回答正常 → `nvidia-smi` 有显存占用
→ 最后 `PASS: 视觉栈已生效`。

> 中间那条纯文本回答**同时就是纯文本回归验证**——它证明业务后端不改代码也能继续跑。

### 4.2 抓推理瞬间的显存峰值

开两个终端。

终端 A：

```bash
watch -n0.5 'nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv'
```

终端 B：

```bash
cd $APP/docker && bash test_vision.sh
```

记录终端 A 上 GPU 0 的**峰值**（不是空闲值）。

**预期约 11–12 GiB / 16 GiB**：权重 6.62 + mmproj 0.86 + KV/计算 2–3 + 视觉编码峰值 0.5–1。

**必须抓推理那一瞬间。** 空闲态看不出视觉编码的峰值，而 OOM 恰恰发生在峰值。

### 4.3 真实合同扫描件（这一步是决策依据，不是走过场）

**先用自带的合成测试件跑一遍**——它是 A4 @ 200 DPI（1654×2339，约 4900 视觉 token，
会被截到 3072，即满载），带标准答案，脚本会自动打分，同时高频采样显存峰值：

```bash
cd $APP/docker
bash test_vision_peak.sh testdata/contract_scan.png
```

**预期**：`prompt_tokens` 约 3000（证明 `--image-max-tokens` 吃满了）、字段 6/6 命中。
标准答案和更多可核对字段见 [`testdata/README.md`](testdata/README.md)。

**再换你自己的真实扫描件**：

```bash
bash test_vision_peak.sh /path/to/你的合同扫描件.jpg
```

换成真实件后不会自动打分（脚本只认自带那张），需人工核对输出。

> **想手写 curl 的话，请求体必须写进文件再用 `--data-binary @文件`**，不能把 base64
> 拼进 `-d "..."`：Linux 单个命令行参数上限 128 KiB，A4 扫描件 base64 后有几百 KiB，
> 内联会直接报 `参数列表过长`。写法见 [`README.md`](README.md) 的「视觉能力」章节。
> 这个限制只影响 shell；业务后端用 SDK 发请求不受影响。

**默认档 3072 token 够不够读清你们实际 DPI 和字号的扫描件，只能实测，猜没有意义。**

判读时注意：**公司名、日期这类字段模型靠语言先验就能补全，糊了也可能蒙对**，区分度低。
真正能反映小字 OCR 质量的是长数字串——统一社会信用代码（18 位混合字母数字）、
带千分位的金额、规格型号。要评估准确率就重点问这些。

准确率不够 → 切高精度档（见下方「两档参数怎么切」）→ 回 4.1 重跑一遍 4.1–4.3。

### 4.4 并发不受影响

```bash
cd $APP/docker
for i in 1 2; do bash test_vision.sh > /tmp/v$i.log 2>&1 & done; wait
grep -c PASS /tmp/v1.log /tmp/v2.log
```

**预期**：两个都 `1`（各自 PASS）。这验证 `--parallel 2` 的两个槽在开视觉后仍能并发。

若有一个失败并提示上下文不够，说明每槽 8192 装不下你的图 + 提示词，降 `IMAGE_MAX_TOKENS`。

### 4.5 回滚路径确实可用（演练一次，别等出事才第一次试）

```bash
cd $APP/docker
# 从 --mmproj 那行到 IMAGE_MAX_TOKENS 那行整段注释（共 6 行；中间的注释行不受影响）
sed -i.rollbaktest '/^      - "--mmproj"/,/IMAGE_MAX_TOKENS/ s|^      - |#      - |' docker-compose.yml

grep -c '^#      - ' docker-compose.yml                        # 预期 6
docker compose config >/dev/null && echo "注释后 YAML 仍合法"
docker compose config | grep -c 'mmproj\|image-min\|image-max' # 预期 0

mv docker-compose.yml.rollbaktest docker-compose.yml           # 立刻恢复
docker compose config | grep -c 'mmproj\|image-min\|image-max' # 预期 4，确认恢复了
```

> 只验证渲染，不重启容器，服务不中断。
>
> 用范围匹配（`/起/,/止/`）而不是逐行列举，是因为视觉参数以后可能增减——
> 列举式的 sed 每加一个参数就得同步改一次，漏改了会静默地只注释掉一部分。

---

## 阶段 5：记录结果

在 `$APP/docker/README.md` 的「视觉能力」章节末尾追加，并同步回仓库提交：

```markdown
### 实测记录（YYYY-MM-DD 上线）

- llama-server build：`bXXXXX`
- 镜像 tag 处理：本地原有 `server-cuda`，已 docker tag 打别名 / 已重新打包 b10156 / 无需处理
- 推理峰值显存：`XX.X GiB / 16 GiB`（GPU 0，抓自 test_vision.sh 执行瞬间）
- 并发验证：2 路并发视觉请求 通过 / 失败
- 真实合同扫描件抽取：甲方 ✓/✗ 乙方 ✓/✗ 金额 ✓/✗ 签订日期 ✓/✗
- 最终采用档位：默认档（`IMAGE_MAX_TOKENS=3072` / `LLAMA_PARALLEL=2`）
```

**这五项是后续调参和排障的唯一事实基础，别省。**

---

## 附：常见调整

### 两档参数怎么切

上下文的约束是**每槽**，不是总量。每槽 = `CONTEXT_SIZE / LLAMA_PARALLEL`，别低于 8192。

| 档位 | `.env` | 每槽 | 适用 |
|---|---|---|---|
| 默认档 | `CONTEXT_SIZE=16384` `LLAMA_PARALLEL=2` `IMAGE_MAX_TOKENS=3072` | 8192 | 整页扫描件够用，保留 2 路并发 |
| 高精度档 | `CONTEXT_SIZE=16384` `LLAMA_PARALLEL=1` `IMAGE_MAX_TOKENS=6144` | 16384 | 密集小字 OCR 更准，并发归零 |

切档：改 `.env` 两个值 → `docker compose up -d` → 回阶段 4 重跑验收。

> **切到高精度档必须同步把业务后端的 `READ_CONCURRENCY` 降到 1**，
> 否则后端并发发请求，服务端只有一个槽，会排队甚至超时。

### 显存不够怎么调

按这个顺序，先动代价小的：

1. 降 `IMAGE_MAX_TOKENS`（3072 → 2048）——只影响单图分辨率上限
2. `CONTEXT_SIZE` 和 `LLAMA_PARALLEL` **一起降**（如 8192 + 1，每槽仍是 8192）
   —— 单独降 `CONTEXT_SIZE` 会把每槽压穿；单独降 `LLAMA_PARALLEL` 一点显存都不省
   （KV 总量由 `CONTEXT_SIZE` 决定，不由槽数决定），反而把每槽拉大
3. 换更小的量化档（`MODEL_FILE` 改 `Q4_K_M`，省约 0.9 GiB）
4. 关掉视觉（见下）

### 关掉视觉（回滚）

```bash
cd $APP/docker
# 注释掉 docker-compose.yml 里视觉相关的 6 行（--mmproj / --image-min-tokens / --image-max-tokens 及各自的值）
docker compose up -d
bash test_api.sh
```

**视觉冒烟那一步会失败，这是预期的**——前面的纯文本检查应该全过。
显存少占约 0.86 GiB。mmproj 文件留在磁盘上无副作用，随时取消注释即可恢复。

整个 `docker/` 目录要回滚就用阶段 3.2 备份的 `docker.bak.*/`。

### 给业务后端的接入要点

完整 API 契约见 [`README.md`](README.md) 的「视觉能力」章节，四条最容易踩的：

1. **必须 base64 data URI**。远程 URL 是服务端去 fetch，内网取不到；`--media-path` 未启用，`file://` 也不可用。
2. **base64 膨胀约 33%**，2 MB 的 JPEG → 约 2.7 MB 请求体。**链路上有 nginx 就要调 `client_max_body_size`。**
3. **`prompt_tokens` 会包含视觉 token**，后端如有 token 统计或限流要重新校准阈值。
4. **PDF 要后端自己转图**（`pdftoppm -jpeg -r 150`），服务端只吃 JPEG/PNG/BMP/TGA/GIF。
