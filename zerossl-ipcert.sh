#!/usr/bin/env bash
set -euo pipefail

# ==========================
#   Load config & prereqs
# ==========================
# 从脚本所在目录加载 .env
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" &>/dev/null && pwd -P)"
CONF="${SCRIPT_DIR}/.env"
[[ -f "$CONF" ]] || { echo "缺少 $CONF（请在脚本同目录创建 .env）"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

log()  { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a /var/log/zerossl-ipcert.log; }
need() { command -v "$1" >/dev/null 2>&1 || { log "缺少依赖：$1"; exit 1; }; }
need curl; need jq; need openssl

VALID_DIR="${WEBROOT%/}/.well-known/pki-validation"
mkdir -p "$VALID_DIR" "$INSTALL_DIR"

key="$INSTALL_DIR/private.key"
csr="$INSTALL_DIR/req.csr"
crt="$INSTALL_DIR/cert.pem"
cab="$INSTALL_DIR/ca_bundle.pem"
full="$INSTALL_DIR/certificate.crt"

# ==========================
#   Helpers
# ==========================
days_left() {
  [[ -f "$full" ]] || { echo 0; return; }
  local end end_ts now_ts
  end=$(openssl x509 -in "$full" -noout -enddate 2>/dev/null | cut -d= -f2) || { echo 0; return; }
  end_ts=$(date -d "$end" +%s)
  now_ts=$(date +%s)
  echo $(( (end_ts - now_ts) / 86400 ))
}

gen_key_csr() {
  if [[ -f "$key" && -f "$csr" && "$ROTATE_KEY" -eq 0 ]]; then
    log "沿用现有私钥与 CSR：$key"
  else
    log "生成私钥与 CSR（SAN=IP:${IP}）"
    openssl req -new -newkey rsa:2048 -nodes \
      -keyout "$key" -out "$csr" \
      -subj "/CN=${IP}" \
      -addext "subjectAltName = IP:${IP}"
    chmod 600 "$key"
  fi

  # 一致性检查
  openssl req -in "$csr" -noout -text | grep -q "IP Address:${IP}" \
    || { log "CSR 中 SAN IP 与配置不一致"; exit 1; }
}

create_order() {
  local days="$1"
  curl -sS -X POST "https://api.zerossl.com/certificates?access_key=${ZEROSSL_KEY}" \
    --data-urlencode certificate_csr@"${csr}" \
    -d "certificate_domains=${IP}" \
    -d "certificate_validity_days=${days}" \
    -d "strict_domains=true"
}

write_validation() {
  local id="$1"
  local json http_url body file fname cleaned lines

  # 1) 拉取详情
  json=$(curl -sS "https://api.zerossl.com/certificates/$id?access_key=${ZEROSSL_KEY}") \
    || { log "获取证书详情失败"; exit 1; }

  # 2) 解析 URL 与内容（内容可能是 array 或 string）
  http_url=$(printf '%s' "$json" | jq -r --arg ip "$IP" '
    .validation.other_methods[$ip].file_validation_url_http
    // .validation.file_validation_url_http
    // empty
  ')
  body=$(printf '%s' "$json" | jq -r --arg ip "$IP" '
    .validation.other_methods[$ip].file_validation_content
    // .validation.file_validation_content
    // empty
    | (if type=="array" then join("\n") else . end)
  ')

  [[ -n "$http_url" && -n "$body" ]] || { log "未拿到校验信息"; echo "$json" | jq -C .; exit 1; }

  # 3) 规范化写入：去 BOM、去 \r，仅保留前三个非空行
  mkdir -p "$VALID_DIR"
  fname="$(basename "$http_url")"
  file="$VALID_DIR/$fname"

  cleaned=$(
    printf '%s' "$body" \
    | sed 's/^\xEF\xBB\xBF//' \
    | tr -d '\r' \
    | awk 'NF{print; if(++c==3) exit}'
  )

  bash -c 'printf "%s" "$0" > "$1"' "$cleaned" "$file"
  chmod 644 "$file"

  # 4) 必须恰好 3 行
  lines=$(awk 'NF{c++} END{print c+0}' "$file")
  if [[ "$lines" != "3" ]]; then
    log "校验文件非空行数应为 3，实际 $lines（$file）"
    exit 1
  fi

  # 5) 本机连通性（公网放行 80 由你保证）
  curl -fsSI "http://${IP}/.well-known/pki-validation/$fname" >/dev/null \
    || { log "HTTP 校验 URL 访问失败：http://${IP}/.well-known/pki-validation/$fname"; exit 1; }
}

trigger_and_wait() {
  local id="$1"
  local r status

  log "触发校验"
  r=$(curl -sS -X POST "https://api.zerossl.com/certificates/${id}/challenges?access_key=${ZEROSSL_KEY}" \
       -d validation_method=HTTP_CSR_HASH)
  echo "$r" | jq -C . >/dev/null || true

  if ! echo "$r" | grep -q '"success":true'; then
    r=$(curl -sS -X POST "https://api.zerossl.com/certificates/${id}/challenges?access_key=${ZEROSSL_KEY}" \
         -d validation_method=FILE_CSR_HASH)
    echo "$r" | jq -C . >/dev/null || true
  fi

  for i in {1..60}; do
    status=$(curl -sS "https://api.zerossl.com/certificates/$id?access_key=${ZEROSSL_KEY}" | jq -r '.status')
    log "轮询 #$i -> $status"
    [[ "$status" = issued ]] && return 0
    [[ "$status" = cancelled || "$status" = revoked ]] && { log "状态异常：$status"; exit 1; }
    sleep 11
  done

  log "等待超时"
  exit 1
}

download_install() {
  local id="$1"
  local dl

  log "下载证书"
  dl=$(curl -sS "https://api.zerossl.com/certificates/$id/download/return?access_key=${ZEROSSL_KEY}")
  echo "$dl" | jq -r '."certificate.crt"' > "$crt"
  echo "$dl" | jq -r '."ca_bundle.crt"'  > "$cab"
  cat "$crt" "$cab" > "$full"
  chmod 644 "$crt" "$cab" "$full"

  log "安装完成：$full + $key"
  if [[ -n "${POST_RELOAD_CMD:-}" ]]; then
    log "重载：$POST_RELOAD_CMD"
    bash -lc "$POST_RELOAD_CMD" || log "重载命令失败（请自查服务是否已读取新证书）"
  fi
}

cancel_old_drafts() {
  local keep="${1:-}"
  local ids

  ids=$(curl -s "https://api.zerossl.com/certificates?access_key=${ZEROSSL_KEY}&limit=100" \
    | jq -r --arg ip "$IP" --arg keep "$keep" '
        .results[]
        | select(.common_name==$ip and .status=="draft" and .id!=$keep)
        | .id
      ')

  [[ -z "$ids" ]] && { log "无可清理的 Draft"; return; }

  while read -r id; do
    [[ -z "$id" ]] && continue
    log "取消 Draft：$id"
    curl -s -X POST "https://api.zerossl.com/certificates/$id/cancel?access_key=${ZEROSSL_KEY}" >/dev/null || true
  done <<< "$ids"
}

# ==========================
#   Main flow
# ==========================
issue_or_renew() {
  local remain id create

  remain=$(days_left)
  if (( remain > RENEW_BEFORE_DAYS )); then
    log "证书剩余 ${remain} 天，未到续期窗口（>${RENEW_BEFORE_DAYS} 天），退出"
    exit 0
  fi

  gen_key_csr

  # 先清旧草稿，避免占额度
  cancel_old_drafts ""

  log "创建证书订单（${VALID_DAYS} 天）"
  create=$(create_order "$VALID_DAYS")
  id=$(echo "$create" | jq -r '.id // empty')

  if [[ -z "$id" ]]; then
    log "创建失败，返回：$(echo "$create" | jq -c .)"
    if [[ "$VALID_DAYS" != "90" ]]; then
      log "回退到 90 天再试"
      create=$(create_order 90)
      id=$(echo "$create" | jq -r '.id // empty')
    fi
  fi

  [[ -n "$id" ]] || { log "仍然失败，请检查配额/额度或取消占用的草稿"; exit 1; }
  log "证书ID：$id"

  # 保留当前订单再次清理其它 Draft
  cancel_old_drafts "$id"

  write_validation "$id"
  trigger_and_wait "$id"
  download_install "$id"
}

case "${1:-run}" in
  run|renew|issue) issue_or_renew ;;
  status) [[ -f "$full" ]] && openssl x509 -in "$full" -noout -subject -enddate || echo "未找到证书" ;;
  *) echo "用法：$0 [run|status]"; exit 1 ;;
esac
