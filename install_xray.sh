#!/usr/bin/env bash
#
# setup-xray-reality.sh
# ---------------------------------------------------------------------------
# 在干净的 Debian/Ubuntu VPS 上搭建 Xray + VLESS + Reality (xtls-rprx-vision)
#
# 设计原则（你应当逐行读懂再跑）:
#   1. 唯一的联网下载是 XTLS 官方安装脚本（github.com/XTLS），用于装 Xray 核心。
#      这一行你可以自己去 https://github.com/XTLS/Xray-install 核对。
#   2. 其余全部本地完成：密钥、UUID、shortId、config.json 均在本机生成，
#      不向任何第三方上报节点信息。
#   3. 不改你的 SSH 配置、不装乱七八糟的东西、不留后门。
#
# 用法:
#   chmod +x setup-xray-reality.sh
#   sudo ./setup-xray-reality.sh
#
# 跑完后会打印：客户端 vless:// 链接 + 关键字段，照着填 Passwall / QuantumultX。
# ---------------------------------------------------------------------------

set -euo pipefail

# ====== 可调参数（按需改，默认即可用）===================================

# Reality 借壳的目标真站。脚本会从下面候选池里自动测 TLS1.3 握手延迟，选最快的。
# 候选都是全球大站——选哪个都"合理"，不会因为冷门而显得可疑。
# 测速时会淘汰：不支持 TLS1.3 的、握手失败的、超时的。
DEST_CANDIDATES=(
  "www.microsoft.com"
  "www.apple.com"
  "www.cloudflare.com"
  "www.amazon.com"
  "www.bing.com"
  "dl.google.com"
  "www.icloud.com"
)

# 若你想跳过自动测速、强制指定某个站，把它填这里（留空=自动测速选最优）。
DEST_DOMAIN_OVERRIDE=""

DEST_PORT="443"

# Xray 监听的公网端口。443 最像正常 HTTPS，最推荐。
LISTEN_PORT="443"

# =========================================================================

# ---- 0. 基础检查 + 系统识别 --------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo $0" >&2
  exit 1
fi

# 识别发行版家族：debian(apt) 还是 rhel(dnf/yum)
OS_FAMILY="unknown"
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "${ID}:${ID_LIKE:-}" in
    *debian*|*ubuntu*) OS_FAMILY="debian" ;;
    *rhel*|*centos*|*fedora*|*rocky*|*almalinux*) OS_FAMILY="rhel" ;;
  esac
  # 兜底：按 ID 再判一次
  case "${ID}" in
    debian|ubuntu) OS_FAMILY="debian" ;;
    centos|rhel|fedora|rocky|almalinux) OS_FAMILY="rhel" ;;
  esac
fi
echo "[*] 检测到系统家族: ${OS_FAMILY} (${PRETTY_NAME:-未知})"

# 跨发行版包安装函数
pkg_install() {
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get update -y && apt-get install -y "$@"
  elif [[ "$OS_FAMILY" == "rhel" ]]; then
    dnf install -y "$@" || yum install -y "$@"
  else
    echo "[!] 未知系统，请手动安装: $*" >&2
    return 1
  fi
}

# 确保 curl / openssl 在
command -v curl    >/dev/null 2>&1 || { echo "[*] 安装 curl ...";    pkg_install curl; }
command -v openssl >/dev/null 2>&1 || { echo "[*] 安装 openssl ..."; pkg_install openssl; }

# ---- 1. 安装 Xray 核心（唯一联网步骤，来源 XTLS 官方）------------------
# 官方脚本地址你可自行核对：https://github.com/XTLS/Xray-install
echo "[*] 通过 XTLS 官方脚本安装 Xray 核心 ..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"
if [[ ! -x "$XRAY_BIN" ]]; then
  echo "Xray 未正确安装，停止。" >&2
  exit 1
fi

# ---- 1.5 自动选择最优 dest（测 TLS1.3 握手延迟，挑最快）---------------
select_best_dest() {
  # 若手动指定了，直接用，不测速
  if [[ -n "${DEST_DOMAIN_OVERRIDE}" ]]; then
    echo "$DEST_DOMAIN_OVERRIDE"
    return 0
  fi

  local host best_host="" best_ms=999999
  echo "[*] 测试候选 dest 的 TLS1.3 握手延迟（取 2 次最优，单位 ms）..." >&2
  printf "    %-22s %-12s %s\n" "候选站" "TLS1.3" "握手延迟" >&2
  printf "    %-22s %-12s %s\n" "------" "------" "--------" >&2

  for host in "${DEST_CANDIDATES[@]}"; do
    local ok_tls13="no" ms_best=999999 i t
    for i in 1 2; do
      # --tlsv1.3 强制 TLS1.3；测到 TLS 握手完成的耗时(time_appconnect)。
      # 失败(不支持 1.3 / 不通 / 超时) -> t 为空，跳过。
      t="$(curl -o /dev/null -s --max-time 6 --tlsv1.3 --tls-max 1.3 \
            -w '%{time_appconnect}' "https://${host}:${DEST_PORT}" 2>/dev/null || true)"
      if [[ -n "$t" && "$t" != "0.000000" ]]; then
        ok_tls13="yes"
        # 秒转毫秒(整数)
        local ms
        ms="$(awk -v x="$t" 'BEGIN{printf "%d", x*1000}')"
        (( ms < ms_best )) && ms_best="$ms"
      fi
    done

    if [[ "$ok_tls13" == "yes" ]]; then
      printf "    %-22s %-12s %s ms\n" "$host" "支持" "$ms_best" >&2
      if (( ms_best < best_ms )); then
        best_ms="$ms_best"
        best_host="$host"
      fi
    else
      printf "    %-22s %-12s %s\n" "$host" "不支持/不通" "—" >&2
    fi
  done

  if [[ -z "$best_host" ]]; then
    # 全部失败的兜底：用微软（一般不会发生）
    echo "    [!] 所有候选均测速失败，回退默认 www.microsoft.com" >&2
    echo "www.microsoft.com"
  else
    echo "    -> 选中最优 dest: ${best_host} (${best_ms} ms)" >&2
    echo "$best_host"
  fi
}

DEST_DOMAIN="$(select_best_dest)"
echo "[*] 最终使用 dest = ${DEST_DOMAIN}"

# ---- 2. 双栈环境检测（重要：确认 VPS 真有可用 IPv6）------------------
echo "[*] 检测 IPv6 可用性 ..."
HAS_V6="no"
if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
  # 有全局 v6 地址，再测能否真正出网
  if curl -s6 --max-time 5 https://api64.ipify.org >/dev/null 2>&1; then
    HAS_V6="yes"
    SERVER_IP6="$(curl -s6 --max-time 5 https://api64.ipify.org || true)"
    echo "    -> IPv6 可用，出口地址: ${SERVER_IP6}"
  else
    echo "    -> 检测到 v6 地址但无法出网（v6 可能是摆设），将以纯 v4 运行出站"
  fi
else
  echo "    -> 未检测到全局 IPv6 地址，将以纯 v4 运行"
fi
# 说明：入站监听 :: 已是双栈，能否经 v6 连入取决于 VPS 是否有公网 v6。
# 出站 domainStrategy=UseIPv4v6 会在目标有 v6 时也能走 v6，无 v6 自动回落 v4，
# 所以即使本机无 v6，配置也不会报错，只是 v6 出口不可用而已。

# ---- 3. 本地生成所有密钥/标识（不联网）--------------------------------
echo "[*] 本地生成 UUID / X25519 密钥 / shortId ..."

UUID="$("$XRAY_BIN" uuid)"

# x25519 输出形如:
#   Private key: xxxx
#   Public key: yyyy
X25519_OUT="$("$XRAY_BIN" x25519)"
PRIVATE_KEY="$(echo "$X25519_OUT" | grep -i 'Private key' | awk -F': ' '{print $2}' | tr -d ' \r')"
PUBLIC_KEY="$(echo "$X25519_OUT"  | grep -i 'Public key'  | awk -F': ' '{print $2}' | tr -d ' \r')"

# shortId：1~16 位的十六进制字符串。生成一个 8 字节(16 hex)的随机值。
SHORT_ID="$(openssl rand -hex 8)"

# 取本机公网 IP（仅用于拼客户端链接显示；失败则留空让你手填）
SERVER_IP="$(curl -s4 --max-time 5 https://api.ipify.org || true)"
[[ -z "$SERVER_IP" ]] && SERVER_IP="<你的VPS公网IP>"

# ---- 4. 写入服务端 config.json ----------------------------------------
CONFIG_DIR="/usr/local/etc/xray"
mkdir -p "$CONFIG_DIR"

# 备份已有配置（如果有）
if [[ -f "$CONFIG_DIR/config.json" ]]; then
  cp "$CONFIG_DIR/config.json" "$CONFIG_DIR/config.json.bak.$(date +%s)"
  echo "[*] 已备份原 config.json"
fi

cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "::",
      "port": ${LISTEN_PORT},
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
          "show": false,
          "dest": "${DEST_DOMAIN}:${DEST_PORT}",
          "xver": 0,
          "serverNames": [ "${DEST_DOMAIN}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4v6" }
    },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" }
    ]
  }
}
EOF

echo "[*] 已写入 $CONFIG_DIR/config.json"

# ---- 5. SELinux 端口处理（仅 RHEL 系且端口非 443 时需要）-------------
# SELinux 默认策略已包含 tcp 443 (http_port_t)，用 443 无需处理。
# 用非 443 端口时，需把该端口加入 http_port_t，否则 Xray 无法 bind，
# 表现为“配置正确但服务起不来 / Permission denied”。
if [[ "$OS_FAMILY" == "rhel" ]] && command -v getenforce >/dev/null 2>&1; then
  if [[ "$(getenforce)" == "Enforcing" ]]; then
    if [[ "${LISTEN_PORT}" != "443" ]]; then
      echo "[*] SELinux 为 Enforcing 且端口非 443，放行 ${LISTEN_PORT}/tcp 到 http_port_t ..."
      command -v semanage >/dev/null 2>&1 || pkg_install policycoreutils-python-utils
      # -a 新增；已存在则用 -m 修改
      semanage port -a -t http_port_t -p tcp "${LISTEN_PORT}" 2>/dev/null \
        || semanage port -m -t http_port_t -p tcp "${LISTEN_PORT}" 2>/dev/null \
        || echo "    [!] semanage 设置失败，若 Xray 起不来请手动处理 SELinux 端口"
    else
      echo "[*] SELinux 为 Enforcing，使用 443（默认已在 http_port_t 内，无需处理）"
    fi
  fi
fi

# ---- 6. 校验配置并重启 -------------------------------------------------
echo "[*] 校验配置 ..."
"$XRAY_BIN" run -test -config "$CONFIG_DIR/config.json"

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 1
systemctl --no-pager --full status xray | head -n 5 || true

# ---- 7. 防火墙放行（自动识别 ufw / firewalld）-------------------------
FW_DONE="no"
# Debian/Ubuntu 常见 ufw
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
  echo "[*] 已在 ufw 放行 ${LISTEN_PORT}/tcp"
  FW_DONE="yes"
fi
# RHEL/CentOS 常见 firewalld
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  echo "[*] 已在 firewalld 放行 ${LISTEN_PORT}/tcp"
  FW_DONE="yes"
fi
if [[ "$FW_DONE" == "no" ]]; then
  echo "[*] 未检测到活动的 ufw/firewalld。若云厂商有安全组，请去控制台放行 ${LISTEN_PORT}/tcp"
fi

# ---- 8. 输出客户端信息 -------------------------------------------------
SHARE_LINK="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&security=reality&type=tcp&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Reality-${SERVER_IP}"

cat <<EOF

==========================================================================
  搭建完成。以下是客户端要用的全部信息（请妥善保存，pbk/sid 错一位都连不上）
==========================================================================

  地址 (address)   : ${SERVER_IP}
$( [[ "$HAS_V6" == "yes" ]] && echo "  IPv6 地址        : ${SERVER_IP6}  (双栈可用，客户端也可用此 v6 地址连入)" )
  端口 (port)      : ${LISTEN_PORT}
  UUID (id)        : ${UUID}
  流控 (flow)      : xtls-rprx-vision
  传输 (network)   : tcp
  安全 (security)  : reality
  SNI / serverName : ${DEST_DOMAIN}
  指纹 (fingerprint): chrome
  公钥 (publicKey) : ${PUBLIC_KEY}
  shortId (sid)    : ${SHORT_ID}

  双栈 / UDP 说明:
   - 入站监听 :: ，IPv4 和 IPv6 同时接受连接。
   - 出站 domainStrategy=UseIPv4v6：目标有 v6 走 v6，否则回落 v4。
   - UDP：VLESS+Reality+Vision 为 TCP 隧道，你的 UDP 流量(游戏/QUIC/DNS)
     以 UDP-over-TCP 封装传输，应用照常可用；客户端需开启 udp-relay。
     若极在意游戏原生 UDP，本协议非最优，但 QX 约束下这是可用解。

  —— 一键导入链接（多数客户端可直接粘贴/扫码）——
  ${SHARE_LINK}

==========================================================================
  提示：
   1. 服务端只存 privateKey，客户端只填 publicKey，别填反。
   2. 客户端设备时间必须准确（误差>~30s 会导致 Reality 握手失败）。
   3. 若连不上：先 systemctl status xray、journalctl -u xray -n 50 看日志。
==========================================================================
EOF
