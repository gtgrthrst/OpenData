#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts
# Author: BentoPDF Community
# License: MIT
# Source: https://github.com/alam00000/bentopdf

APP="BentoPDF"
var_tags="${var_tags:-pdf;productivity}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  
  if [[ ! -f /etc/systemd/system/bentopdf.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  
  msg_info "Updating ${APP}"
  systemctl stop bentopdf
  cd /opt/bentopdf
  $STD docker compose pull
  systemctl start bentopdf
  msg_ok "Updated ${APP}"
  exit
}

function default_settings() {
  msg_info "Installing Dependencies"
  $STD apt-get update
  $STD apt-get install -y \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release
  msg_ok "Installed Dependencies"
}

function install_docker() {
  msg_info "Installing Docker"
  
  # Add Docker GPG key
  $STD mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  
  # Add Docker repository
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  # Install Docker
  $STD apt-get update
  $STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  
  # Enable and start Docker
  systemctl enable docker
  systemctl start docker
  
  msg_ok "Installed Docker"
}

function install_bentopdf() {
  msg_info "Installing ${APP}"
  
  # Create directory
  mkdir -p /opt/bentopdf
  
  # Create docker-compose.yml
  cat > /opt/bentopdf/docker-compose.yml << 'EOF'
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
EOF
  
  # Pull and start
  cd /opt/bentopdf
  $STD docker compose pull
  $STD docker compose up -d
  
  msg_ok "Installed ${APP}"
}

function create_service() {
  msg_info "Creating Service"
  
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
  
  systemctl daemon-reload
  systemctl enable bentopdf.service
  
  msg_ok "Created Service"
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3000${CL}"
