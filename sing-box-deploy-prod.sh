#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR="/opt/sing-box"
BINARY="$WORKDIR/sing-box"
CONFIG="$WORKDIR/sing-box链式代理测试.json"
LOGDIR="$WORKDIR/logs"
SERVICE_NAME="sing-box"
SYSCTL_FILE="/etc/sysctl.d/98-sing-box-router.conf"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ARCH=""
BINARY_URLS=()

log() {
  echo "[$(date '+%F %T')] $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    fail "请用 root 运行本脚本"
  fi
}

disable_cdrom_sources() {
  local changed=0

  if [[ -f /etc/apt/sources.list ]] && grep -Eq '^[[:space:]]*deb[[:space:]]+cdrom:' /etc/apt/sources.list; then
    log "检测到 cdrom APT 源，自动注释 /etc/apt/sources.list 中的相关条目"
    cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)"
    sed -Ei 's@^[[:space:]]*(deb[[:space:]]+cdrom:.*)@# disabled by deploy-sing-box-router.sh: \1@g' /etc/apt/sources.list
    changed=1
  fi

  if [[ -d /etc/apt/sources.list.d ]]; then
    while IFS= read -r -d '' file; do
      if grep -Eq '^[[:space:]]*deb[[:space:]]+cdrom:' "$file"; then
        log "检测到 cdrom APT 源，自动注释 $file 中的相关条目"
        cp -a "$file" "${file}.bak.$(date +%s)"
        sed -Ei 's@^[[:space:]]*(deb[[:space:]]+cdrom:.*)@# disabled by deploy-sing-box-router.sh: \1@g' "$file"
        changed=1
      fi
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -print0 2>/dev/null)
  fi

  if [[ $changed -eq 1 ]]; then
    log "已处理 cdrom APT 源"
  fi
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  local pkgs=(ca-certificates iproute2 nftables curl unzip procps systemd)
  local missing=()
  for pkg in "${pkgs[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    disable_cdrom_sources
    log "安装依赖: ${missing[*]}"
    apt-get update -o Acquire::Retries=3
    apt-get install -y "${missing[@]}"
  fi
}

detect_arch() {
  local raw_arch
  raw_arch=$(uname -m)
  case "$raw_arch" in
    x86_64|amd64)
      ARCH="amd64"
      ;;
    aarch64|arm64)
      ARCH="arm64"
      ;;
    *)
      fail "不支持的系统架构: $raw_arch，目前仅支持 amd64 和 arm64"
      ;;
  esac
  log "检测到系统架构: $raw_arch -> $ARCH"
}

set_binary_urls() {
  case "$ARCH" in
    amd64)
      BINARY_URLS=(
        "https://mirror.ghproxy.com/https://github.com/lisuyuan13/guize/releases/download/sing-box-1.14.0-alpha.8-reF1nd-linux-amd64-musl/sing-box"
        "https://ghproxy.net/https://github.com/lisuyuan13/guize/releases/download/sing-box-1.14.0-alpha.8-reF1nd-linux-amd64-musl/sing-box"
        "https://github.moeyy.xyz/https://github.com/lisuyuan13/guize/releases/download/sing-box-1.14.0-alpha.8-reF1nd-linux-amd64-musl/sing-box"
        "https://github.com/lisuyuan13/guize/releases/download/sing-box-1.14.0-alpha.8-reF1nd-linux-amd64-musl/sing-box"
      )
      ;;
    arm64)
      BINARY_URLS=(
        "https://mirror.ghproxy.com/https://github.com/lisuyuan13/guize/releases/download/sing-box-1.14.0-alpha.8-reF1nd-linux-arm64-musl/sing-box"
        "https://ghproxy.net/https://github.com/lisuyuan13/guize/releases/download/sing-box-1.14.0-alpha.8-reF1nd-linux-arm64-musl/sing-box"
        "https://github.moeyy.xyz/https://github.com/lisuyuan13/guize/releases/download/sing-box-1.14.0-alpha.8-reF1nd-linux-arm64-musl/sing-box"
        "https://github.com/lisuyuan13/guize/releases/download/sing-box-1.14.0-alpha.8-reF1nd-linux-arm64-musl/sing-box"
      )
      ;;
    *)
      fail "未初始化架构下载地址"
      ;;
  esac
}

download_binary() {
  local tmp_file url
  tmp_file="$BINARY.tmp"
  rm -f "$tmp_file"

  for url in "${BINARY_URLS[@]}"; do
    log "尝试下载 $ARCH 核心: $url"
    if curl -fL --connect-timeout 15 --max-time 300 --retry 2 "$url" -o "$tmp_file"; then
      if [[ -s "$tmp_file" ]]; then
        mv -f "$tmp_file" "$BINARY"
        chmod 755 "$BINARY"
        log "核心下载完成: $BINARY"
        return 0
      fi
    fi
    rm -f "$tmp_file"
    log "下载失败，尝试下一个源"
  done

  fail "所有核心下载源都失败了"
}

prepare_files() {
  [[ -d "$WORKDIR" ]] || fail "$WORKDIR 不存在"
  [[ -f "$CONFIG" ]] || fail "缺少配置文件: $CONFIG"

  mkdir -p "$LOGDIR" "$WORKDIR/ui"

  detect_arch
  set_binary_urls
  download_binary
}

get_default_iface() {
  local iface
  iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}') || true
  if [[ -z "${iface:-}" ]]; then
    iface=$(ip -6 route show default 2>/dev/null | awk '/default/ {print $5; exit}') || true
  fi
  [[ -n "${iface:-}" ]] || fail "无法识别默认网卡"
  echo "$iface"
}

check_ipv6_status() {
  local iface="$1"
  log "检查 IPv6 状态"
  local disable_all disable_default disable_iface has_global6
  disable_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)
  disable_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 1)
  disable_iface=$(sysctl -n "net.ipv6.conf.${iface}.disable_ipv6" 2>/dev/null || echo 1)
  if [[ "$disable_all" != "0" || "$disable_default" != "0" || "$disable_iface" != "0" ]]; then
    log "检测到 IPv6 未完全启用，脚本将启用并设置自动获取"
  fi
  if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q 'inet6'; then
    has_global6=1
  else
    has_global6=0
  fi
  if [[ "$has_global6" -eq 1 ]]; then
    log "IPv6 已存在全局地址"
  else
    log "当前未检测到全局 IPv6 地址；已写入自动获取参数，后续是否拿到地址取决于上游网络是否提供 RA/DHCPv6"
  fi
}

configure_sysctl() {
  local iface="$1"
  log "写入 sysctl: $SYSCTL_FILE"
  cat > "$SYSCTL_FILE" <<EOF
# sing-box 旁路由持久化参数
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.${iface}.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# 开启转发后继续接收 RA，保持 IPv6 自动获取
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.${iface}.accept_ra = 2
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
net.ipv6.conf.${iface}.autoconf = 1
EOF

  sysctl --system >/dev/null

  # 某些 Armbian/Ubuntu ARM 镜像上，仅靠 all/default 不足以真正打开当前物理网卡 IPv6。
  # 这里显式对当前默认网卡再应用一次，避免 sing-box TUN 在配置 IPv6 地址时出现 permission denied。
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
  sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >/dev/null || true
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
  sysctl -w net.ipv6.conf.all.accept_ra=2 >/dev/null || true
  sysctl -w net.ipv6.conf.default.accept_ra=2 >/dev/null || true
  sysctl -w "net.ipv6.conf.${iface}.accept_ra=2" >/dev/null || true
  sysctl -w net.ipv6.conf.all.autoconf=1 >/dev/null || true
  sysctl -w net.ipv6.conf.default.autoconf=1 >/dev/null || true
  sysctl -w "net.ipv6.conf.${iface}.autoconf=1" >/dev/null || true
}

write_service() {
  log "写入 systemd 服务: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$WORKDIR
ExecStartPre=/usr/bin/test -x $BINARY
ExecStartPre=/usr/bin/test -f $CONFIG
ExecStart=$BINARY run -c $CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=false
StandardOutput=append:$LOGDIR/stdout.log
StandardError=append:$LOGDIR/stderr.log

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
}

validate_config() {
  log "检查 sing-box 配置"
  "$BINARY" version >/dev/null
  "$BINARY" check -c "$CONFIG" >/dev/null
}

start_service() {
  log "启动 $SERVICE_NAME"
  if ! systemctl restart "$SERVICE_NAME"; then
    echo
    echo "===== systemctl status $SERVICE_NAME =====" >&2
    systemctl --no-pager --full status "$SERVICE_NAME" >&2 || true
    echo "===== journalctl -u $SERVICE_NAME -n 80 =====" >&2
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    fail "$SERVICE_NAME 启动失败"
  fi
  sleep 3
  systemctl --no-pager --full status "$SERVICE_NAME"
}

update_config_github_urls() {
  [[ -f "$CONFIG" ]] || return 0

  sed -i \
    -e 's@https://github\.com/Zephyruso/zashboard/releases/latest/download/dist\.zip@https://mirror.ghproxy.com/https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip@g' \
    -e 's@https://raw\.githubusercontent\.com/@https://mirror.ghproxy.com/https://raw.githubusercontent.com/@g' \
    "$CONFIG"
}

show_summary() {
  local iface="$1"
  local ip4 ip6
  ip4=$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | head -n1 | cut -d/ -f1)
  ip6=$(ip -6 -o addr show dev "$iface" scope global | awk '{print $4}' | head -n1 | cut -d/ -f1)

  echo
  echo "========== 部署完成 =========="
  echo "默认网卡: $iface"
  echo "IPv4: ${ip4:-未获取}"
  echo "IPv6: ${ip6:-未获取}"
  echo "服务: systemctl status $SERVICE_NAME"
  echo "配置: $CONFIG"
  echo "日志目录: $LOGDIR"
  echo "面板地址: http://${ip4:-<本机IP>}:9090/ui/"
  echo "API 地址: http://${ip4:-<本机IP>}:9090"
  echo "HTTP 代理: ${ip4:-<本机IP>}:8080"
  echo "SOCKS5 代理: ${ip4:-<本机IP>}:1080"
  echo "透明代理 redirect: ${ip4:-<本机IP>}:7890"
  echo "透明代理 tproxy: ${ip4:-<本机IP>}:7891"
  echo "DNS: ${ip4:-<本机IP>}:1053"
  echo "TUN 网卡: momo"
  echo "=============================="
}

main() {
  require_root
  install_base_packages
  prepare_files
  local iface
  iface=$(get_default_iface)
  check_ipv6_status "$iface"
  configure_sysctl "$iface"
  update_config_github_urls
  validate_config
  write_service
  start_service
  show_summary "$iface"
}

main "$@"
