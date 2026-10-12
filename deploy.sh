#!/usr/bin/env bash
#
#  daed + MosDNS 一键部署脚本
#  ------------------------------------------------------------------
#  作用：在 Linux 网关上安装 daed 与 MosDNS，并完成全部配置：
#        1. 安装 daed（官方 .deb / .rpm，已装则跳过）
#        2. 安装 MosDNS 并转换分流规则
#        3. 写入 MosDNS 配置，并用官方 mosdns service install 安装 systemd 服务（监听 53 + 5333）
#        4. 把 daed 的 DNS 上游指向 MosDNS
#
#  用法：sudo bash deploy.sh
#
#  支持系统：Debian 11/12、Ubuntu 20.04+、以及任何有 systemd 的发行版
#  依赖：curl、python3（用于解压 zip 与转换规则）
#  ------------------------------------------------------------------

set -Eeuo pipefail

# ============================ 安装位置 ============================
MOSDNS_VERSION="v5.3.4"
BIN_PATH="/usr/local/bin/mosdns"
CONVERTER="/usr/local/bin/dat2rules.py"
CONF_DIR="/etc/mosdns"
RULES_DIR="/etc/mosdns/rules"
LOG_DIR="/var/log/mosdns"
LOG_FILE="/var/log/mosdns/mosdns.log"
UNIT_DIR="/etc/systemd/system"
DAED_DB="/etc/daed/wing.db"
SYSTEMCTL=systemctl

# ============================ 输出工具 ============================
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

on_err() { printf '\n%s[x]%s 脚本在第 %s 行出错，已中止。\n' "$C_R" "$C_0" "${1:-?}" >&2; }
trap 'on_err "$LINENO"' ERR

WORK="$(mktemp -d /tmp/mosdns-deploy.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap 'cleanup' EXIT

# ============================ 1. 环境检查 ============================
step "环境检查"

[ "$(id -u)" -eq 0 ] || die "需要 root 权限运行：sudo bash $0"
command -v curl    >/dev/null 2>&1 || die "缺少 curl，请先安装：apt install -y curl"
command -v python3 >/dev/null 2>&1 || die "缺少 python3，请先安装：apt install -y python3"

case "$(uname -m)" in
  x86_64|amd64)   MOSDNS_ARCH=amd64;  DAED_ARCH=x86_64 ;;
  aarch64|arm64)  MOSDNS_ARCH=arm64;  DAED_ARCH=arm64 ;;
  armv7l|armv7)   MOSDNS_ARCH=arm-7;  DAED_ARCH="" ;;
  armv6l|armv6)   MOSDNS_ARCH=arm-6;  DAED_ARCH="" ;;
  *)              die "不支持的 CPU 架构：$(uname -m)" ;;
esac

ok "系统 $( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}") / 架构 $MOSDNS_ARCH"

# 53 端口占用检查：被 systemd-resolved 占用时自动关闭其 DNSStubListener
if ss -lunp 2>/dev/null | grep -qE "[:.]53[[:space:]]"; then
  holder="$(ss -lunp 2>/dev/null | grep -E "[:.]53[[:space:]]" \
            | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/.*("//; s/"$//' || true)"
  if [ "${holder:-}" = "systemd-resolve" ]; then
    warn "端口 53 被 systemd-resolved 占用，将关闭其 DNSStubListener"
    mkdir -p /etc/systemd
    touch /etc/systemd/resolved.conf
    if grep -q '^#\?DNSStubListener=' /etc/systemd/resolved.conf; then
      sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
    else
      printf '\nDNSStubListener=no\n' >> /etc/systemd/resolved.conf
    fi
    $SYSTEMCTL restart systemd-resolved 2>/dev/null || true
    sleep 1
  elif [ "${holder:-}" = "mosdns" ]; then
    warn "端口 53 被本机 mosdns 占用，先停止旧服务（稍后会重新启动）"
    $SYSTEMCTL stop mosdns 2>/dev/null || true
    sleep 1
  else
    die "端口 53 已被【${holder:-未知进程}】占用，请先释放该端口"
  fi
fi

# ============================ 2. 安装 daed ============================
step "安装 daed"

if command -v daed >/dev/null 2>&1 || [ -x /usr/bin/daed ]; then
  ok "daed 已安装：$(daed --version 2>&1 | head -1)"
else
  if [ -z "$DAED_ARCH" ]; then
    warn "daed 官方包不含 $(uname -m) 架构，请手动安装：https://github.com/daeuniverse/daed/releases"
  elif command -v apt-get >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "$WORK/daed.deb" \
      "https://github.com/daeuniverse/daed/releases/latest/download/installer-daed-linux-${DAED_ARCH}.deb" \
      || die "daed 下载失败，请检查网络后重试"
    apt-get install -y "$WORK/daed.deb"
    ok "daed 已安装：$(daed --version 2>&1 | head -1)"
  elif command -v dnf >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "$WORK/daed.rpm" \
      "https://github.com/daeuniverse/daed/releases/latest/download/installer-daed-linux-${DAED_ARCH}.rpm" \
      || die "daed 下载失败，请检查网络后重试"
    dnf install -y "$WORK/daed.rpm"
    ok "daed 已安装：$(daed --version 2>&1 | head -1)"
  else
    warn "未找到 apt-get / dnf，请手动安装 daed：https://github.com/daeuniverse/daed/releases"
  fi
fi

# ============================ 3. 安装 MosDNS ============================
step "安装 MosDNS（${MOSDNS_VERSION}）"

if [ -x "$BIN_PATH" ] && "$BIN_PATH" version 2>/dev/null | grep -q "${MOSDNS_VERSION#v}"; then
  ok "已存在同版本 $BIN_PATH，跳过下载"
else
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$WORK/mosdns.zip" \
    "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${MOSDNS_ARCH}.zip" \
    || die "MosDNS 下载失败，请检查网络后重试"

  # 官方 release 只有 zip 包；优先用系统 unzip，Debian 默认不带 unzip 时退回 python3 标准库解压
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$WORK/mosdns.zip" -d "$WORK" || die "zip 解压失败"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$WORK/mosdns.zip" "$WORK" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as f:
    f.extractall(sys.argv[2])
PY
  else
    die "系统既没有 unzip 也没有 python3，无法解压官方 zip 包，请先安装其中之一"
  fi
  SRC="$(find "$WORK" -maxdepth 2 -type f -name mosdns | head -1)"
  [ -n "$SRC" ] || die "压缩包里没找到 mosdns 可执行文件"
  install -d -m 0755 "$(dirname "$BIN_PATH")"
  install -m 0755 -o root -g root "$SRC" "$BIN_PATH"
  ok "已安装 $BIN_PATH（$("$BIN_PATH" version 2>&1 | head -1)）"
fi

# ============================ 4. 生成规则文件 ============================
step "准备 geosite / geoip 规则"

install -d -m 0755 "$CONF_DIR" "$RULES_DIR" "$LOG_DIR"

NEED_RULES=1
if [ -f "$RULES_DIR/geosite_CN.txt" ] && [ -f "$RULES_DIR/geosite_CATEGORY_ADS_ALL.txt" ] && [ -f "$RULES_DIR/geoip_CN.txt" ]; then
  ok "规则文件已存在，跳过下载与转换（更新请运行 sudo update-rules.sh）"
  NEED_RULES=0
fi

# dat 优先用本机已有的（daed / dae 自带），否则在线下载
if [ "$NEED_RULES" = 1 ]; then
for name in geosite.dat geoip.dat; do
  dst="$WORK/$name"
  src=""
  for c in "/usr/share/daed/$name" "/usr/share/dae/$name" "/usr/share/v2ray-rules-dat/$name"; do
    [ -f "$c" ] && { src="$c"; break; }
  done
  if [ -n "$src" ]; then
    cp -f "$src" "$dst"
    ok "$name ← 本机 $src"
  else
    info "本机没有 $name，改为下载"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$dst" \
      "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$name" \
      || die "下载 $name 失败，请检查网络后重试"
    ok "$name ← 已下载"
  fi
done
fi

# 安装 dat → 文本规则 转换器（MosDNS v5 不能直接读 dat；update-rules.sh 也依赖它）
if [ -x "$CONVERTER" ]; then
  ok "规则转换器已存在：$CONVERTER"
else
  install -d -m 0755 "$(dirname "$CONVERTER")"
cat > "$CONVERTER" <<'PYEOF'
#!/usr/bin/env python3
"""
dat2rules.py — 把 v2ray 格式的 geosite.dat / geoip.dat 转成 MosDNS v5 文本规则

用法:
    dat2rules.py <geosite.dat> <geoip.dat> <输出目录>

导出 tag：geosite CN、CATEGORY-ADS-ALL；geoip CN、PRIVATE

生成的规则语法:
    domain:example.com   后缀匹配（对应 dat 里的 Domain 类型）
    full:example.com     精确匹配（对应 Full）
    regexp:^ad\\.            正则（对应 Regex）
    keyword:xxx          关键字（对应 Plain）
"""
import ipaddress
import os
import sys


def read_varint(buf, i):
    r = 0
    s = 0
    while True:
        b = buf[i]
        i += 1
        r |= (b & 0x7F) << s
        if not (b & 0x80):
            break
        s += 7
    return r, i


def skip_field(buf, i, wire_type):
    if wire_type == 0:
        _, i = read_varint(buf, i)
        return i
    if wire_type == 1:
        return i + 8
    if wire_type == 2:
        ln, i = read_varint(buf, i)
        return i + ln
    if wire_type == 5:
        return i + 4
    raise ValueError("unsupported wire type %d" % wire_type)


def parse_geosite(path):
    data = open(path, "rb").read()
    i = 0
    while i < len(data):
        key, i = read_varint(data, i)
        field, wt = key >> 3, key & 7
        if wt != 2:
            i = skip_field(data, i, wt)
            continue
        ln, i = read_varint(data, i)
        entry = data[i:i + ln]
        i += ln
        if field != 1:
            continue

        j = 0
        code = None
        domains = []
        while j < len(entry):
            k2, j = read_varint(entry, j)
            f2, w2 = k2 >> 3, k2 & 7
            if w2 != 2:
                j = skip_field(entry, j, w2)
                continue
            l2, j = read_varint(entry, j)
            val = entry[j:j + l2]
            j += l2
            if f2 == 1:
                code = val.decode("utf-8", "ignore")
            elif f2 == 2:
                m = 0
                dtype = 0
                dval = None
                while m < len(val):
                    k3, m = read_varint(val, m)
                    f3, w3 = k3 >> 3, k3 & 7
                    if w3 == 0:
                        x3, m = read_varint(val, m)
                        if f3 == 1:
                            dtype = x3
                    elif w3 == 2:
                        l3, m = read_varint(val, m)
                        t3 = val[m:m + l3]
                        m += l3
                        if f3 == 2:
                            dval = t3.decode("utf-8", "ignore")
                    else:
                        m = skip_field(val, m, w3)
                if dval:
                    domains.append((dtype, dval))
        if code:
            yield code, domains


def parse_geoip(path):
    data = open(path, "rb").read()
    i = 0
    while i < len(data):
        key, i = read_varint(data, i)
        field, wt = key >> 3, key & 7
        if wt != 2:
            i = skip_field(data, i, wt)
            continue
        ln, i = read_varint(data, i)
        entry = data[i:i + ln]
        i += ln
        if field != 1:
            continue

        j = 0
        code = None
        cidrs = []
        while j < len(entry):
            k2, j = read_varint(entry, j)
            f2, w2 = k2 >> 3, k2 & 7
            if w2 != 2:
                j = skip_field(entry, j, w2)
                continue
            l2, j = read_varint(entry, j)
            val = entry[j:j + l2]
            j += l2
            if f2 == 1:
                code = val.decode("utf-8", "ignore")
            elif f2 == 2:
                m = 0
                ipbin = None
                prefix = None
                while m < len(val):
                    k3, m = read_varint(val, m)
                    f3, w3 = k3 >> 3, k3 & 7
                    if w3 == 0:
                        x3, m = read_varint(val, m)
                        if f3 == 2:
                            prefix = x3
                    elif w3 == 2:
                        l3, m = read_varint(val, m)
                        t3 = val[m:m + l3]
                        m += l3
                        if f3 == 1:
                            ipbin = t3
                    else:
                        m = skip_field(val, m, w3)
                if ipbin is not None and prefix is not None:
                    try:
                        cidrs.append("%s/%s" % (ipaddress.ip_address(ipbin), prefix))
                    except Exception:
                        pass
        if code:
            yield code, cidrs


def to_rule(dtype, value):
    """1=Regex -> regexp:  2=Domain -> domain:  3=Full -> full:  0=Plain -> keyword:"""
    if dtype == 1:
        return "regexp:" + value
    if dtype == 3:
        return "full:" + value
    if dtype == 0:
        return "keyword:" + value
    return "domain:" + value


def safe_name(tag):
    return tag.upper().replace("!", "NOT").replace("-", "_")


def main():
    if len(sys.argv) != 4:
        print("用法: dat2rules.py <geosite.dat> <geoip.dat> <输出目录>")
        sys.exit(1)
    geosite_path, geoip_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)

    want_site = {"CN", "CATEGORY-ADS-ALL"}
    want_ip = {"CN", "PRIVATE"}
    written = {}

    for code, domains in parse_geosite(geosite_path):
        up = code.upper()
        if up not in want_site:
            continue
        path = os.path.join(out, "geosite_%s.txt" % safe_name(up))
        with open(path, "w") as f:
            f.write("\n".join(to_rule(t, v) for t, v in domains) + "\n")
        written[path] = len(domains)

    for code, cidrs in parse_geoip(geoip_path):
        up = code.upper()
        if up not in want_ip:
            continue
        path = os.path.join(out, "geoip_%s.txt" % safe_name(up))
        with open(path, "w") as f:
            f.write("\n".join(cidrs) + "\n")
        written[path] = len(cidrs)

    for path, n in sorted(written.items()):
        print("  %-52s %d 条" % (path, n))
    if not written:
        print("  [!] 没有导出任何规则，请检查 dat 文件是否正确")
        sys.exit(1)


if __name__ == "__main__":
    main()
PYEOF
  chmod 0755 "$CONVERTER"
  ok "已安装规则转换器 $CONVERTER"
fi

if [ "$NEED_RULES" = 1 ]; then
  python3 "$CONVERTER" "$WORK/geosite.dat" "$WORK/geoip.dat" "$RULES_DIR" \
    || die "规则转换失败"
fi

# ============================ 5. 写配置文件 ============================
step "写入 $CONF_DIR/config.yaml"

if [ -f "$CONF_DIR/config.yaml" ]; then
  CONF_BAK="$CONF_DIR/config.yaml.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONF_DIR/config.yaml" "$CONF_BAK"
  info "已备份原配置：$CONF_BAK"
fi

cat > "$CONF_DIR/config.yaml" <<EOF
log:
  level: info
  file: "$LOG_FILE"

api:
  http: "127.0.0.1:9080"

include: []

plugins:
  # ================= 规则数据 =================
  - tag: geosite_cn
    type: domain_set
    args:
      files:
        - "$RULES_DIR/geosite_CN.txt"

  - tag: geosite_ads
    type: domain_set
    args:
      files:
        - "$RULES_DIR/geosite_CATEGORY_ADS_ALL.txt"

  - tag: geoip_cn
    type: ip_set
    args:
      files:
        - "$RULES_DIR/geoip_CN.txt"

  # ================= 缓存 =================
  - tag: cache
    type: cache
    args:
      size: 20480
      lazy_cache_ttl: 86400

  # ================= 上游 =================
  # 上游统一使用 DoH(443)，绕开 daed 的 :53 劫持
  - tag: ali_dns
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "https://dns.alidns.com/dns-query"
          dial_addr: "223.5.5.5:443"
        - addr: "https://dns.alidns.com/dns-query"
          dial_addr: "223.6.6.6:443"

  - tag: wan_dns
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "https://dns.google/dns-query"
          dial_addr: "8.8.8.8:443"
        - addr: "https://dns.google/dns-query"
          dial_addr: "8.8.4.4:443"

  # ================= 主序列 =================
  # 命中国内域名后用 accept 终止序列，不再走兜底上游
  - tag: main_sequence
    type: sequence
    args:
      - exec: \$cache
      - matches: qname \$geosite_ads
        exec: reject 3
      - matches: qname \$geosite_cn
        exec: \$ali_dns
      - matches: qname \$geosite_cn
        exec: accept
      - exec: \$wan_dns

  # ================= 服务入口 =================
  # 局域网终端入口：把设备 DNS 直接指向本机即可
  - tag: udp_server_lan
    type: udp_server
    args:
      entry: main_sequence
      listen: "0.0.0.0:53"

  - tag: tcp_server_lan
    type: tcp_server
    args:
      entry: main_sequence
      listen: "0.0.0.0:53"

  # daed 上游入口
  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: "0.0.0.0:5333"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: "0.0.0.0:5333"
EOF
ok "已写入 $CONF_DIR/config.yaml"

# ============================ 6. systemd 服务 ============================
step "安装 systemd 服务（官方 mosdns service install）"

# 官方安装命令会自动生成 /etc/systemd/system/mosdns.service
# （Restart=always，自带崩溃自动拉起）；若旧 unit 已存在则先移除
if [ -f "$UNIT_DIR/mosdns.service" ]; then
  info "已存在旧版 mosdns.service，先移除以便官方命令重新生成"
  rm -f "$UNIT_DIR/mosdns.service"
fi
"$BIN_PATH" service install -d "$CONF_DIR" -c "$CONF_DIR/config.yaml" \
  || die "mosdns service install 失败"
ok "已通过 mosdns service install 生成 $UNIT_DIR/mosdns.service"

# 启动前先做一次配置加载预检（临时端口起影子实例，不影响线上端口）
info "配置加载预检"
SHADOW="$WORK/shadow.yaml"
sed -e 's#0.0.0.0:5333#127.0.0.1:15333#' \
    -e 's#0.0.0.0:53#127.0.0.1:15353#' \
    -e 's#127.0.0.1:9080#127.0.0.1:19080#' \
    -e "s#${LOG_FILE}##" \
    "$CONF_DIR/config.yaml" > "$SHADOW"
timeout 8 "$BIN_PATH" start -c "$SHADOW" -d "$CONF_DIR" > "$WORK/shadow.log" 2>&1 || true
if grep -qiE 'all plugins are loaded|plugins loaded' "$WORK/shadow.log"; then
  ok "配置加载正常"
else
  warn "预检未通过，日志如下："
  sed 's/^/    /' "$WORK/shadow.log" | tail -20
  die "配置有问题，已中止（未启动服务）"
fi

$SYSTEMCTL daemon-reload
$SYSTEMCTL enable --now mosdns >/dev/null 2>&1 || $SYSTEMCTL restart mosdns
sleep 2
if $SYSTEMCTL is-active --quiet mosdns; then
  ok "mosdns 服务已启动"
else
  journalctl -u mosdns -n 30 --no-pager | sed 's/^/    /'
  die "mosdns 启动失败"
fi

# ============================ 7. 配置 daed ============================
step "配置 daed"

if [ ! -f "$DAED_DB" ]; then
  warn "未找到 $DAED_DB（daed 可能还没启动过）"
  warn "请先启动 daed 并在 WebUI（http://<本机IP>:2023）完成节点配置，再运行一次本脚本"
else
  LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true)"
  [ -n "$LAN_IP" ] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [ -n "$LAN_IP" ] || LAN_IP="127.0.0.1"
  DAED_UPSTREAM="tcp+udp://${LAN_IP}:5333"

  # 若 daed 的 DNS 上游已指向本机 mosdns，则跳过修改（避免无谓重启 daed）
  ALREADY=0
  python3 - "$DAED_DB" "$LAN_IP" <<'PYCHK' && ALREADY=1 || true
import sqlite3, sys
db, ip = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    row = con.execute("select dns from dns where selected=1").fetchone()
    v = row[0] if row else ""
    sys.exit(0 if (":5333" in v and ip in v) else 1)
except Exception:
    sys.exit(1)
PYCHK

  if [ "$ALREADY" = 1 ]; then
    ok "daed DNS 上游已指向 $DAED_UPSTREAM，跳过修改（不重启 daed）"
  else
  info "daed DNS 上游将指向：$DAED_UPSTREAM（会短暂重启 daed）"

  if $SYSTEMCTL is-active --quiet daed; then
    $SYSTEMCTL stop daed
    sleep 1
  fi

  BAK="${DAED_DB}.bak.$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$DAED_DB")"
  cp -a "$DAED_DB" "$BAK"
  ok "已备份 $BAK"

  python3 - "$DAED_DB" "$DAED_UPSTREAM" <<'PY'
import re
import sqlite3
import sys

db, upstream = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.cursor()

dns_value = (
    "dns {\n"
    "upstream {\n"
    "  mosdns: '%s'\n"
    "}\n"
    "\n"
    "routing {\n"
    "  request {\n"
    "    fallback: mosdns\n"
    "  }\n"
    "}\n"
    "}\n"
) % upstream

cur.execute("update dns set dns=? where selected=1", (dns_value,))
if cur.rowcount == 0:
    cur.execute("update dns set dns=?", (dns_value,))
print("  dns 上游已设置为 %s" % upstream)

# dial_mode 不能是 ip，否则域名分流失效
cur.execute("select id, global from configs where selected=1")
row = cur.fetchone()
if row:
    cid, g = row
    m = re.search(r'dial_mode\s*:\s*"([^"]*)"', g)
    current = m.group(1) if m else None
    if current in (None, "ip"):
        if m:
            g2 = re.sub(r'dial_mode\s*:\s*"[^"]*"', 'dial_mode:"domain++"', g, count=1)
        else:
            g2 = g.replace("{", '{\n  dial_mode:"domain++"', 1)
        cur.execute("update configs set global=? where id=?", (g2, cid))
        print('  dial_mode: %s -> domain++' % (current or "(未设置)"))
    else:
        print("  dial_mode 已是 %s，保持不变" % current)

cur.execute("select routing from routings where selected=1")
r = cur.fetchone()
routing = r[0] if r else ""
checks = [
    ("国内 IP 直连",   re.search(r'dip\(geoip:cn\)\s*->\s*direct', routing)),
    ("国内域名直连",   re.search(r'domain\(geosite:cn\)\s*->\s*direct', routing)),
    ("默认走代理",     re.search(r'fallback\s*:\s*proxy', routing)),
    ("私有地址直连",   re.search(r'dip\(geoip:private\)\s*->\s*direct', routing)),
]
missing = [name for name, hit in checks if not hit]
if missing:
    print("  [!] 以下路由规则没找到，请到 daed WebUI 手动确认：%s" % "、".join(missing))
else:
    print("  分流规则检查通过")

con.commit()
con.close()
PY

  $SYSTEMCTL start daed
  sleep 3
  if $SYSTEMCTL is-active --quiet daed; then
    ok "daed 已启动"
  else
    warn "daed 未启动，请检查：journalctl -u daed -n 50"
  fi
  fi
fi

# ============================ 8. 规则自动更新 ============================
step "安装规则自动更新（每周定时）"

cat > /usr/local/bin/update-rules.sh <<'UPD'
#!/usr/bin/env bash
#  更新 MosDNS 分流规则：下载最新 geosite/geoip dat → 转成文本规则 → 重启 mosdns
#  用法：sudo update-rules.sh
set -Eeuo pipefail

RULES_DIR="/etc/mosdns/rules"
CONVERTER="/usr/local/bin/dat2rules.py"
KEEP=3

[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo update-rules.sh" >&2; exit 1; }
[ -x "$CONVERTER" ] || { echo "缺少 $CONVERTER（请先运行 deploy.sh）" >&2; exit 1; }

WORK="$(mktemp -d /tmp/mosdns-rules.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for name in geosite.dat geoip.dat; do
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$WORK/$name" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$name" \
    || { echo "下载 $name 失败" >&2; exit 1; }
done

mkdir -p "$WORK/new"
python3 "$CONVERTER" "$WORK/geosite.dat" "$WORK/geoip.dat" "$WORK/new" \
  || { echo "规则转换失败" >&2; exit 1; }

BAK="${RULES_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$RULES_DIR" "$BAK"
install -m 0644 "$WORK/new"/geosite_*.txt "$WORK/new"/geoip_*.txt "$RULES_DIR/"
# 只保留最近 KEEP 份备份
ls -t "${RULES_DIR}".bak.* 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf

systemctl restart mosdns
sleep 2
if systemctl is-active --quiet mosdns; then
  echo "[+] 规则已更新，mosdns 重启正常（备份：$BAK）"
else
  echo "[!] mosdns 重启失败，回滚旧规则" >&2
  rm -f "$RULES_DIR"/geosite_*.txt "$RULES_DIR"/geoip_*.txt
  cp -a "$BAK"/. "$RULES_DIR"/
  systemctl restart mosdns
  exit 1
fi
UPD
chmod 0755 /usr/local/bin/update-rules.sh
ok "已安装 /usr/local/bin/update-rules.sh（手动更新：sudo update-rules.sh）"

# 用 crontab 做每周定时（幂等：已配置过则先清掉旧条目再写入）
CRON_TAG="# mosdns-rules-update"
CRON_LINE='30 4 * * 0 /usr/local/bin/update-rules.sh >> /var/log/mosdns/rules-update.log 2>&1'
( crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | grep -vF "/usr/local/bin/update-rules.sh" || true
  printf '%s\n%s\n' "$CRON_TAG" "$CRON_LINE" ) | crontab - \
  || die "写入 crontab 失败"

# 确保 cron 服务在跑（Debian 叫 cron，RHEL 系叫 crond）
if $SYSTEMCTL is-active --quiet cron 2>/dev/null; then
  ok "cron 服务运行中"
elif $SYSTEMCTL is-active --quiet crond 2>/dev/null; then
  ok "crond 服务运行中"
elif command -v apt-get >/dev/null 2>&1; then
  $SYSTEMCTL enable --now cron >/dev/null 2>&1 || true
  ok "已启动 cron 服务"
elif command -v dnf >/dev/null 2>&1; then
  $SYSTEMCTL enable --now crond >/dev/null 2>&1 || true
  ok "已启动 crond 服务"
fi
ok "已配置 crontab：每周日 04:30 自动更新规则（查看：crontab -l）"

# ============================ 9. 自检 ============================
step "部署自检"

printf '  %-12s : %s\n' "MosDNS" "$("$BIN_PATH" version 2>&1 | head -1 || true)"
printf '  %-12s : %s\n' "服务状态" "$($SYSTEMCTL is-active mosdns 2>/dev/null || true)"
printf '  %-12s : %s\n' "监听端口" "$(ss -tuln 2>/dev/null | grep -E ':(53|5333)\b' | awk '{print $5}' | sort -u | tr '\n' ' ' || true)"
printf '  %-12s : %s\n' "规则文件" "$(ls "$RULES_DIR" 2>/dev/null | tr '\n' ' ' || true)"
echo

if command -v dig >/dev/null 2>&1; then
  printf '  %-24s %-10s %s\n' "域名" "状态" "应答"
  for d in www.baidu.com www.qq.com www.google.com; do
    out="$(timeout 20 dig @127.0.0.1 -p 53 "$d" A +time=9 +tries=2 2>&1 || true)"
    st="$(printf '%s' "$out" | grep -oE 'status: [A-Z]+' | head -1 | cut -d' ' -f2 || true)"
    an="$(printf '%s' "$out" | awk '/ANSWER SECTION/{f=1;next} f&&NF{print $5; exit}' || true)"
    printf '  %-24s %-10s %s\n' "$d" "${st:-无响应}" "${an:-<空>}"
  done
  echo
  printf '  %s\n' "国内域名应返回国内 IP；国外域名首次查询若超时属 DoH 冷启动，重查即正常"
else
  info "未安装 dig，跳过解析测试：apt install -y dnsutils"
fi

step "完成"
cat <<EOF3

  MosDNS 配置    ${CONF_DIR}/config.yaml
  规则目录       ${RULES_DIR}
  日志           ${LOG_FILE}

  下一步：
    1) 把局域网终端的 DNS 指向本机 IP（53 端口）
    2) 常用命令：
         systemctl status mosdns
         systemctl restart mosdns
         tail -f ${LOG_FILE}
    3) 规则每周日 04:30 自动更新；手动更新：sudo update-rules.sh
EOF3
