#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_DIR="/opt/sing-box"
TARGET_FILE="$TARGET_DIR/deploy-sing-box-router.sh"
TMP_FILE="$TARGET_FILE.tmp"

URLS=(
  "https://cdn.jsdelivr.net/gh/lisuyuan13/guize@main/sing-box-deploy-prod.sh"
  "https://fastly.jsdelivr.net/gh/lisuyuan13/guize@main/sing-box-deploy-prod.sh"
  "https://testingcf.jsdelivr.net/gh/lisuyuan13/guize@main/sing-box-deploy-prod.sh"
  "https://raw.githubusercontent.com/lisuyuan13/guize/refs/heads/main/sing-box-deploy-prod.sh"
)

log() {
  echo "[$(date '+%F %T')] $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    fail "请用 root 运行此脚本"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1"
}

download_file() {
  mkdir -p "$TARGET_DIR"
  rm -f "$TMP_FILE"

  local url
  for url in "${URLS[@]}"; do
    log "尝试下载: $url"
    if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$TMP_FILE"; then
      if [[ -s "$TMP_FILE" ]]; then
        log "下载成功: $url"
        return 0
      fi
    fi
    log "下载失败，尝试下一个源"
    rm -f "$TMP_FILE"
  done

  fail "所有下载源都失败了"
}

fix_line_endings() {
  log "修复 CRLF 换行"
  sed -i 's/\r$//' "$TMP_FILE"
}

install_script() {
  mv -f "$TMP_FILE" "$TARGET_FILE"
  chmod +x "$TARGET_FILE"
  log "已写入: $TARGET_FILE"
}

show_preview() {
  log "脚本头部预览"
  sed -n '1,5p' "$TARGET_FILE"
}

run_script() {
  log "开始执行: $TARGET_FILE"
  exec "$TARGET_FILE"
}

main() {
  require_root
  need_cmd curl
  need_cmd sed
  need_cmd chmod
  download_file
  fix_line_endings
  install_script
  show_preview
  run_script
}

main "$@"
