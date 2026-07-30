#!/usr/bin/env bash
# 满载视觉请求 + 高频采样显存峰值 + 字段抽取准确率打分。
#
# 为什么需要这个脚本（而不是 test_vision.sh + watch nvidia-smi）：
#   1. test_vision.sh 用的是 224x224 的四象限色块图，只占约 1024 视觉 token（受
#      --image-min-tokens 抬到下限），显存几乎没有变化，测不出峰值。真实的整页
#      A4 扫描件在 200 DPI 下是 1654x2339 ≈ 387 万像素 ≈ 4900 token，会被
#      --image-max-tokens 截到 3072 —— 那才是满载。
#   2. `watch -n0.5` 每 500ms 采一次，而视觉编码可能几百毫秒就结束了，峰值经常被漏掉。
#      这里用 nvidia-smi -lms 50（单进程、50ms 一次）采样，采不到就退化成紧凑循环。
#
# 用法：
#   bash test_vision_peak.sh testdata/contract_scan.png
#   GPU_INDEX=1 BASE_URL=http://127.0.0.1:8081/v1 bash test_vision_peak.sh 我的扫描件.jpg
set -uo pipefail

IMG_PATH="${1:-}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080/v1}"
MODEL="${MODEL:-qwen3.5-9b}"
GPU_INDEX="${GPU_INDEX:-0}"
MAX_TOKENS="${MAX_TOKENS:-800}"

if [ -z "$IMG_PATH" ] || [ ! -f "$IMG_PATH" ]; then
  echo "用法: bash test_vision_peak.sh <图片路径>"
  echo "  例: bash test_vision_peak.sh testdata/contract_scan.png"
  exit 1
fi

case "$IMG_PATH" in
  *.png|*.PNG) MIME=image/png ;;
  *.jpg|*.jpeg|*.JPG|*.JPEG) MIME=image/jpeg ;;
  *.bmp|*.BMP) MIME=image/bmp ;;
  *.gif|*.GIF) MIME=image/gif ;;
  *) echo "不支持的图片格式（支持 png/jpg/bmp/gif）: $IMG_PATH"; exit 1 ;;
esac

BYTES=$(stat -c %s "$IMG_PATH")
echo "==> 图片: $IMG_PATH  ($((BYTES/1024)) KiB, $MIME)"

# 估算视觉 token：Qwen-VL 约 784 px ≈ 1 token（28x28 patch + 2x2 merge）
if command -v python3 >/dev/null 2>&1; then
  python3 - "$IMG_PATH" <<'PY' || true
import sys, struct
p = sys.argv[1]
d = open(p, 'rb').read(64)
w = h = None
if d[:8] == b'\x89PNG\r\n\x1a\n':
    w, h = struct.unpack('>II', d[16:24])
elif d[:2] == b'\xff\xd8':
    f = open(p, 'rb'); f.read(2)
    while True:
        b = f.read(1)
        if not b: break
        if b != b'\xff': continue
        m = f.read(1)
        while m == b'\xff': m = f.read(1)
        if m in (b'\xc0', b'\xc1', b'\xc2'):
            f.read(3); h, w = struct.unpack('>HH', f.read(4)); break
        ln = struct.unpack('>H', f.read(2))[0]; f.read(ln - 2)
if w and h:
    print(f"    尺寸 {w}x{h} = {w*h/1e6:.2f} 百万像素，估算视觉 token ≈ {w*h//784}"
          f"（超过 --image-max-tokens 会被截断到该上限）")
PY
fi

# ---- 显存采样（后台）----
SAMPLE_FILE=$(mktemp)
SAMPLER_PID=""
SAMPLER_MODE=""
start_sampler() {
  # 首选 -lms（单进程持续输出，50ms 一次）
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "$GPU_INDEX" -lms 50 \
    > "$SAMPLE_FILE" 2>/dev/null &
  SAMPLER_PID=$!
  sleep 0.5
  # 老版 nvidia-smi 不认 -lms：进程已退出且没产出 → 退化成紧凑循环
  if [ ! -s "$SAMPLE_FILE" ]; then
    kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null
    ( while :; do
        nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "$GPU_INDEX" 2>/dev/null
      done > "$SAMPLE_FILE" ) &
    SAMPLER_PID=$!
    SAMPLER_MODE="紧凑循环（-lms 不支持）"
    sleep 0.5
  else
    SAMPLER_MODE="-lms 50ms"
  fi
}
stop_sampler() {
  [ -n "$SAMPLER_PID" ] && { kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; }
}

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "!! 找不到 nvidia-smi，跳过显存测量，只做准确率测试"
else
  start_sampler
  BASELINE=$(sort -n "$SAMPLE_FILE" 2>/dev/null | tail -1)
  echo "==> GPU ${GPU_INDEX} 基线（请求前）: ${BASELINE:-?} MiB"
fi

# ---- 发请求 ----
PROMPT='这是一份合同扫描件。请仔细阅读后，只输出一个 JSON 对象，不要任何解释文字，字段为：甲方、乙方、合同编号、合同总金额、签订日期、乙方联系电话。'
PAYLOAD=$(mktemp)
{
  printf '{"model":"%s","max_tokens":%s,"temperature":0,"chat_template_kwargs":{"enable_thinking":false},' "$MODEL" "$MAX_TOKENS"
  printf '"messages":[{"role":"user","content":[{"type":"text","text":"%s"},' "$PROMPT"
  printf '{"type":"image_url","image_url":{"url":"data:%s;base64,' "$MIME"
  base64 -w0 "$IMG_PATH"
  printf '"}}]}]}'
} > "$PAYLOAD"
echo "==> 请求体 $(( $(stat -c %s "$PAYLOAD") / 1024 )) KiB（base64 比原图大约 1/3）"

echo "==> 发送中…"
T0=$(date +%s.%N)
RESP=$(curl -sS -w '\n%{http_code}' "${BASE_URL}/chat/completions" \
  -H "Content-Type: application/json" --data-binary "@$PAYLOAD")
RC=$?
T1=$(date +%s.%N)
rm -f "$PAYLOAD"

stop_sampler
if [ -s "$SAMPLE_FILE" ]; then
  PEAK=$(sort -n "$SAMPLE_FILE" | tail -1)
  NSAMPLES=$(wc -l < "$SAMPLE_FILE")
fi
rm -f "$SAMPLE_FILE"

[ $RC -ne 0 ] && { echo "FAIL: 请求发不出去"; exit 1; }

CODE=$(printf '%s' "$RESP" | tail -n1)
BODY=$(printf '%s' "$RESP" | sed '$d')
[ "$CODE" != "200" ] && { echo "FAIL: HTTP ${CODE}"; echo "$BODY"; exit 1; }

echo ""
echo "===== 显存 ====="
if [ -n "${PEAK:-}" ]; then
  echo "基线            : ${BASELINE} MiB"
  echo "峰值            : ${PEAK} MiB   （采样 ${NSAMPLES} 次，${SAMPLER_MODE}）"
  echo "视觉推理增量    : $(( PEAK - BASELINE )) MiB"
  TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i "$GPU_INDEX" 2>/dev/null)
  [ -n "$TOTAL" ] && echo "占比            : ${PEAK} / ${TOTAL} MiB  （剩余 $(( TOTAL - PEAK )) MiB）"
else
  echo "（未采到样本）"
fi

echo ""
echo "===== 耗时与 token ====="
awk -v a="$T0" -v b="$T1" 'BEGIN{printf "端到端          : %.1f 秒\n", b-a}'
printf '%s' "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
u = d.get('usage', {}); t = d.get('timings', {})
print(f\"prompt_tokens   : {u.get('prompt_tokens')}   ← 含视觉 token，这是 --image-max-tokens 实际生效值的证据\")
print(f\"completion      : {u.get('completion_tokens')}\")
if t.get('prompt_per_second'): print(f\"prefill         : {t['prompt_per_second']:.1f} tok/s\")
if t.get('predicted_per_second'): print(f\"decode          : {t['predicted_per_second']:.1f} tok/s\")
print()
print('===== 模型输出 =====')
print(d['choices'][0]['message']['content'])
" 2>/dev/null || { echo "(解析失败，原始响应)"; echo "$BODY"; }

# ---- 准确率打分（仅当用的是自带测试件）----
case "$IMG_PATH" in
  *contract_scan.png)
    echo ""
    echo "===== 字段准确率（对照 testdata/README.md 的标准答案）====="
    hits=0; total=0
    check() {
      total=$((total+1))
      if printf '%s' "$BODY" | grep -qF "$2"; then hits=$((hits+1)); printf '  ✓ %-12s %s\n' "$1" "$2"
      else printf '  ✗ %-12s 期望含 %s\n' "$1" "$2"; fi
    }
    check "甲方"       "杭州云图信息技术"
    check "乙方"       "南京恒信机电设备"
    check "合同编号"   "HT-2026-0715-037"
    check "合同总金额" "1,286,400"
    check "签订日期"   "2026"
    check "乙方电话"   "025-5217-9930"
    echo "  ---- ${hits}/${total} 命中 ----"
    echo "  金额和编号这类长数字串最能反映小字 OCR 质量；全中说明 3072 token 够用。"
    ;;
esac
