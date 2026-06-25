#!/usr/bin/env bash
# 验证容器内 Qwen3.5-9B 服务是否跑通（对齐 Windows 版 test_windows_api.ps1）。
#
# 用法：
#   bash deploy/docker/test_api.sh
#   BASE_URL=http://127.0.0.1:8081/v1 bash deploy/docker/test_api.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080/v1}"
MODEL="${MODEL:-qwen3.5-9b}"

echo "==> /v1/models"
curl -fsS "${BASE_URL}/models" || { echo "服务未就绪，先看 'docker compose logs -f'"; exit 1; }
echo ""

echo "==> /v1/chat/completions"
curl -fsS "${BASE_URL}/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"请用一句话说明你是谁，并说明你是否可以用于合同检索。\"}
    ],
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }"
echo ""
echo ""
echo "==> 显存占用（确认模型确实在 GPU 上，应见 ~8-9GB）"
nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv
