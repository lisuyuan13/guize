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

disable_cdrom_sources() {
  local changed=0

  if [[ -f /etc/apt/sources.list ]] && grep -Eq '^[[:space:]]*deb[[:space:]]+cdrom:' /etc/apt/sources.list; then
    log "检测到 cdrom APT 源，自动注释 /etc/apt/sources.list 中的相关条目"
    cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)"
    sed -Ei 's@^[[:space:]]*(deb[[:space:]]+cdrom:.*)@# disabled by bootstrap-sing-box-deploy.sh: \1@g' /etc/apt/sources.list
    changed=1
  fi

  if [[ -d /etc/apt/sources.list.d ]]; then
    while IFS= read -r -d '' file; do
      if grep -Eq '^[[:space:]]*deb[[:space:]]+cdrom:' "$file"; then
        log "检测到 cdrom APT 源，自动注释 $file 中的相关条目"
        cp -a "$file" "${file}.bak.$(date +%s)"
        sed -Ei 's@^[[:space:]]*(deb[[:space:]]+cdrom:.*)@# disabled by bootstrap-sing-box-deploy.sh: \1@g' "$file"
        changed=1
      fi
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -print0 2>/dev/null)
  fi

  if [[ $changed -eq 1 ]]; then
    log "已处理 cdrom APT 源"
  fi
}

ensure_basic_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v sed >/dev/null 2>&1 || missing+=(sed)
  command -v chmod >/dev/null 2>&1 || missing+=(coreutils)

  if [[ ${#missing[@]} -gt 0 ]]; then
    disable_cdrom_sources
    export DEBIAN_FRONTEND=noninteractive
    log "安装基础工具: ${missing[*]}"
    apt-get update -o Acquire::Retries=3
    apt-get install -y "${missing[@]}"
  fi
}

download_file() {
  mkdir -p "$TARGET_DIR"
  rm -f "$TMP_FILE"

  local url
  for url in "${URLS[@]}"; do
    log "尝试下载: $url"
    if curl -fsSL --connect-timeout 15 --max-time 180 "$url" -o "$TMP_FILE"; then
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
  ensure_basic_tools
  download_file
  fix_line_endings
  install_script
  show_preview
  run_script
}

main "$@"
