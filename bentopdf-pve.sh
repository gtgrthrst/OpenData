#!/usr/bin/env bash

# BentoPDF 完全自動化安裝腳本
# 所有邏輯都在此腳本中，不依賴外部文件

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# 應用程式配置
APP="BentoPDF"
var_tags="pdf;productivity"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="1"

# 顯示標題
header_info "$APP"
variables
color
catch_errors

# 更新腳本函數
function update_script() {
  header_info
  check_container_storage
  check_container_resources
  
  if [[ ! -f /opt/bentopdf/docker-compose.yml ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  
  msg_info "Updating ${APP}"
  cd /opt/bentopdf
  $STD docker compose pull
  $STD docker compose up -d
  msg_ok "Updated ${APP}"
  exit
}

# 開始安裝
start
build_container
description

# ==================== 容器內安裝邏輯 ====================

msg_info "Configuring Container"

# 配置 DNS
msg_info "Configuring DNS"
cat <<EOF >/etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 168.95.1.1
EOF
msg_ok "DNS Configured"

# 更新系統
msg_info "Updating System"
$STD apt-get update
$STD apt-get upgrade -y
msg_ok "System Updated"

# 安裝依賴
msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  apt-transport-https \
  software-properties-common
msg_ok "Dependencies Installed"

# 安裝 Docker
msg_info "Installing Docker"
$STD mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
$STD apt-get update
$STD apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-compose-plugin
systemctl enable docker
systemctl start docker
msg_ok "Docker Installed"

# 驗證 Docker
msg_info "Verifying Docker Installation"
if ! docker --version > /dev/null 2>&1; then
  msg_error "Docker installation failed"
  exit 1
fi
msg_ok "Docker Verified"

# 部署 BentoPDF
msg_info "Deploying ${APP}"
mkdir -p /opt/bentopdf
cd /opt/bentopdf

cat > docker-compose.yml <<'COMPOSE_EOF'
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
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
COMPOSE_EOF

$STD docker compose pull
$STD docker compose up -d
msg_ok "${APP} Deployed"

# 創建 systemd 服務
msg_info "Creating Service"
cat > /etc/systemd/system/bentopdf.service <<'SERVICE_EOF'
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
SERVICE_EOF

systemctl daemon-reload
systemctl enable bentopdf.service
msg_ok "Service Created"

# 等待容器啟動
msg_info "Waiting for ${APP} to start"
sleep 10
msg_ok "${APP} Started"

# 驗證安裝
msg_info "Verifying Installation"
if docker ps | grep -q bentopdf; then
  msg_ok "Installation Verified"
else
  msg_error "Container not running"
  docker ps -a
  exit 1
fi

# 清理
msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"

# 完成訊息
msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3000${CL}"
