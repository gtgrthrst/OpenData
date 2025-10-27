#!/usr/bin/env bash

# BentoPDF Proxmox VE LXC 容器自動安裝腳本
# 此腳本將在 Proxmox VE 上建立一個 LXC 容器並安裝 BentoPDF

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# 應用程式資訊
APP="BentoPDF"
var_tags="pdf;productivity"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="ubuntu"
var_version="24.04"
var_unprivileged="1"

# 顯示標題資訊
header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  
  if [[ ! -f /etc/systemd/system/bentopdf.service ]]; then
    msg_error "找不到 ${APP} 安裝！"
    exit
  fi
  
  msg_info "正在更新 ${APP}"
  
  # 停止服務
  systemctl stop bentopdf
  
  # 拉取最新的 Docker 映像
  docker pull bentopdf/bentopdf:latest
  
  # 重新啟動服務
  systemctl start bentopdf
  
  msg_ok "已成功更新 ${APP}"
  exit
}

function default_settings() {
  msg_info "設定容器"
  
  # 更新系統
  $STD apt-get update
  $STD apt-get -y upgrade
  
  # 安裝必要的套件
  msg_info "安裝 Docker 和相關工具"
  $STD apt-get install -y curl wget git ca-certificates gnupg lsb-release
  
  # 安裝 Docker
  $STD mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  $STD apt-get update
  $STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  
  # 啟動 Docker
  systemctl enable docker
  systemctl start docker
  
  msg_ok "已完成基礎設定"
}

function install_bentopdf() {
  msg_info "安裝 ${APP}"
  
  # 建立工作目錄
  mkdir -p /opt/bentopdf
  cd /opt/bentopdf
  
  # 建立 docker-compose.yml
  cat > docker-compose.yml << 'EOF'
services:
  bentopdf:
    image: bentopdf/bentopdf:latest
    container_name: bentopdf
    ports:
      - '3000:8080'
    restart: unless-stopped
    environment:
      - TZ=Asia/Taipei
EOF
  
  # 啟動 BentoPDF
  $STD docker compose up -d
  
  # 建立系統服務
  cat > /etc/systemd/system/bentopdf.service << 'EOF'
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
EOF
  
  # 啟用服務
  systemctl daemon-reload
  systemctl enable bentopdf.service
  
  msg_ok "已成功安裝 ${APP}"
}

function display_info() {
  IP=$(hostname -I | awk '{print $1}')
  
  msg_info "安裝資訊"
  echo -e "\n${CHECKMARK} ${GN}BentoPDF 已成功安裝！${CL}"
  echo -e "${CHECKMARK} ${GN}存取網址：${CL} http://${IP}:3000"
  echo -e "${CHECKMARK} ${GN}Docker 容器名稱：${CL} bentopdf"
  echo -e "${CHECKMARK} ${GN}時區設定：${CL} Asia/Taipei"
  echo -e "\n${CHECKMARK} ${YW}常用指令：${CL}"
  echo -e "  - 查看日誌：${BL}docker logs bentopdf${CL}"
  echo -e "  - 重新啟動：${BL}systemctl restart bentopdf${CL}"
  echo -e "  - 更新版本：${BL}docker pull bentopdf/bentopdf:latest && systemctl restart bentopdf${CL}"
  echo -e "  - 進入容器：${BL}docker exec -it bentopdf sh${CL}"
}

# 主要安裝流程
start
build_container
description

msg_ok "容器建立完成，開始安裝 ${APP}"

# 執行安裝步驟
default_settings
install_bentopdf
display_info

msg_ok "安裝完成！\n"
