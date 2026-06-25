#!/usr/bin/env bash
# 在 Ubuntu 22.04 GPU 服务器上准备 Docker + NVIDIA Container Toolkit。
# 前提：NVIDIA 驱动已安装（你这台是 535，nvidia-smi 正常）。本脚本不碰驱动。
#
# 用法：
#   bash deploy/docker/setup_docker_gpu.sh
#
# 完成后会跑一个 GPU 容器自检（nvidia-smi in container）。
set -euo pipefail

echo "==> 1/4 检查 NVIDIA 驱动"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "未检测到 nvidia-smi。请先确认主机 NVIDIA 驱动已安装。" >&2
  exit 1
fi
nvidia-smi

echo "==> 2/4 安装 Docker Engine（若已装则跳过）"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sudo sh
else
  echo "Docker 已安装：$(docker --version)"
fi

echo "==> 3/4 安装 NVIDIA Container Toolkit"
if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
else
  echo "nvidia-container-toolkit 已安装。"
fi

echo "==> 4/4 GPU 容器自检"
# 用与服务相同的镜像基底验证 GPU 是否能被容器看到。
sudo docker run --rm --gpus '"device=0"' nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi

echo ""
echo "完成。接下来："
echo "  cd deploy/docker"
echo "  cp .env.docker.example .env   # 按需改 MODELS_DIR / MODEL_FILE"
echo "  docker compose up -d"
echo ""
echo "（提示：若想免 sudo 跑 docker，执行 'sudo usermod -aG docker \$USER' 后重新登录）"
