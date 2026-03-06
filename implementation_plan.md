# Docker Compose Deployment — Oracle Cloud

Deploy LogStack lên **Oracle Cloud** (Free Tier ARM: 4 vCPU / 24 GB RAM / 200 GB) bằng Docker Compose. Thoải mái tài nguyên hơn.

## Architecture

```
Mobile App ──HTTPS──→ Cloudflare Tunnel ──→ Log Collector (Node.js, :4000)
                                                    │
                                                    ↓ HTTP forward
                                               Fluent Bit (:8888)
                                                    │
                                                    ↓ opensearch output
                                               OpenSearch (:9200)
                                               Dashboards (:5601)

                                         Health Dashboard (:3000) ← Web theo dõi healthy
```

## Proposed Changes

### Docker Compose

#### [NEW] [docker-compose.yml](file:///Users/vothong/Documents/hdbank/log-monitor/colector/docker-compose.yml)

6 services — thoải mái RAM trên Oracle Cloud:

| Service | Image | RAM | Ports |
|---|---|---|---|
| `opensearch` | `opensearchproject/opensearch:2.18.0` | 1.5 GB (`-Xms512m -Xmx512m`) | 9200 |
| `dashboards` | `opensearchproject/opensearch-dashboards:2.18.0` | 512 MB | 5601 |
| `log-collector` | build [./Dockerfile](file:///Users/vothong/Documents/hdbank/log-monitor/colector/Dockerfile) (production mode) | 256 MB | 4000 |
| `fluent-bit` | `fluent/fluent-bit:3.0` | 128 MB | 8888 (internal) |
| `cloudflared` | `cloudflare/cloudflared:latest` | 128 MB | — |
| `health-dashboard` | Nginx + static HTML | 32 MB | 3000 |

---

### Health Dashboard

#### [NEW] [health-dashboard/index.html](file:///Users/vothong/Documents/hdbank/log-monitor/colector/health-dashboard/index.html)

Trang web nhỏ hiển thị trạng thái healthy của toàn bộ hệ thống:
- ✅/❌ Log Collector (API health)
- ✅/❌ OpenSearch (cluster health)
- ✅/❌ Fluent Bit (metrics)
- ✅/❌ Dashboards (status)
- Hiển thị: uptime, buffer size, cluster status, tổng logs
- Auto refresh mỗi 30 giây

#### [NEW] [health-dashboard/nginx.conf](file:///Users/vothong/Documents/hdbank/log-monitor/colector/health-dashboard/nginx.conf)

Nginx config làm reverse proxy, cho phép dashboard gọi API health của các service khác (tránh CORS).

---

### Log Collector

#### [MODIFY] [app.ts](file:///Users/vothong/Documents/hdbank/log-monitor/colector/src/app.ts)

- Chạy **production mode** (`NODE_ENV=production`)
- Thay [bulkIndexToOpenSearch()](file:///Users/vothong/Documents/hdbank/log-monitor/colector/src/app.ts#123-159) → `forwardToFluentBit()` (HTTP POST tới `http://fluent-bit:8888`)
- Bỏ buffer/flush logic (Fluent Bit tự buffer)
- Giữ nguyên: rate limiter, validation, health/metrics endpoints

---

### Fluent Bit

#### [NEW] [fluent-bit/fluent-bit-vps.conf](file:///Users/vothong/Documents/hdbank/log-monitor/colector/fluent-bit/fluent-bit-vps.conf)

Config Fluent Bit cho VPS:
- **INPUT**: HTTP (:8888) — nhận log từ Log Collector
- **OUTPUT**: OpenSearch (`https://opensearch:9200`) — ghi trực tiếp
- Bỏ file tail, bỏ stdout

---

### VPS Setup

#### [NEW] [deploy-vps.sh](file:///Users/vothong/Documents/hdbank/log-monitor/colector/deploy-vps.sh)

Script setup Oracle Cloud VPS:
1. Cài Docker + Docker Compose
2. Setup firewall (iptables/UFW)
3. `docker compose up -d`

#### [NEW] [.env.example](file:///Users/vothong/Documents/hdbank/log-monitor/colector/.env.example)

File env mẫu (passwords, Cloudflare token, domain).

## Verification Plan

### Manual Verification
1. `docker compose up -d` — kiểm tra tất cả services start thành công
2. `curl http://localhost:4000/health` — Log Collector OK
3. Gửi test log và kiểm tra OpenSearch nhận được
4. Truy cập `http://localhost:3000` — xem Health Dashboard
