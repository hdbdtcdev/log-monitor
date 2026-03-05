#!/bin/bash
set -e

echo "══════════════════════════════════════"
echo "  LogStack — Oracle Cloud VPS Setup"
echo "══════════════════════════════════════"

# ─── 1. Cài Git ───
if command -v git &>/dev/null; then
  echo "✓ Git đã cài: $(git --version)"
else
  echo "→ Cài Git..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y git
  elif command -v yum &>/dev/null; then
    sudo yum install -y git
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y git
  fi
  echo "✓ Git đã cài xong"
fi

# ─── 2. Cài Docker ───
if command -v docker &>/dev/null; then
  echo "✓ Docker đã cài: $(docker --version)"
else
  echo "→ Cài Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "✓ Docker đã cài xong"
fi

# ─── 3. Kiểm tra Docker Compose (đi kèm Docker mới) ───
if docker compose version &>/dev/null; then
  echo "✓ Docker Compose: $(docker compose version --short)"
else
  echo "✗ Docker Compose không có. Cài Docker bản mới nhất lại."
  exit 1
fi

# ─── 4. Tăng vm.max_map_count cho OpenSearch ───
CURRENT_MAP_COUNT=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if [ "$CURRENT_MAP_COUNT" -lt 262144 ]; then
  echo "→ Set vm.max_map_count=262144 (yêu cầu của OpenSearch)..."
  sudo sysctl -w vm.max_map_count=262144
  echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf >/dev/null
  echo "✓ Đã set"
else
  echo "✓ vm.max_map_count=$CURRENT_MAP_COUNT (OK)"
fi

# ─── 5. Mở firewall (iptables) ───
echo "→ Mở ports: 4000 (API), 5601 (Dashboards), 3000 (Health)..."
sudo iptables -I INPUT -p tcp --dport 4000 -j ACCEPT 2>/dev/null || true
sudo iptables -I INPUT -p tcp --dport 5601 -j ACCEPT 2>/dev/null || true
sudo iptables -I INPUT -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true

# ─── 6. Tạo .env nếu chưa có ───
if [ ! -f .env ]; then
  echo "→ Tạo .env từ .env.example..."
  cp .env.example .env
  echo "⚠  Hãy sửa .env trước khi chạy docker compose!"
  echo "   nano .env"
fi

# ─── 7. Khởi chạy ───
echo ""
echo "══════════════════════════════════════"
echo "  Setup xong! Chạy lệnh sau:"
echo ""
echo "  1. nano .env          # sửa password + Cloudflare token"
echo "  2. docker compose up -d"
echo "  3. docker compose ps  # kiểm tra"
echo "══════════════════════════════════════"
