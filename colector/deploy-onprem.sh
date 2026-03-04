#!/usr/bin/env bash
# ============================================================
# deploy-onprem.sh — Deploy LogStack On-Prem hoàn chỉnh
# Bao gồm: OpenSearch (security ON) + Dashboards + Log Collector
#          + Phân quyền RBAC + Cloudflare Tunnel
#
# Cách dùng:
#   chmod +x deploy-onprem.sh
#   ./deploy-onprem.sh              # Deploy lần đầu
#   ./deploy-onprem.sh --clean      # Xóa hết và deploy lại
#   ./deploy-onprem.sh --skip-tunnel # Bỏ qua bước cloudflared
# ============================================================

set -euo pipefail

# ── Màu sắc ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
            echo -e "${CYAN}  $1${NC}"; \
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Config — chỉnh tại đây ───────────────────────────────────
CLUSTER_NAME="logging-cluster"
NAMESPACE="logging"
IMAGE_NAME="log-collector"
IMAGE_TAG="1.0.0"
DOCKER_HUB_USER="shinichi495"
COLLECTOR_DIR="./collector"
CF_TUNNEL_NAME="logstack-tunnel"
DOMAIN="logstack.store"

# Passwords — đổi trước khi deploy production!
OPENSEARCH_ADMIN_PASSWORD='LogStack#2026$X'
DEV_USER_PASSWORD='Mobile#Logs2026$'

# ── Flags ────────────────────────────────────────────────────
SKIP_TUNNEL=false
for arg in "$@"; do
  [[ "$arg" == "--skip-tunnel" ]] && SKIP_TUNNEL=true
  if [[ "$arg" == "--clean" ]]; then
    warn "Clean mode — xóa toàn bộ cluster cũ..."
    k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true
    success "Đã xóa cluster cũ"
  fi
done

# ══════════════════════════════════════════════════════════════
# BƯỚC 1: Kiểm tra dependencies
# ══════════════════════════════════════════════════════════════
step "BƯỚC 1/9: Kiểm tra dependencies"

for cmd in docker kubectl helm k3d cloudflared curl; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd chưa được cài. Chạy: brew install $cmd"
  fi
  success "$cmd ✓"
done

if ! docker ps &>/dev/null; then
  error "Docker Desktop chưa chạy!"
fi

# ══════════════════════════════════════════════════════════════
# BƯỚC 2: Tạo k3d cluster
# ══════════════════════════════════════════════════════════════
step "BƯỚC 2/9: Tạo k3d cluster"

if k3d cluster list | grep -q "$CLUSTER_NAME"; then
  warn "Cluster '$CLUSTER_NAME' đã tồn tại — start lại"
  k3d cluster start "$CLUSTER_NAME" 2>/dev/null || true
else
  k3d cluster create "$CLUSTER_NAME" \
    --port "9200:9200@loadbalancer" \
    --port "5601:5601@loadbalancer" \
    --port "4000:4000@loadbalancer"
  success "Cluster '$CLUSTER_NAME' đã được tạo ✓"
fi

kubectl config use-context "k3d-$CLUSTER_NAME"
success "Context: k3d-$CLUSTER_NAME ✓"

# ══════════════════════════════════════════════════════════════
# BƯỚC 3: Namespace + Helm repo
# ══════════════════════════════════════════════════════════════
step "BƯỚC 3/9: Setup namespace và Helm repo"

kubectl create namespace "$NAMESPACE" 2>/dev/null || warn "Namespace đã tồn tại"
helm repo add opensearch https://opensearch-project.github.io/helm-charts 2>/dev/null || true
helm repo update
success "Helm repo OpenSearch ✓"

# ══════════════════════════════════════════════════════════════
# BƯỚC 4: Deploy OpenSearch với Security BẬT
# ══════════════════════════════════════════════════════════════
step "BƯỚC 4/9: Deploy OpenSearch (Security ON)"

# Dọn dẹp release cũ nếu còn
if helm list -n "$NAMESPACE" | grep -q "^opensearch "; then
  warn "Tìm thấy OpenSearch release cũ — uninstall..."
  helm uninstall opensearch -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete secret -n "$NAMESPACE" \
    $(kubectl get secret -n "$NAMESPACE" 2>/dev/null | grep "^sh.helm.release.*opensearch[^-]" | awk '{print $1}') \
    2>/dev/null || true
  sleep 5
fi

log "Deploying OpenSearch với security..."
helm install opensearch opensearch/opensearch \
  --namespace "$NAMESPACE" \
  --set replicas=1 \
  --set singleNode=true \
  --set opensearchJavaOpts="-Xms512m -Xmx512m" \
  --set-string "extraEnvs[0].name=OPENSEARCH_INITIAL_ADMIN_PASSWORD" \
  --set-string "extraEnvs[0].value=${OPENSEARCH_ADMIN_PASSWORD}"

log "Chờ OpenSearch khởi động (2-3 phút)..."
kubectl wait pod \
  -l app.kubernetes.io/name=opensearch \
  -n "$NAMESPACE" \
  --for=condition=ready \
  --timeout=300s
success "OpenSearch đang chạy ✓"

# ══════════════════════════════════════════════════════════════
# BƯỚC 5: Setup RBAC — Roles và Users
# ══════════════════════════════════════════════════════════════
step "BƯỚC 5/9: Setup RBAC (Roles & Users)"

# Port forward tạm để gọi API
log "Port forwarding OpenSearch để setup RBAC..."
kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n "$NAMESPACE" &>/dev/null &
PF_PID=$!
sleep 8

# Chờ OpenSearch security API ready
for i in {1..10}; do
  if curl -s -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" -k \
    https://localhost:9200/_cluster/health &>/dev/null; then
    break
  fi
  log "Chờ security API ready... ($i/10)"
  sleep 5
done

# Gán all_access cho admin
log "Gán all_access cho admin..."
curl -s -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" -k -X PUT \
  https://localhost:9200/_plugins/_security/api/rolesmapping/all_access \
  -H 'Content-Type: application/json' \
  -d '{"users": ["admin"]}' | grep -q "CREATED\|OK\|updated" && \
  success "admin → all_access ✓" || warn "all_access mapping có thể đã tồn tại"

# Tạo role dev_role
log "Tạo dev_role..."
curl -s -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" -k -X PUT \
  https://localhost:9200/_plugins/_security/api/roles/dev_role \
  -H 'Content-Type: application/json' \
  -d '{
    "description": "Dev role - chi xem mobile-logs",
    "index_permissions": [{
      "index_patterns": ["mobile-logs-*"],
      "allowed_actions": ["read","indices:data/read/search","indices:data/read/get"]
    }],
    "cluster_permissions": ["cluster_composite_ops_ro"]
  }' | grep -q "CREATED\|OK\|updated" && \
  success "dev_role created ✓" || warn "dev_role có thể đã tồn tại"

# Tạo user dev
log "Tạo user dev..."
curl -s -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" -k -X PUT \
  https://localhost:9200/_plugins/_security/api/internalusers/dev \
  -H 'Content-Type: application/json' \
  -d "{
    \"password\": \"${DEV_USER_PASSWORD}\",
    \"backend_roles\": [],
    \"attributes\": {}
  }" | grep -q "CREATED\|OK\|updated" && \
  success "user dev created ✓" || warn "user dev có thể đã tồn tại"

# Gán dev_role cho user dev
log "Gán dev_role cho user dev..."
curl -s -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" -k -X PUT \
  https://localhost:9200/_plugins/_security/api/rolesmapping/dev_role \
  -H 'Content-Type: application/json' \
  -d '{"users": ["dev"]}' | grep -q "CREATED\|OK\|updated" && \
  success "dev → dev_role ✓" || warn "dev_role mapping có thể đã tồn tại"

# Dừng port forward tạm
kill $PF_PID 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
# BƯỚC 6: Deploy OpenSearch Dashboards
# ══════════════════════════════════════════════════════════════
step "BƯỚC 6/9: Deploy OpenSearch Dashboards"

# Dọn dẹp release cũ
if helm list -n "$NAMESPACE" | grep -q "opensearch-dashboards"; then
  warn "Tìm thấy Dashboards release cũ — uninstall..."
  helm uninstall opensearch-dashboards -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete secret -n "$NAMESPACE" \
    $(kubectl get secret -n "$NAMESPACE" 2>/dev/null | grep "opensearch-dashboards" | awk '{print $1}') \
    2>/dev/null || true
  sleep 5
fi

helm install opensearch-dashboards opensearch/opensearch-dashboards \
  --namespace "$NAMESPACE" \
  --set opensearchHosts="https://opensearch-cluster-master:9200" \
  --set-string "extraEnvs[0].name=OPENSEARCH_USERNAME" \
  --set-string "extraEnvs[0].value=admin" \
  --set-string "extraEnvs[1].name=OPENSEARCH_PASSWORD" \
  --set-string "extraEnvs[1].value=${OPENSEARCH_ADMIN_PASSWORD}"

log "Chờ Dashboards khởi động..."
kubectl wait pod \
  -l app.kubernetes.io/name=opensearch-dashboards \
  -n "$NAMESPACE" \
  --for=condition=ready \
  --timeout=180s
success "OpenSearch Dashboards đang chạy ✓"

# ══════════════════════════════════════════════════════════════
# BƯỚC 7: Build và deploy Log Collector
# ══════════════════════════════════════════════════════════════
step "BƯỚC 7/9: Deploy Log Collector"

if [[ ! -f "$COLLECTOR_DIR/Dockerfile" ]]; then
  error "Không tìm thấy Dockerfile tại $COLLECTOR_DIR/Dockerfile"
fi

log "Building Docker image..."
docker build -t "$IMAGE_NAME:$IMAGE_TAG" "$COLLECTOR_DIR"
success "Image built ✓"

log "Import image vào k3d..."
k3d image import "$IMAGE_NAME:$IMAGE_TAG" -c "$CLUSTER_NAME"
success "Image imported ✓"

log "Tạo secret cho Log Collector..."
kubectl create secret generic opensearch-secret \
  --from-literal=log-collector-password="${OPENSEARCH_ADMIN_PASSWORD}" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
success "Secret created ✓"

log "Deploy Log Collector..."
kubectl apply -f "$COLLECTOR_DIR/k8s/deployment.yaml"
kubectl wait pod \
  -l app=log-collector \
  -n "$NAMESPACE" \
  --for=condition=ready \
  --timeout=120s
success "Log Collector đang chạy ✓"

# ══════════════════════════════════════════════════════════════
# BƯỚC 8: Start port-forwards
# ══════════════════════════════════════════════════════════════
step "BƯỚC 8/9: Start port-forwards"

pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2

kubectl port-forward svc/log-collector 4000:80 -n "$NAMESPACE" &>/dev/null &
kubectl port-forward svc/opensearch-dashboards 5601:5601 -n "$NAMESPACE" &>/dev/null &
kubectl port-forward svc/opensearch-cluster-master 9200:9200 -n "$NAMESPACE" &>/dev/null &
sleep 5
success "Port-forwards running ✓"

# ══════════════════════════════════════════════════════════════
# BƯỚC 9: Start Cloudflare Tunnel
# ══════════════════════════════════════════════════════════════
step "BƯỚC 9/9: Start Cloudflare Tunnel"

if [[ "$SKIP_TUNNEL" == "true" ]]; then
  warn "Bỏ qua Cloudflare Tunnel (--skip-tunnel)"
else
  pkill -f "cloudflared tunnel" 2>/dev/null || true
  sleep 1

  if [[ ! -f ~/.cloudflared/config.yml ]]; then
    warn "Chưa có ~/.cloudflared/config.yml — bỏ qua tunnel"
    warn "Setup tunnel thủ công: cloudflared tunnel run $CF_TUNNEL_NAME"
  else
    cloudflared tunnel run "$CF_TUNNEL_NAME" &>/tmp/cloudflared.log &
    sleep 5
    if pgrep -f "cloudflared tunnel" > /dev/null; then
      success "Cloudflare Tunnel running ✓"
    else
      warn "Tunnel chưa start — chạy thủ công: cloudflared tunnel run $CF_TUNNEL_NAME"
    fi
  fi
fi

# ── Verify ───────────────────────────────────────────────────
log "Verify hệ thống..."

HEALTH=$(curl -s -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" -k \
  https://localhost:9200/_cluster/health | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")

COL=$(curl -s http://localhost:4000/health | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")

# ── Tóm tắt ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           🎉 LOGSTACK DEPLOYED SUCCESSFULLY!             ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}║  OpenSearch health : ${HEALTH}                                  ${NC}"
echo -e "${GREEN}║  Log Collector     : ${COL}                                     ${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}║  LOCAL:                                                   ║${NC}"
echo -e "${GREEN}║  • API        : http://localhost:4000/health              ║${NC}"
echo -e "${GREEN}║  • Dashboard  : http://localhost:5601                     ║${NC}"
echo -e "${GREEN}║  • OpenSearch : https://localhost:9200                    ║${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}║  PUBLIC (Cloudflare Tunnel):                              ║${NC}"
echo -e "${GREEN}║  • API        : https://api.${DOMAIN}/health        ║${NC}"
echo -e "${GREEN}║  • Dashboard  : https://dashboard.${DOMAIN}         ║${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}║  USERS:                                                   ║${NC}"
echo -e "${GREEN}║  • admin : LogStack#2026\$X  (toàn quyền)                ║${NC}"
echo -e "${GREEN}║  • dev   : Mobile#Logs2026\$ (chỉ mobile-logs-*)          ║${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"