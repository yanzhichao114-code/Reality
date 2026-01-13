#!/bin/bash
set -euo pipefail

# --- 1. 基础环境检查 ---

if [ "$(id -u)" != "0" ]; then
  echo "错误: 此脚本必须以 root 身份运行。"
  exit 1
fi

# ANSI 颜色定义
RED_BOLD="\033[31;1m"
RESET="\033[0m"

echo -e "${RED_BOLD}==========================================================${RESET}"
echo -e "${RED_BOLD}                 Xray Reality 脚本                        ${RESET}"
echo -e "${RED_BOLD}==========================================================${RESET}"

# 依赖检查
need_cmds=(curl openssl awk grep ss ip systemctl pgrep unzip)
missing=()
for c in "${need_cmds[@]}"; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "检测到缺少依赖: ${missing[*]}"
  echo "正在更新 apt 源并安装依赖..."
  apt-get update -y >/dev/null
  apt-get install -y curl openssl ca-certificates iproute2 grep gawk procps unzip >/dev/null
fi

# systemd 检查
if ! command -v systemctl >/dev/null 2>&1; then
  echo "错误: 当前系统不支持 systemd。"
  exit 1
fi

# --- 2. 前置：检测并卸载旧 Xray ---

XRAY_INSTALL_SCRIPT_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

detect_old_xray() {
  if pgrep -x xray >/dev/null 2>&1 \
    || systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "xray.service" \
    || [ -f /etc/systemd/system/xray.service ] \
    || [ -f /lib/systemd/system/xray.service ] \
    || [ -x /usr/local/bin/xray ] \
    || [ -x /usr/bin/xray ] \
    || [ -d /usr/local/etc/xray ]; then
    echo "1"
  else
    echo "0"
  fi
}

if [ "$(detect_old_xray)" = "1" ]; then
  echo "检测到旧版 Xray，正在执行卸载清理..."
  systemctl stop xray >/dev/null 2>&1 || true
  systemctl disable xray >/dev/null 2>&1 || true
  bash -c "$(curl -fsSL "$XRAY_INSTALL_SCRIPT_URL")" @ remove >/dev/null 2>&1 || true
  rm -rf /usr/local/etc/xray >/dev/null 2>&1 || true
  echo "✅ 旧版本清理完成。"
fi

# --- 3. 安装 Xray ---

echo "正在安装最新版 Xray..."
INSTALL_SCRIPT="$(curl -fsSL "$XRAY_INSTALL_SCRIPT_URL")" || {
  echo "错误: 无法下载 Xray 安装脚本，请检查网络。"
  exit 1
}
bash -c "$INSTALL_SCRIPT" @ install

XRAY_BIN="/usr/local/bin/xray"
if [ ! -x "$XRAY_BIN" ]; then
  echo "错误: Xray 二进制文件未找到或不可执行 ($XRAY_BIN)。"
  exit 1
fi

# --- 4. 监听端口配置 (外网端口) ---

echo ""
while true; do
  read -rp "请输入 Xray 外网监听端口 (默认: 443): " input_port
  PORT=${input_port:-443}

  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "❌ 错误: 端口必须是 1-65535 之间的数字。"
    continue
  fi

  if ss -H -lnt "sport = :$PORT" | grep -q .; then
    echo "❌ 端口 ${PORT} 已被占用，请更换。"
    ss -lntp "sport = :$PORT" || true
    continue
  fi

  echo "✅ 外网端口 ${PORT} 可用。"
  break
done

# --- 5. 伪装域名 ---

read -rp "请输入伪装域名 (SNI) (默认: speed.cloudflare.com): " DEST_DOMAIN
DEST_DOMAIN=${DEST_DOMAIN:-speed.cloudflare.com}

if ! [[ "$DEST_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "错误: 域名格式不合法。"
  exit 1
fi

# --- 6. 内部回落端口 (支持手动输入) ---

get_random_suggestion() {
  local p
  while true; do
    p=$((RANDOM % 30000 + 10000))
    if [ "$p" -eq "$PORT" ]; then continue; fi
    if ! ss -H -lnt "sport = :$p" | grep -q .; then
      echo "$p"
      return
    fi
  done
}

echo ""
SUGGEST_PORT="$(get_random_suggestion)"

while true; do
  read -rp "请输入内部回落端口 (留空则使用随机端口 $SUGGEST_PORT): " input_internal
  
  if [ -z "$input_internal" ]; then
    INTERNAL_PORT="$SUGGEST_PORT"
    echo "✅ 使用随机内部端口: ${INTERNAL_PORT}"
    break
  fi

  if ! [[ "$input_internal" =~ ^[0-9]+$ ]]; then
    echo "❌ 错误: 请输入有效的数字。"
    continue
  fi

  if [ "$input_internal" -lt 1 ] || [ "$input_internal" -gt 65535 ]; then
    echo "❌ 错误: 端口必须在 1-65535 之间。"
    continue
  fi

  if [ "$input_internal" -eq "$PORT" ]; then
    echo "❌ 错误: 内部端口不能与外网监听端口 ($PORT) 相同，会导致死循环。"
    continue
  fi

  if ss -H -lnt "sport = :$input_internal" | grep -q .; then
    echo "❌ 错误: 端口 $input_internal 已被其他程序占用，请更换。"
    continue
  fi

  INTERNAL_PORT="$input_internal"
  echo "✅ 内部端口设置为: ${INTERNAL_PORT}"
  break
done

# --- 7. 生成身份凭证 ---

echo ""
echo "正在生成身份凭证..."

UUID="$($XRAY_BIN uuid)" || { echo "执行 xray uuid 失败"; exit 1; }
KEYS="$($XRAY_BIN x25519)" || { echo "执行 xray x25519 失败"; exit 1; }

PRIVATE_KEY="$(echo "$KEYS" | awk -F': ' '/^PrivateKey:/ {print $2; exit}')"
PUB_OUT="$($XRAY_BIN x25519 -i "$PRIVATE_KEY" 2>/dev/null || true)"
PUBLIC_KEY="$(echo "$PUB_OUT" | awk -F': ' '/^PublicKey:/ {print $2; exit}')"

if [ -z "${PUBLIC_KEY:-}" ]; then
  PUBLIC_KEY="$(echo "$KEYS" | awk -F': ' '/^Password:/ {print $2; exit}')"
fi

SHORT_ID="$(openssl rand -hex 4)"

if [ -z "${UUID:-}" ] || [ -z "${PRIVATE_KEY:-}" ] || [ -z "${PUBLIC_KEY:-}" ]; then
  echo "❌ 错误: 凭证生成失败。"
  exit 1
fi

# --- 8. 写入配置 (保持美化格式) ---

mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "dokodemo-in",
      "listen": "127.0.0.1",
      "port": ${INTERNAL_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "${DEST_DOMAIN}",
        "port": 443,
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls"],
        "routeOnly": true
      }
    },
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "127.0.0.1:${INTERNAL_PORT}",
          "serverNames": [
            "${DEST_DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["dokodemo-in"],
        "domain": ["${DEST_DOMAIN}"],
        "outboundTag": "direct"
      },
      {
        "inboundTag": ["dokodemo-in"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# --- 9. 配置预检 ---

echo "正在检查配置文件有效性..."
if ! "$XRAY_BIN" run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
  echo "错误: Xray 配置预检失败。错误日志如下："
  "$XRAY_BIN" run -test -config /usr/local/etc/xray/config.json || true
  exit 1
fi

# --- 10. 启动并校验服务 (已更新为循环重试机制) ---

echo "正在启动 Xray..."
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray

# 1. 先检查服务状态是否报错
if ! systemctl is-active --quiet xray; then
  echo "错误: Xray 服务启动失败。请查看日志：journalctl -u xray -n 80"
  exit 1
fi

# 2. 循环检查端口监听 (解决启动时序问题)
echo "正在检查端口监听状态..."
CHECK_COUNT=0
MAX_RETRIES=10

while [ $CHECK_COUNT -lt $MAX_RETRIES ]; do
  if ss -H -lntp "sport = :$PORT" | grep -q xray; then
    echo "✅ 检测到 Xray 端口 $PORT 启动成功。"
    break
  fi
  
  echo "端口尚未就绪，等待 1 秒... ($((CHECK_COUNT+1))/$MAX_RETRIES)"
  sleep 1
  CHECK_COUNT=$((CHECK_COUNT+1))
done

# 3. 如果重试 10 次后仍未成功，则判定失败
if [ $CHECK_COUNT -eq $MAX_RETRIES ]; then
  echo "❌ 错误: 超时未检测到 xray 监听端口 $PORT。"
  echo "当前端口占用情况:"
  ss -lntp "sport = :$PORT" || true
  exit 1
fi

# --- 11. 生成分享链接 ---

SERVER_IP="$(curl -fsS4 ifconfig.me 2>/dev/null || true)"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
fi
SERVER_IP="${SERVER_IP:-YOUR_SERVER_IP}"

# 修改点：节点别名改为 Reality (去掉 _Auto)
SHARE_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&type=tcp&sni=${DEST_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Reality"

echo ""
echo -e "${RED_BOLD}==========================================================${RESET}"
echo -e "${RED_BOLD}                      部署完成                            ${RESET}"
echo -e "${RED_BOLD}==========================================================${RESET}"
echo " 地址 (IP):       ${SERVER_IP}"
echo " 端口 (Port):     ${PORT}"
echo " 伪装域名 (SNI):  ${DEST_DOMAIN}"
echo " UUID:            ${UUID}"
echo " Public Key:      ${PUBLIC_KEY}"
echo " Dokodemo Port:   ${INTERNAL_PORT} (内部回落)"
echo "----------------------------------------------------------"
echo " VLESS 分享链接:"
echo "${SHARE_LINK}"
echo "=========================================================="
