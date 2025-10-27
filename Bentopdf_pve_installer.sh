#!/usr/bin/env bash

# BentoPDF 一鍵安裝腳本 - 優化版
# 適用於已存在的 LXC 容器

set -e  # 遇到錯誤立即停止

# ==================== 配色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 函數定義 ====================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_step() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${YELLOW}========================================${NC}"
}

# ==================== 參數檢查 ====================
if [ $# -eq 0 ]; then
    echo "使用方法: $0 <容器ID>"
    echo "範例: $0 124"
    exit 1
fi

CTID=$1

# 檢查是否為 root
if [ "$EUID" -ne 0 ]; then 
    log_error "請使用 root 權限執行此腳本"
    exit 1
fi

# 檢查容器是否存在
if ! pct status $CTID >/dev/null 2>&1; then
    log_error "容器 $CTID 不存在"
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════╗"
echo "║     BentoPDF 一鍵安裝腳本 v2.0        ║"
echo "║        容器 ID: $CTID                   ║"
echo "╚════════════════════════════════════════╝"
echo ""

# ==================== 步驟 1: 修復網路 ====================
log_step "步驟 1/6: 修復網路配置"

log_info "停止容器..."
pct stop $CTID 2>/dev/null || true
sleep 2

log_info "配置網路（DHCP）..."
pct set $CTID -net0 name=eth0,bridge=vmbr0,firewall=1,ip=dhcp

log_info "啟動容器..."
pct start $CTID
sleep 8

log_info "等待網路就緒..."
NETWORK_OK=false
for i in {1..20}; do
    if pct exec $CTID -- ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        NETWORK_OK=true
        break
    fi
    echo -ne "  嘗試 $i/20...\r"
    sleep 2
done

if [ "$NETWORK_OK" = true ]; then
    CONTAINER_IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
    log_success "網路連線成功！容器 IP: $CONTAINER_IP"
else
    log_error "網路連線失敗"
    echo ""
    echo "請手動檢查網路設定："
    echo "  1. pct exec $CTID -- ip addr"
    echo "  2. pct exec $CTID -- ping 8.8.8.8"
    exit 1
fi

# ==================== 步驟 2: 配置 DNS ====================
log_step "步驟 2/6: 配置 DNS"

pct exec $CTID -- bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 168.95.1.1
EOF'

log_success "DNS 配置完成"

# ==================== 步驟 3: 更新系統 ====================
log_step "步驟 3/6: 更新系統"

log_info "更新套件列表..."
pct exec $CTID -- apt-get update -qq 2>&1 | grep -v "^Get:" || true

log_info "升級系統套件（可能需要幾分鐘）..."
pct exec $CTID -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq' 2>&1 | grep -v "^Reading" || true

log_info "安裝基礎工具..."
pct exec $CTID -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget ca-certificates' 2>&1 | grep -v "^Selecting" || true

log_success "系統更新完成"

# ==================== 步驟 4: 安裝 Docker ====================
log_step "步驟 4/6: 安裝 Docker"

# 檢查 Docker 是否已安裝
if pct exec $CTID -- docker --version >/dev/null 2>&1; then
    log_info "Docker 已安裝，跳過此步驟"
else
    log_info "下載並安裝 Docker（需要幾分鐘）..."
    pct exec $CTID -- bash -c 'curl -fsSL https://get.docker.com | sh' >/dev/null 2>&1
    
    log_info "啟動 Docker 服務..."
    pct exec $CTID -- systemctl enable docker >/dev/null 2>&1
    pct exec $CTID -- systemctl start docker
    
    # 驗證安裝
    if pct exec $CTID -- docker --version >/dev/null 2>&1; then
        DOCKER_VERSION=$(pct exec $CTID -- docker --version)
        log_success "Docker 安裝成功: $DOCKER_VERSION"
    else
        log_error "Docker 安裝失敗"
        exit 1
    fi
fi

# 檢查 Docker Compose
if ! pct exec $CTID -- docker compose version >/dev/null 2>&1; then
    log_info "安裝 Docker Compose Plugin..."
    pct exec $CTID -- bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin' 2>&1 | grep -v "^Selecting" || true
fi

log_success "Docker 環境準備完成"

# ==================== 步驟 5: 部署 BentoPDF ====================
log_step "步驟 5/6: 部署 BentoPDF"

log_info "創建工作目錄..."
pct exec $CTID -- mkdir -p /opt/bentopdf

log_info "創建 Docker Compose 配置..."
pct exec $CTID -- bash -c 'cat > /opt/bentopdf/docker-compose.yml << "EOF"
services:
  bentopdf:
    image: bentopdf/bentopdf:latest
    container_name: bentopdf
    ports:
      - "3000:8080"
    restart: unless-stopped
    environment:
      - TZ=Asia/Taipei
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF'

log_info "拉取 BentoPDF Docker 映像（需要幾分鐘）..."
pct exec $CTID -- bash -c 'cd /opt/bentopdf && docker compose pull' 2>&1 | grep -E "Pulling|Downloaded|digest:" || true

log_info "啟動 BentoPDF 容器..."
pct exec $CTID -- bash -c 'cd /opt/bentopdf && docker compose up -d'

log_info "等待容器啟動..."
sleep 8

log_success "BentoPDF 部署完成"

# ==================== 步驟 6: 驗證安裝 ====================
log_step "步驟 6/6: 驗證安裝"

if pct exec $CTID -- docker ps | grep -q bentopdf; then
    log_success "BentoPDF 容器運行中"
    
    # 測試服務
    log_info "測試服務回應..."
    sleep 3
    if pct exec $CTID -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null | grep -q "200\|302"; then
        log_success "服務回應正常"
    else
        log_info "服務可能還在啟動中，請稍後再試"
    fi
else
    log_error "BentoPDF 容器未運行"
    echo ""
    echo "查看容器狀態："
    pct exec $CTID -- docker ps -a
    echo ""
    echo "查看日誌："
    pct exec $CTID -- docker logs bentopdf 2>&1 | tail -20
    exit 1
fi

# ==================== 完成資訊 ====================
echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║                                                    ║"
echo "║          ✨ 安裝成功完成！✨                       ║"
echo "║                                                    ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "📍 存取資訊："
echo "   🌐 網址: ${GREEN}http://${CONTAINER_IP}:3000${NC}"
echo "   🆔 容器: ${BLUE}$CTID${NC}"
echo "   🐳 名稱: ${BLUE}bentopdf${NC}"
echo ""
echo "🔧 常用指令："
echo "   查看狀態:  ${BLUE}pct exec $CTID -- docker ps${NC}"
echo "   查看日誌:  ${BLUE}pct exec $CTID -- docker logs -f bentopdf${NC}"
echo "   重新啟動:  ${BLUE}pct exec $CTID -- docker restart bentopdf${NC}"
echo "   停止服務:  ${BLUE}pct exec $CTID -- docker stop bentopdf${NC}"
echo "   進入容器:  ${BLUE}pct enter $CTID${NC}"
echo ""
echo "📝 更新指令："
echo "   ${BLUE}pct exec $CTID -- bash -c 'cd /opt/bentopdf && docker compose pull && docker compose up -d'${NC}"
echo ""
echo "🎉 現在可以在瀏覽器中開啟 ${GREEN}http://${CONTAINER_IP}:3000${NC} 使用 BentoPDF！"
echo ""
