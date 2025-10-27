#!/usr/bin/env bash

# BentoPDF Proxmox VE LXC 容器自動安裝腳本 v2.0
# 改進版：增強網路檢測、錯誤處理和用戶互動

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# ==================== 應用程式配置 ====================
APP="BentoPDF"
var_tags="pdf;productivity"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="ubuntu"
var_version="24.04"
var_unprivileged="1"

# ==================== 顏色定義 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==================== 輔助函數 ====================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ==================== 網路檢測函數 ====================
wait_for_network() {
    local container_id=$1
    local max_attempts=30
    local attempt=1
    
    log_info "等待容器網路就緒..."
    
    while [ $attempt -le $max_attempts ]; do
        # 檢查容器是否有 IP
        if pct exec $container_id -- ip addr show eth0 2>/dev/null | grep -q "inet "; then
            # 檢查是否能 ping 通外部
            if pct exec $container_id -- ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
                local container_ip=$(pct exec $container_id -- hostname -I | awk '{print $1}')
                log_success "網路已就緒！容器 IP: $container_ip"
                return 0
            fi
        fi
        
        echo -ne "${YELLOW}[WAIT]${NC} 網路檢測中... (嘗試 $attempt/$max_attempts)\r"
        sleep 2
        ((attempt++))
    done
    
    log_error "網路連線逾時，請手動檢查網路設定"
    return 1
}

# ==================== 網路配置函數 ====================
configure_network() {
    local container_id=$1
    
    log_info "配置容器網路..."
    
    # 停止容器
    pct stop $container_id >/dev/null 2>&1
    sleep 2
    
    # 設定網路（DHCP）
    pct set $container_id -net0 name=eth0,bridge=vmbr0,firewall=1,ip=dhcp >/dev/null 2>&1
    
    # 啟動容器
    pct start $container_id >/dev/null 2>&1
    sleep 3
    
    # 等待網路就緒
    if wait_for_network $container_id; then
        return 0
    else
        log_warning "自動網路配置失敗，嘗試手動配置..."
        
        # 詢問用戶是否要手動設定靜態 IP
        read -p "是否要設定靜態 IP？(y/N): " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            read -p "輸入 IP 位址 (例如 192.168.1.122/24): " static_ip
            read -p "輸入閘道 (例如 192.168.1.1): " gateway
            
            pct stop $container_id
            pct set $container_id -net0 name=eth0,bridge=vmbr0,ip=$static_ip,gw=$gateway
            pct start $container_id
            sleep 3
            
            if wait_for_network $container_id; then
                return 0
            fi
        fi
        
        return 1
    fi
}

# ==================== DNS 配置函數 ====================
configure_dns() {
    local container_id=$1
    
    log_info "配置 DNS 伺服器..."
    
    pct exec $container_id -- bash -c "cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 168.95.1.1
EOF"
    
    # 測試 DNS
    if pct exec $container_id -- ping -c 1 -W 2 google.com >/dev/null 2>&1; then
        log_success "DNS 配置成功"
        return 0
    else
        log_warning "DNS 可能有問題，但繼續安裝..."
        return 0
    fi
}

# ==================== 更新腳本函數 ====================
function update_script() {
    header_info
    check_container_storage
    check_container_resources
    
    if [[ ! -f /etc/systemd/system/bentopdf.service ]]; then
        log_error "找不到 ${APP} 安裝！"
        exit 1
    fi
    
    log_info "正在更新 ${APP}..."
    
    # 停止服務
    systemctl stop bentopdf
    
    # 拉取最新的 Docker 映像
    docker pull bentopdf/bentopdf:latest
    
    # 重新啟動服務
    systemctl start bentopdf
    
    log_success "已成功更新 ${APP}"
    exit 0
}

# ==================== 系統設定函數 ====================
function default_settings() {
    local container_id=$1
    
    log_info "開始配置容器系統..."
    
    # 更新系統
    log_info "更新系統套件..."
    pct exec $container_id -- bash -c "apt-get update >/dev/null 2>&1"
    pct exec $container_id -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >/dev/null 2>&1"
    
    # 安裝基礎工具
    log_info "安裝必要工具..."
    pct exec $container_id -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget git ca-certificates gnupg lsb-release >/dev/null 2>&1"
    
    log_success "系統基礎配置完成"
}

# ==================== Docker 安裝函數 ====================
function install_docker() {
    local container_id=$1
    
    log_info "開始安裝 Docker..."
    
    # 創建 Docker GPG 金鑰目錄
    pct exec $container_id -- mkdir -p /etc/apt/keyrings
    
    # 添加 Docker GPG 金鑰
    log_info "添加 Docker GPG 金鑰..."
    pct exec $container_id -- bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    
    # 添加 Docker 軟體庫
    log_info "添加 Docker 軟體庫..."
    pct exec $container_id -- bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    
    # 更新套件列表
    pct exec $container_id -- apt-get update >/dev/null 2>&1
    
    # 安裝 Docker
    log_info "安裝 Docker 套件（這可能需要幾分鐘）..."
    pct exec $container_id -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin" || {
        log_error "Docker 安裝失敗"
        return 1
    }
    
    # 啟動並啟用 Docker
    pct exec $container_id -- systemctl enable docker >/dev/null 2>&1
    pct exec $container_id -- systemctl start docker
    
    # 驗證 Docker 安裝
    if pct exec $container_id -- docker --version >/dev/null 2>&1; then
        local docker_version=$(pct exec $container_id -- docker --version)
        log_success "Docker 安裝成功：$docker_version"
        return 0
    else
        log_error "Docker 安裝驗證失敗"
        return 1
    fi
}

# ==================== BentoPDF 安裝函數 ====================
function install_bentopdf() {
    local container_id=$1
    
    log_info "開始安裝 ${APP}..."
    
    # 創建工作目錄
    pct exec $container_id -- mkdir -p /opt/bentopdf
    
    # 創建 docker-compose.yml
    log_info "創建 Docker Compose 配置..."
    pct exec $container_id -- bash -c "cat > /opt/bentopdf/docker-compose.yml << 'EOF'
services:
  bentopdf:
    image: bentopdf/bentopdf:latest
    container_name: bentopdf
    ports:
      - '3000:8080'
    restart: unless-stopped
    environment:
      - TZ=Asia/Taipei
    healthcheck:
      test: [\"CMD\", \"wget\", \"--quiet\", \"--tries=1\", \"--spider\", \"http://localhost:8080\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF"
    
    # 拉取並啟動 BentoPDF
    log_info "拉取 BentoPDF Docker 映像（這可能需要幾分鐘）..."
    pct exec $container_id -- bash -c "cd /opt/bentopdf && docker compose pull" || {
        log_error "Docker 映像拉取失敗"
        return 1
    }
    
    log_info "啟動 BentoPDF 容器..."
    pct exec $container_id -- bash -c "cd /opt/bentopdf && docker compose up -d" || {
        log_error "BentoPDF 啟動失敗"
        return 1
    }
    
    # 等待容器啟動
    sleep 5
    
    # 創建系統服務
    log_info "創建系統服務..."
    pct exec $container_id -- bash -c "cat > /etc/systemd/system/bentopdf.service << 'EOF'
[Unit]
Description=BentoPDF Docker Container
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/bentopdf
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF"
    
    # 啟用服務
    pct exec $container_id -- systemctl daemon-reload
    pct exec $container_id -- systemctl enable bentopdf.service >/dev/null 2>&1
    
    # 驗證安裝
    if pct exec $container_id -- docker ps | grep -q bentopdf; then
        log_success "${APP} 安裝成功！"
        return 0
    else
        log_error "${APP} 安裝驗證失敗"
        return 1
    fi
}

# ==================== 顯示資訊函數 ====================
function display_info() {
    local container_id=$1
    local container_ip=$(pct exec $container_id -- hostname -I | awk '{print $1}')
    
    echo ""
    echo "=============================================="
    log_success "${APP} 安裝完成！"
    echo "=============================================="
    echo ""
    echo -e "${GREEN}📍 存取資訊：${NC}"
    echo -e "   🌐 存取網址: ${BLUE}http://${container_ip}:3000${NC}"
    echo -e "   🆔 容器 ID: ${BLUE}${container_id}${NC}"
    echo -e "   🐳 容器名稱: ${BLUE}bentopdf${NC}"
    echo ""
    echo -e "${GREEN}🔧 常用指令：${NC}"
    echo -e "   查看日誌:     ${BLUE}pct exec ${container_id} -- docker logs -f bentopdf${NC}"
    echo -e "   重新啟動:     ${BLUE}pct exec ${container_id} -- docker restart bentopdf${NC}"
    echo -e "   停止服務:     ${BLUE}pct exec ${container_id} -- docker stop bentopdf${NC}"
    echo -e "   更新版本:     ${BLUE}pct exec ${container_id} -- bash -c 'cd /opt/bentopdf && docker compose pull && docker compose up -d'${NC}"
    echo -e "   進入容器:     ${BLUE}pct enter ${container_id}${NC}"
    echo ""
    echo -e "${GREEN}📚 更多資訊：${NC}"
    echo -e "   GitHub: https://github.com/alam00000/bentopdf"
    echo -e "   Discord: https://discord.gg/AP2Y97juZT"
    echo ""
    echo "=============================================="
}

# ==================== 主要安裝流程 ====================
main() {
    # 顯示標題
    header_info "$APP"
    variables
    color
    catch_errors
    
    # 構建容器
    log_info "開始構建 LXC 容器..."
    start
    build_container
    description
    
    # 獲取容器 ID
    # 這裡需要從 build_container 函數中取得 container_id
    # 如果腳本已經設定了 CTID 變數，使用它
    local container_id=${CTID}
    
    if [ -z "$container_id" ]; then
        log_error "無法取得容器 ID"
        exit 1
    fi
    
    log_success "容器 $container_id 創建完成"
    
    # 配置網路
    if ! configure_network $container_id; then
        log_error "網路配置失敗，請手動配置後重新執行"
        echo ""
        echo "手動配置步驟："
        echo "1. pct stop $container_id"
        echo "2. pct set $container_id -net0 name=eth0,bridge=vmbr0,ip=dhcp"
        echo "3. pct start $container_id"
        exit 1
    fi
    
    # 配置 DNS
    configure_dns $container_id
    
    # 系統設定
    if ! default_settings $container_id; then
        log_error "系統設定失敗"
        exit 1
    fi
    
    # 安裝 Docker
    if ! install_docker $container_id; then
        log_error "Docker 安裝失敗"
        exit 1
    fi
    
    # 安裝 BentoPDF
    if ! install_bentopdf $container_id; then
        log_error "BentoPDF 安裝失敗"
        exit 1
    fi
    
    # 顯示完成資訊
    display_info $container_id
    
    log_success "所有安裝步驟完成！"
}

# ==================== 執行主程式 ====================
main "$@"
