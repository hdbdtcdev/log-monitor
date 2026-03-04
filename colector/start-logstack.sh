#!/usr/bin/env bash
# ============================================================
# start-logstack.sh — Khởi động LogStack mỗi ngày
# Copy về home: cp start-logstack.sh ~/start-logstack.sh
# Cấp quyền:    chmod +x ~/start-logstack.sh
# Chạy:         ~/start-logstack.sh
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ── Bước 1: Start k3d cluster ─────────────────────────────
log "Starting k3d cluster..."
k3d cluster start logging-cluster 2>/dev/null || warn "Cluster đã chạy rồi"
kubectl config use-context k3d-logging-cluster
ok "Cluster ready"

# ── Bước 2: Chờ pods ready ────────────────────────────────
log "Chờ pods khởi động..."
kubectl wait pod --all -n logging \
  --for=condition=ready \
  --timeout=90s 2>/dev/null || warn "Một số pods chưa ready — kiểm tra: kubectl get pods -n logging"
ok "Pods ready"

# ── Bước 3: Kill port-forward cũ nếu còn ─────────────────
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1

# ── Bước 4: Start port-forwards ──────────────────────────
log "Starting port-forwards..."
kubectl port-forward svc/log-collector 4000:80 -n logging &>/dev/null &
kubectl port-forward svc/opensearch-dashboards 5601:5601 -n logging &>/dev/null &
kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n logging &>/dev/null &
sleep 3
ok "Port-forwards running"

# ── Bước 5: Start Cloudflare tunnel ──────────────────────
log "Starting Cloudflare tunnel..."
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1
cloudflared tunnel run logstack-tunnel &>/tmp/cloudflared.log &
sleep 3

# Kiểm tra tunnel đang chạy
if pgrep -f "cloudflared tunnel" > /dev/null; then
  ok "Cloudflare tunnel running"
else
  warn "Tunnel chưa start — chạy thủ công: cloudflared tunnel run logstack-tunnel"
fi

# ── Tóm tắt ──────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           🚀 LOGSTACK READY!                         ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║  LOCAL:                                               ║${NC}"
echo -e "${GREEN}║  • API:        http://localhost:4000/health           ║${NC}"
echo -e "${GREEN}║  • Dashboard:  http://localhost:5601                  ║${NC}"
echo -e "${GREEN}║  • OpenSearch: http://localhost:9200                  ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║  PUBLIC (Cloudflare Tunnel):                          ║${NC}"
echo -e "${GREEN}║  • API:        https://api.logstack.store/health      ║${NC}"
echo -e "${GREEN}║  • Dashboard:  https://dashboard.logstack.store       ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"