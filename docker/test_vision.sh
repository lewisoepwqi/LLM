#!/usr/bin/env bash
# 视觉冒烟测试：确认 llama-server 真的走通了视觉栈（mmproj 已加载且模型能读到图）。
#
# 为什么不只断言"请求没报错"：视觉请求与纯文本请求走同一个 /v1/chat/completions，
# 纯文本是向后兼容的，所以一个 mmproj 未加载或格式写错的请求也可能返回一段看似正常
# 的文本回复。这里用一张四象限纯色图断言回答里至少命中 2 种颜色 —— 模型没真正读到
# 图时不可能瞎猜对。
#
# 用法：
#   bash docker/test_vision.sh
#   BASE_URL=http://127.0.0.1:8081/v1 bash docker/test_vision.sh
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080/v1}"
MODEL="${MODEL:-qwen3.5-9b}"

# 224x224 PNG，四象限：左上红 / 右上绿 / 左下蓝 / 右下黄。610 字节，内嵌以保持脚本自包含。
IMG_B64="iVBORw0KGgoAAAANSUhEUgAAAOAAAADgCAIAAACVT/22AAACKUlEQVR42u3SwQkAMBDDsOy/dLpEHkcReAKjNNEwCwSoBKgAlQCVABWgEqACVAJUAlSASoAKUAlQCVABKgEqQCVAJUAFqASoALVAgEqAClAJUAlQASoBKkAlQCVABagEqACVAJUAFaASoAJUAlQCVIBKgApQCVAJUAEqASoBKkAlQAWoBKgEqACVABWgEqASoAJUAlSASoBKgApQCVABKgEqASpAJUAlQAWoBKgAlQCVABWgEqACVAJUAlSASoAKUAlQCVABKgEqQCVAJUAFqASoBKgAlQAVoBKgEqACVAJUgEqASoAKUAlQASoB+vVQD6a10TBAAQUUUAEKKKACFFBABSiggAIqQAEFVIACCqgABRRQIQUooIAKUEABFaCAAipAAQUUUAEKKKACFFBABSiggAKKFKCAAipAAQVUgAIKqAAFFFBABSiggApQQAEVoIACCihVgAIKqAAFFFABCiigAhRQQAEVoIACKkABBVSAAgoooFQBCiigAhRQQAUooIAKUEABBVSAAgqoAAUUUAEKKKCAUgUooIAKUEABFaCAAipAAQUUUAEKKKACFFBABSiggAJKFaCAAipAAQVUgAIKqAAFFFBABSiggApQQAEVoIACCqgABRRQAQoooAIUUEAFKKCAAipAAQVUgAIKqAAFFFBABSiggApQQAEVoIACKkABBRRQAQoooAIUUEAFKKCAAipAAQVUgAIKqAAFFFABCiiggArQUz0MTBlNkfzOVgAAAABJRU5ErkJggg=="

echo "==> 视觉冒烟测试 (${BASE_URL})"

resp=$(curl -sS -w '\n%{http_code}' "${BASE_URL}/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": [
      {\"type\": \"text\", \"text\": \"这张图被平均分成四个方块。请只回答这四个方块分别是什么颜色，用中文颜色词，不要解释。\"},
      {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,${IMG_B64}\"}}
    ]}],
    \"max_tokens\": 64,
    \"temperature\": 0,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }") || { echo "FAIL: 请求发不出去（服务没起？先看 docker compose logs -f）"; exit 1; }

code=$(printf '%s' "$resp" | tail -n1)
body=$(printf '%s' "$resp" | sed '$d')

if [ "$code" != "200" ]; then
  echo "FAIL: HTTP ${code}"
  echo "$body"
  echo "提示：报 multimodal / mmproj 相关错误 = --mmproj 没配上，或镜像 build 低于 b9222。"
  exit 1
fi

echo "响应：$body"

# 直接在响应体里数颜色词。提示词本身不含任何颜色词，所以不会有假阳性。
hits=0
for c in 红 绿 蓝 黄; do
  case "$body" in *"$c"*) hits=$((hits+1));; esac
done
echo "命中颜色数：${hits}/4"

if [ "$hits" -lt 2 ]; then
  echo "FAIL: 只命中 ${hits} 种颜色（阈值 2），视觉栈可能未真正生效。"
  exit 1
fi

echo "PASS: 视觉栈已生效"
