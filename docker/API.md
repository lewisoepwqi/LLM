# 接口文档 — Qwen3.5-9B（文本 + 视觉）

给业务后端（合同雷达 / 标书工作台 / knowledge-os 等）接入用。

服务部署与运维见 [`README.md`](README.md)，上线流程见 [`RUNBOOK-vision.md`](RUNBOOK-vision.md)。

---

## 概览

| 项 | 值 |
|---|---|
| 基础地址 | `http://<服务器IP>:8080/v1` |
| 协议 | OpenAI Chat Completions 兼容 |
| 认证 | **无**（内网服务，未启用 API key） |
| 模型 | Qwen3.5-9B Q5_K_M + mmproj f16（图文） |
| 并发槽 | 2（每槽上下文 8192） |
| 端点 | `POST /v1/chat/completions`、`GET /v1/models`、`GET /health` |

**`model` 字段填什么都行。** 服务只加载了一个模型，llama-server 不校验这个字段。
`/v1/models` 返回的 id 是容器内路径（`/models/Qwen3.5-9B/Qwen_Qwen3.5-9B-Q5_K_M.gguf`），
但请求里写 `"qwen3.5-9b"` 同样可用。建议固定用 `"qwen3.5-9b"`，便于日志辨识。

---

## 向后兼容

**开启视觉后，纯文本请求的行为与之前完全一致。** `content` 传字符串时走的是原来的路径，
端点、端口、参数、响应结构都没变。**已有代码不需要任何改动。**

变化只有一处，且只在你主动传图时才涉及：`content` 从字符串变成数组。

---

## 一、纯文本调用（不变）

```json
POST /v1/chat/completions
{
  "model": "qwen3.5-9b",
  "messages": [
    {"role": "system", "content": "你是合同审阅助手。"},
    {"role": "user", "content": "这段条款有什么风险？……"}
  ],
  "temperature": 0,
  "max_tokens": 800,
  "chat_template_kwargs": {"enable_thinking": false}
}
```

`chat_template_kwargs.enable_thinking: false` 关闭思考链。服务端启动时已默认关闭，
请求里再写一次是保险（该参数在新版 llama.cpp 中已标记废弃，但当前 b9765 上行为正常）。

---

## 二、图文调用

`content` 改为 content-part 数组，图片用 **base64 data URI**：

```json
{
  "model": "qwen3.5-9b",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "提取这份合同的甲方、乙方、合同总金额、签订日期。"},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ..."}}
    ]
  }],
  "temperature": 0,
  "max_tokens": 800,
  "chat_template_kwargs": {"enable_thinking": false}
}
```

一条消息里可以放多张图（多个 `image_url` part），但要注意上下文预算（见第四节）。

### 图片约束

| 约束 | 说明 |
|---|---|
| **必须用 base64 data URI** | 服务端也支持远程 URL，但那是**服务端**去 fetch——本服务在内网，取不到你的图。`file://` 也不可用（本部署未启用 `--media-path`，且不保证后端与本容器同机）。 |
| 格式 | JPEG / PNG / BMP / TGA / GIF |
| **PDF 需自行转图** | 服务端不接受 PDF。用 `pdftoppm -jpeg -r 200 in.pdf page` 之类先转。 |
| 体积 | base64 比原图大约 1/3。一张 A4 @200 DPI 的扫描件约 0.5 MB → 请求体约 0.65 MB。llama-server 自身不限体积，**但链路上若有 nginx 反代，须调 `client_max_body_size`**。 |

---

## 三、视觉 token 与图片尺寸

Qwen-VL 是动态分辨率：**视觉 token 数由像素面积决定，约 784 px ≈ 1 token**。

| 图片 | 像素 | 估算 token | 实际生效 |
|---|---|---|---|
| A4 @ 150 DPI（1240×1754） | 2.18 M | ≈ 2775 | 2775 |
| A4 @ 200 DPI（1654×2339） | 3.87 M | ≈ 4934 | **截到 3072** |
| A4 @ 300 DPI（2480×3508） | 8.70 M | ≈ 11097 | **截到 3072** |
| 印章截图（400×400） | 0.16 M | ≈ 204 | **抬到 1024** |

服务端配置了 `--image-min-tokens 1024` / `--image-max-tokens 3072`：

- **超过 3072 会被降采样**，不报错，但小字可能糊掉。**给超过 200 DPI 的扫描件不会更准，
  只会更慢**——先在客户端把图缩到 200 DPI 左右更划算。
- 低于 1024 会被抬到 1024。这是 llama.cpp 对 Qwen-VL 的建议下限，保的是印章、签字、
  表格截图这类小图的识别质量。

`usage.prompt_tokens` **包含视觉 token**。如果后端有 token 统计或限流逻辑，阈值要重新校准。

---

## 四、上下文预算

**每槽 8192 token**（`CONTEXT_SIZE 16384 ÷ LLAMA_PARALLEL 2`）。一次请求要装下：

```
图片(≤3072) + 系统提示 + 用户文本 + 历史消息 + max_tokens 输出  ≤  8192
```

实践建议：

- 单图 + 提示词 + 800 输出 ≈ 4000，余量充足
- **一次放 2 张整页扫描件就会很紧**（3072×2 = 6144，只剩 2000 给文本和输出）
- 图文混合的多轮对话，历史里的图会一直占着 token —— 长会话要主动裁剪历史

超预算的表现是输出被截断或报错，不会静默出错。

---

## 五、结构化输出（强烈建议）

**模型默认会把 JSON 套在 ` ```json ` 代码块里**，直接 `json.loads()` 会失败。实测输出：

````text
```json
{
  "甲方": "杭州云图信息技术有限公司",
  ...
}
```
````

不要用正则剥代码块——用服务端的 schema 约束，让它只能吐合法 JSON：

```json
{
  "model": "qwen3.5-9b",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "提取这份合同的甲方、乙方、合同总金额、签订日期。"},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ"}}
    ]
  }],
  "temperature": 0,
  "response_format": {
    "type": "json_object",
    "schema": {
      "type": "object",
      "properties": {
        "甲方":       {"type": "string"},
        "乙方":       {"type": "string"},
        "合同总金额": {"type": "string"},
        "签订日期":   {"type": "string"}
      },
      "required": ["甲方", "乙方", "合同总金额", "签订日期"]
    }
  }
}
```

服务端用 GBNF 语法约束解码，**输出保证符合 schema**，没有代码块包裹，也不会漏字段。

> **这一节的 `response_format` 用法来自 llama.cpp 官方文档，尚未在本部署的 b9765 上实测。**
> 接入前先跑一次确认：如果返回的仍带代码块，改用 `{"type": "json_object"}`（不带 schema）
> 或退回客户端剥壳。

---

## 六、性能与并发（2026-07-30 实测，RTX A4000）

| 场景 | 耗时 |
|---|---|
| 纯文本（24 token 输入 / 46 输出） | < 1 秒，decode 54.9 tok/s |
| 单张整页扫描件（3044 token） | **7.5 秒**（prefill 606 tok/s，decode 53.7 tok/s） |
| 两路并发整页扫描件 | **11.5 秒**（串行会是 15 秒） |

**并发只提升约 30% 吞吐，不是翻倍。** 两个槽共享同一块 GPU 算力，视觉 prefill 是算力
密集型。后端并发数（如 `READ_CONCURRENCY`）**设 2，不要更高**——超过槽数只会排队，
还会挤占另一路的响应时间。

**超时设置**：单张整页图建议客户端超时 ≥ 60 秒。并发时排队会更久，批量任务建议 120 秒。

---

## 七、prompt cache：同一张图多轮追问几乎免费

服务端启用了 prompt cache。**同一张图第二次提问，视觉编码不会重做**：

| | prompt_tokens | cached_tokens | 耗时 |
|---|---|---|---|
| 首次提问 | 3044 | 0 | 7.5 秒 |
| 同图追问 | 3015 | **3011** | **1.4 秒** |

缓存是**前缀匹配**的，所以要吃到这个收益，请求必须共享前缀：

```
✅ 好：把图放在 content 数组靠前，问题放后面 / 用多轮 messages 追加提问
❌ 差：每次请求把不同的随机 ID、时间戳拼进图片之前的文本 —— 前缀一变，缓存全失效
```

**对合同抽取的实际意义**：与其一次让模型吐 20 个字段（容易漏、容易错），不如**分几轮各问
几个字段**——第二轮起每次只要 1～2 秒。准确率和延迟可以兼得。

跨文档命中率很低（每份扫描件不同），别指望。

---

## 八、错误处理

| 现象 | 原因 | 处理 |
|---|---|---|
| HTTP 500，消息含 `multimodal` / `mmproj` | 服务端没加载视觉模块 | 联系运维，见 README 排错 |
| HTTP 413 | nginx 反代的 `client_max_body_size` 太小 | 调大到 ≥ 8m |
| 输出被截断 | 超过每槽 8192 预算 | 减图、减历史、减 `max_tokens` |
| 响应很慢（> 30 秒） | 排队（并发数超过 2 个槽） | 客户端限流到 2 |
| 返回的 JSON 带 ` ```json ` 包裹 | 没用 `response_format` | 见第五节 |
| 模型说"看不到图片" | content 数组结构写错，或 `image_url.url` 不是合法 data URI | 检查 `data:image/jpeg;base64,` 前缀是否完整 |

---

## 九、代码示例

### Python — `requests`

```python
import base64, requests

BASE = "http://192.168.16.201:8080/v1"

def extract_fields(image_path: str, fields: list[str], timeout: int = 90) -> dict:
    with open(image_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    mime = "image/png" if image_path.lower().endswith(".png") else "image/jpeg"

    r = requests.post(f"{BASE}/chat/completions", timeout=timeout, json={
        "model": "qwen3.5-9b",
        "temperature": 0,
        "max_tokens": 800,
        "chat_template_kwargs": {"enable_thinking": False},
        "response_format": {
            "type": "json_object",
            "schema": {
                "type": "object",
                "properties": {k: {"type": "string"} for k in fields},
                "required": fields,
            },
        },
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": f"提取这份合同的：{'、'.join(fields)}。"},
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
        ]}],
    })
    r.raise_for_status()
    data = r.json()
    print("视觉 token:", data["usage"]["prompt_tokens"],
          "缓存命中:", data["usage"].get("prompt_tokens_details", {}).get("cached_tokens"))
    return data["choices"][0]["message"]["content"]
```

### Python — OpenAI SDK

服务是 OpenAI 兼容的，可以直接用官方 SDK（`api_key` 随便填，服务端不校验）：

```python
from openai import OpenAI

client = OpenAI(base_url="http://192.168.16.201:8080/v1", api_key="not-needed")

resp = client.chat.completions.create(
    model="qwen3.5-9b",
    temperature=0,
    max_tokens=800,
    timeout=90,
    messages=[{"role": "user", "content": [
        {"type": "text", "text": "提取甲方、乙方、合同总金额。"},
        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
    ]}],
    extra_body={"chat_template_kwargs": {"enable_thinking": False}},
)
print(resp.choices[0].message.content)
```

### 多轮追问（吃满 prompt cache）

```python
messages = [{"role": "user", "content": [
    {"type": "text", "text": "这是一份合同扫描件，接下来我会问你几个问题。"},
    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
]}]

for q in ["甲方和乙方分别是谁？", "合同总金额是多少？", "付款分几期，每期多少？"]:
    messages.append({"role": "user", "content": q})
    r = client.chat.completions.create(model="qwen3.5-9b", messages=messages,
                                       temperature=0, max_tokens=400)
    a = r.choices[0].message.content
    messages.append({"role": "assistant", "content": a})
    print(q, "→", a)
    # 第 2 轮起 cached_tokens 会很高，耗时从 ~7.5s 降到 ~1.5s
```

注意多轮会累积上下文，**每槽只有 8192**，长对话要裁剪历史（图必须留在最前面，否则缓存失效）。

### PDF → 图

```python
import subprocess, tempfile, pathlib

def pdf_to_images(pdf_path: str, dpi: int = 200) -> list[str]:
    """200 DPI 是甜点：A4 约 4900 视觉 token，服务端截到 3072；
    再高只会更慢，不会更准。"""
    out = tempfile.mkdtemp()
    subprocess.run(["pdftoppm", "-jpeg", "-r", str(dpi), pdf_path, f"{out}/page"], check=True)
    return sorted(str(p) for p in pathlib.Path(out).glob("page-*.jpg"))
```

### curl（仅调试用）

**请求体必须写进文件用 `--data-binary @文件`**，不能把 base64 拼进 `-d "..."`：
Linux 单个命令行参数上限 128 KiB，一张扫描件 base64 后有几百 KiB，内联会报
`参数列表过长`。写法见 [`README.md`](README.md) 的「视觉能力」章节。

> 这个限制**只影响 shell**。后端用 SDK / HTTP 客户端发请求不受影响——
> 请求体走 socket，不经过 `exec` 的参数表。

---

## 十、不要做的事

- ❌ **不要传远程 URL 或 `file://`** —— 内网取不到，`--media-path` 未启用
- ❌ **不要一次塞 2 张以上整页扫描件** —— 每槽 8192 装不下
- ❌ **不要为了"更清晰"用 300 DPI 以上** —— 超过 3072 token 会被降采样，只是更慢
- ❌ **不要把并发开到 2 以上** —— 只有 2 个槽，多的只会排队
- ❌ **不要在图片之前拼随机 ID / 时间戳** —— 破坏 prompt cache 前缀
- ❌ **不要用正则剥 ` ```json ` 代码块** —— 用 `response_format` 从源头解决
