#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/sing-box"
BIN="${BASE_DIR}/sing-box"
CONF="${BASE_DIR}/sing-box链式代理测试.json"
LOG_DIR="${BASE_DIR}/logs"
UNIT_FILE="/etc/systemd/system/sing-box.service"
SYSCTL_FILE="/etc/sysctl.d/99-sing-box.conf"
SERVICE_NAME="sing-box"

info() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*"; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请使用 root 运行此脚本。"
    exit 1
  fi
}

check_platform() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64|aarch64|arm64)
      info "检测到架构：$arch"
      ;;
    *)
      warn "当前架构是 $arch。若你的 sing-box 二进制不是对应架构，服务会启动失败。"
      ;;
  esac
}

check_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "systemctl 不存在，当前系统可能不是 systemd 环境。"
    exit 1
  fi
  if ! systemctl list-units >/dev/null 2>&1; then
    err "systemd 不可用或未正常运行。"
    exit 1
  fi
}

disable_cdrom_sources() {
  if [[ -f /etc/apt/sources.list ]]; then
    sed -i '/^deb cdrom:/s/^/# /' /etc/apt/sources.list || true
  fi
  if [[ -d /etc/apt/sources.list.d ]]; then
    find /etc/apt/sources.list.d -type f \( -name '*.list' -o -name '*.sources' \) -print0 | while IFS= read -r -d '' f; do
      sed -i '/^deb cdrom:/s/^/# /' "$f" || true
    done
  fi
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    info "更新并安装基础依赖..."
    export DEBIAN_FRONTEND=noninteractive
    disable_cdrom_sources
    apt-get update -y
    apt-get install -y ca-certificates iproute2 procps
  else
    warn "未检测到 apt-get，跳过依赖安装。"
  fi
}

validate_files() {
  [[ -f "$BIN" ]] || { err "二进制不存在：$BIN"; exit 1; }
  [[ -f "$CONF" ]] || { err "配置文件不存在：$CONF"; exit 1; }
  mkdir -p "$LOG_DIR"
  chmod +x "$BIN"
}

write_sysctl() {
  cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl --system >/dev/null || true
}

write_unit() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=sing-box transparent gateway
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BASE_DIR}
ExecStart=${BIN} run -c ${CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_service() {
  info "设置开机自启..."
  systemctl enable "$SERVICE_NAME"

  info "启动/重启服务..."
  systemctl restart "$SERVICE_NAME"

  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "服务运行正常。"
    systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,15p'
    echo "Ok"
  else
    err "服务未能正常启动，输出最近日志："
    journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true
    exit 1
  fi
}

main() {
  require_root
  check_platform
  check_systemd
  install_deps
  validate_files
  write_sysctl
  write_unit
  start_service
}

main "$@"
