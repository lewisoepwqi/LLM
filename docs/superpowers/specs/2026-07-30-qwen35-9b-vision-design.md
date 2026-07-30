# Qwen3.5-9B 启用视觉能力 — 设计文档

日期：2026-07-30
状态：已确认，待实施

## 背景

`docker/` 目录当前把 `bartowski/Qwen_Qwen3.5-9B-GGUF` 的 `Q5_K_M` 量化跑在
`ghcr.io/ggml-org/llama.cpp:server-cuda` 容器里，单卡（GPU 0）全量 offload，
OpenAI 兼容 API 暴露在 8080，供合同/标书业务后端通过 HTTP 调用。

Qwen3.5-9B 本身具备视觉能力（HF 仓库 `pipeline_tag` 为 `image-text-to-text`），
但当前部署只加载了主权重，未加载多模态投影器（mmproj），因此视觉不可用。

目标：在**不更换主模型、不改变 API 契约**的前提下开启视觉能力。

## 关键调研结论

1. **mmproj 文件与主模型在同一个 HF 仓库**，无需更换仓库或重下主权重。
   - `mmproj-Qwen_Qwen3.5-9B-f16.gguf` = 918,165,952 B ≈ 876 MiB
   - 同仓库另有 `bf16` 变体（921,704,896 B），CUDA 后端选 `f16`。
2. **llama-server 开启视觉只需 `--mmproj <file>`**。相关旋钮：
   - `--mmproj-offload` / `--no-mmproj-offload`（投影器是否上 GPU，默认上）
   - `--image-min-tokens N` / `--image-max-tokens N`（动态分辨率模型的每图视觉 token 上下限，默认读模型自带值）
   - `--mtmd-batch-max-tokens N`（编码时每批图像 token 数，默认 1024）
3. **API 协议不变**。同一个 `/v1/chat/completions`，纯文本请求完全向后兼容；
   传图时 `messages[].content` 由字符串改为 content-part 数组，
   `image_url.url` 支持 base64 data URI、远程 URL、`file://`（需 `--media-path`）。
4. **镜像 tag 可以钉死**。`ghcr.io/ggml-org/llama.cpp` 提供 `server-cuda-bNNNNN`
   版本固定 tag，最新为 `server-cuda-b10156`，与浮动 tag `server-cuda` 当前
   同 digest（`sha256:4c0ece468721077a8bff8c114f8b0a92a8604ed310c91939fadfe37595a53b9e`）。
5. **视觉 token 换算**：Qwen-VL 系为 28×28 px patch + 2×2 merge，约 **784 px ≈ 1 视觉 token**。
   一张 1.0–1.4M 像素的 A4 扫描件约 **1800–2600 token/页**。

## 范围

### 做

- 补下 mmproj 文件到现有 `models/Qwen3.5-9B/` 目录
- 现有 8080 容器就地加 `--mmproj` 与 `--image-max-tokens`
- 镜像 tag 参数化并钉死版本
- 更新 README / OFFLINE.md 文档
- `test_api.sh` 增加视觉冒烟测试

### 不做（已明确排除）

- **不启用 `--media-path` / `file://` 本地文件路径**。后端不保证与 llama 容器同机，
  共享挂载卷不成立，该路径无收益。**图片一律走 base64 data URI。**
- 不另起第二个容器、不占用 GPU 1。文本与视觉共用现有 8080 服务。
- 不更换主模型权重、不改量化档。
- 不修改业务后端代码（后端接入是独立工作项，本文档只定义其可依赖的 API 契约）。

## 设计

### 架构

服务形态不变：单容器、单卡、单端口。

```
业务后端  ──HTTP(base64 图)──▶  8080  llama-server
                                       ├─ Qwen_Qwen3.5-9B-Q5_K_M.gguf   (主权重, 不变)
                                       └─ mmproj-Qwen_Qwen3.5-9B-f16.gguf (新增)
```

回滚路径：注释掉 compose 里 `--mmproj` 两行并重启，服务退回纯文本，
mmproj 文件留在磁盘上无副作用。

### 前置检查：镜像 build 号

离线服务器上的镜像是历史 `docker load` 进去的，build 号未知。实施第一步必须确认：

```bash
docker exec Qwen3.5-9B /app/llama-server --version
```

判据：**≥ b9222**（bartowski 出这批量化所用的 build）。

推论：这批 GGUF 依赖的 MTP 层是 b9180 才支持的，**若当前服务能正常加载并产出正常输出，
则镜像已 ≥ b9180**，mtmd 视觉栈大概率已在其中。因此需要重打包镜像的概率不高，
但该命令仍必须执行，不做假设。

若版本不足，按 OFFLINE.md 流程重打包，使用固定 tag：

```bash
docker pull --platform linux/amd64 ghcr.io/ggml-org/llama.cpp:server-cuda-b10156
docker save ghcr.io/ggml-org/llama.cpp:server-cuda-b10156 -o llama-server-cuda-b10156.tar
```

### 模型文件获取（离线流程）

有网机器：

```bash
hf download bartowski/Qwen_Qwen3.5-9B-GGUF mmproj-Qwen_Qwen3.5-9B-f16.gguf --local-dir ./gguf
sha256sum ./gguf/mmproj-Qwen_Qwen3.5-9B-f16.gguf
scp ./gguf/mmproj-Qwen_Qwen3.5-9B-f16.gguf 服务器:~/app/LLM/models/Qwen3.5-9B/
```

服务器侧比对 sha256，一致方视为传输完整。文件与主 GGUF 同目录，
容器内路径 `/models/Qwen3.5-9B/mmproj-Qwen_Qwen3.5-9B-f16.gguf`。

### 上下文与视觉 token 预算

现状 `-c 16384 --parallel 2` = **每槽 8192**。业务后端读正文本就要塞约 8000 字
（≈4000–6000 中文 token）进同一个槽，图片与正文抢同一份预算。

**采用默认档**：保持 `-c 16384 --parallel 2`，新增 `--image-max-tokens 3072`。
单槽预算分配：图 ≤3072 + 提示词与正文 + 输出，落在 8192 内，并发不降。

**备选高精度档**（不在本次实施范围，仅记录为已知调优路径）：
`--parallel 1` + `-c 16384` + `--image-max-tokens 6144`。单图分辨率上限翻倍，
密集小字扫描件 OCR 准确率更高，代价是并发归零，业务后端 `READ_CONCURRENCY` 须同步降到 1。

档位切换方式：改 `.env` 中 `LLAMA_PARALLEL` 与 `IMAGE_MAX_TOKENS` 两个值后重启。

决策依据：3072 token 是否够读清一页合同，取决于实际扫描件 DPI 与字号，
无法先验判定。先上默认档，用真实扫描件实测准确率后再决定是否切档。

`--image-min-tokens` 与 `--mtmd-batch-max-tokens` 保持默认，不显式传入。

### 显存

| 项 | 估算 |
|---|---|
| Q5_K_M 权重 | 6.62 GiB |
| mmproj f16（默认 offload 到 GPU） | 0.86 GiB |
| KV @16384 + 计算缓冲 | ~2–3 GiB（现网实测口径） |
| 视觉编码峰值缓冲 | +0.5–1 GiB |
| **合计峰值** | **~11–12 GiB / 16 GiB** |

A4000 单卡有余量。此为估算值，验收时必须在**推理图片的瞬间**实测，
而非只看空闲态。若峰值逼近上限，优先降 `IMAGE_MAX_TOKENS`，其次降 `CONTEXT_SIZE`。

### API 契约

**服务端零变更。** `POST /v1/chat/completions`、端口 8080、模型名、`/v1/models`、
`/health` 全部不变。

**向后兼容。** `content` 为字符串时行为与现在完全一致。因此视觉能力可以先上线，
业务后端后续独立接入，无需同步发版。

**传图请求格式**（后端接入时使用）：

```json
{
  "model": "qwen3.5-9b",
  "messages": [
    {"role": "user", "content": [
      {"type": "text", "text": "提取这张合同扫描件的甲乙方、金额、签订日期"},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,<BASE64>"}}
    ]}
  ],
  "chat_template_kwargs": {"enable_thinking": false}
}
```

后端接入约束：

1. **必须使用 base64 data URI。** llama-server 支持远程 URL，但那是服务端发起 fetch，
   内网机器取不到图。`file://` 已明确排除（见"不做"）。
2. **base64 膨胀约 33%**：2 MB JPEG → ~2.7 MB 请求体。llama-server 自身不限体积，
   但若链路上有 nginx 反代，须调 `client_max_body_size`。这是最易踩的坑。
3. **`prompt_tokens` 口径变化**：将包含视觉 token。后端若有 token 统计或限流逻辑，
   需重新校准阈值。
4. **支持格式**：JPEG / PNG / BMP / TGA / GIF。PDF 由后端自行转图（如 `pdftoppm`）。
5. `chat_template_kwargs.enable_thinking=false` 对视觉请求同样生效，无需改动。

### 测试

视觉冒烟测试拆成独立脚本 `docker/test_vision.sh`，由 `test_api.sh` 在现有两项检查后调用。
拆开的理由：独立脚本可以脱离 GPU、用本地 mock HTTP 服务验证断言逻辑本身是否正确，
不必为了验证测试而占用一次上服务器的成本；也便于上线后单独重跑。

- 内嵌一张极小的、内容可判定的 base64 图片（四象限纯色 PNG），
  发一次视觉请求，断言响应中出现预期内容。
- 目的是证明**视觉栈确实被走通**，而不仅仅是"请求没报错"——
  纯文本兼容意味着一个格式错误的视觉请求也可能返回看似正常的文本回复。
- 现有 `nvidia-smi` 显存检查保留，并在文档中提示视觉验收需抓推理瞬间峰值。

## 交付物

| 文件 | 改动 |
|---|---|
| `docker/docker-compose.yml` | 新增 `--mmproj`、`--image-max-tokens`；镜像 tag 参数化并钉死 |
| `docker/.env`、`docker/.env.docker.example` | 新增 `MMPROJ_FILE`、`IMAGE_MAX_TOKENS`、`LLAMA_IMAGE`；补两档参数说明 |
| `docker/OFFLINE.md` | 新增 mmproj 下载/上传/校验一节；镜像重打包改用固定 tag |
| `docker/README.md` | 视觉用法示例、调参对照表补充、排错补"视觉不生效"条目 |
| `docker/test_vision.sh` | 新建：独立视觉冒烟测试（内嵌四象限纯色测试图，自包含） |
| `docker/test_api.sh` | 末尾调用 `test_vision.sh` |

## 验收标准

1. `docker exec Qwen3.5-9B /app/llama-server --version` 输出 ≥ b9222。
2. 容器启动日志显示 mmproj 加载成功，`/health` 返回 200。
3. `bash test_api.sh` 全部通过，含视觉冒烟测试。
4. 原有纯文本请求行为不变（回归验证）。
5. 推理图片瞬间 GPU 0 显存峰值 < 16 GiB，有明确余量。
6. 用一张真实合同扫描件跑通字段抽取，记录准确率作为是否切高精度档的依据。

## 参考

- https://huggingface.co/bartowski/Qwen_Qwen3.5-9B-GGUF
- https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md
- https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
