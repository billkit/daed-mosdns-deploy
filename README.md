# daed + MosDNS 部署方案

在 **daed**（dae 的 WebUI 版本）网关上，用 **MosDNS** 接管 DNS 分流。

- 国内域名 → 国内 DoH 上游，返回真实国内 IP，**由 daed 判定 `direct` 直连**
- 国外域名 → 国外 DoH 上游（经代理解析，无污染），**由 daed 判定 `proxy`**
- 广告域名 → 直接 `NXDOMAIN` 拦截
- 局域网设备把 DNS 指向网关即可用；daed 的 `:53` 劫持链路由 MosDNS 提供后端

> 本方案可以直接替换掉 AdGuardHome：AdGuardHome 的「DNS 上游 + 黑白名单」职责全部由 MosDNS 承担，  
> 而且 MosDNS 是单二进制、配置更透明、内存占用低（约 90MB）。

---

## 目录

- [架构](#架构)
- [前置条件](#前置条件)
- [一键部署](#一键部署)
- [手动分步部署](#手动分步部署)
- [验证](#验证)
- [日常运维](#日常运维)
- [卸载](#卸载)

---

## 架构

```
                局域网终端
                     │  DNS 查询
        ┌────────────┴────────────┐
        │                         │
   DNS 指向网关                 DNS 指向任意公网
   (192.168.x.x:53)             (223.5.5.5 / 8.8.8.8 ...)
        │                         │
        │                         ▼
        │                  daed 无条件劫持所有 :53
        │                         │
        │                         ▼
        │              MosDNS  (网关IP:5333)   ← daed 的 DNS 上游
        │                         │
        └────────────────────────►│
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
              国内域名 (geosite:CN)        其他域名
                    │                           │
            阿里 DoH (443)              Google DoH (443)
            223.5.5.5 / 223.6.6.6       8.8.8.8 / 8.8.4.4
                    │                           │
                    ▼                           ▼
          daed: dip(geoip:cn)          daed: dip(8.8.8.8) / fallback
                → direct                     → proxy
```

**MosDNS 监听两个端口**

| 入口                   | 端口     | 用途                   |
| -------------------- | ------ | -------------------- |
| `udp/tcp_server_lan` | `53`   | 局域网终端把 DNS 直接设为网关 IP |
| `udp/tcp_server`     | `5333` | daed 的 DNS 上游指向这里    |

两个入口共用同一条 `main_sequence`，行为完全一致。

---

## 前置条件

| 项目 | 要求                                                       |
| -- | -------------------------------------------------------- |
| 系统 | Debian 11/12、Ubuntu 20.04+，或任何使用 systemd 的发行版            |
| 架构 | amd64 / arm64 / armv7 / armv6                            |
| 权限 | root                                                     |
| 依赖 | `curl`、`unzip` 或 `python3`（任一即可，用于解压官方 zip 包；Debian/Ubuntu 自带） |
| 内核 | daed 需要 **Linux ≥ 5.8 且开启 BTF**。`uname -r` 低于 5.8 请先升级内核 |
| 网络 | 能访问 GitHub                                               |

确认内核是否支持 eBPF/BTF：

```bash
uname -r
ls /sys/kernel/btf/vmlinux
```

`/sys/kernel/btf/vmlinux` 不存在 → daed 起不来，需要换内核（如 `linux-image-cloud-amd64` 或 XanMod）。

---

## 一键部署

```bash
curl -fLO https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/deploy.sh
sudo bash deploy.sh
```

没有任何参数，全程自动：

1. 检查系统、架构、`53` 端口占用（若被 `systemd-resolved` 占用会自动关掉它的 `DNSStubListener`）
2. 安装 daed（已装则跳过；官方 `.deb` / `.rpm`）
3. 安装 MosDNS 到 `/usr/local/bin/mosdns`（已装同版本则跳过下载）
4. 准备 `geosite.dat` / `geoip.dat`（优先用本机已有的，否则在线下载），转换成文本规则写入 `/etc/mosdns/rules/`（规则已存在则跳过）
5. 生成 `/etc/mosdns/config.yaml`（已有配置自动备份）并启动 systemd 服务（启动前先做配置加载预检）
6. 把 daed 的 DNS 上游指向 MosDNS、`dial_mode` 改为 `domain++`（已指向则跳过，不重启 daed；修改时备份 `wing.db` 并短暂重启 daed）
7. 安装规则自动更新：`/usr/local/bin/update-rules.sh` + crontab 每周日 04:30
8. 输出自检结果

各组件都带存在性检测：没装就安装，已存在就只做配置。

---

## 手动分步部署

不想用脚本、或要搞清每一步在做什么，照下面走。

### 1. 安装 daed

```bash
# Debian / Ubuntu
curl -fL -o /tmp/daed.deb \
  https://github.com/daeuniverse/daed/releases/latest/download/installer-daed-linux-x86_64.deb
apt install -y /tmp/daed.deb

# RHEL / CentOS / Fedora
dnf install -y https://github.com/daeuniverse/daed/releases/latest/download/installer-daed-linux-x86_64.rpm
```

安装后开 WebUI（`http://<网关IP>:2023`）完成节点、订阅、分组配置，确认代理本身能通，再往下走。

### 2. 安装 MosDNS

```bash
ARCH=amd64        # arm64 / arm-7 / arm-6
VER=v5.3.4
curl -fL -o /tmp/mosdns.zip \
  https://github.com/IrineSistiana/mosdns/releases/download/$VER/mosdns-linux-$ARCH.zip
unzip -q /tmp/mosdns.zip -d /tmp/mosdns \
  || python3 -c "import zipfile;zipfile.ZipFile('/tmp/mosdns.zip').extractall('/tmp/mosdns')"
install -m 0755 /tmp/mosdns/mosdns /usr/local/bin/mosdns
mosdns version
```

> MosDNS v5 不能直接读 `geosite.dat` / `geoip.dat`，需要先转成文本规则（见下一步）。

### 3. 生成规则文件

转换器由 `deploy.sh` 自动安装到 `/usr/local/bin/dat2rules.py`，也可以从脚本里单独取出。  
导出 tag 固定为：geosite 的 `CN`、`CATEGORY-ADS-ALL`，geoip 的 `CN`、`PRIVATE`。

```bash
dat2rules.py /usr/share/v2ray-rules-dat/geosite.dat \
             /usr/share/v2ray-rules-dat/geoip.dat \
             /etc/mosdns/rules
```

产出：

| 文件                             | 条数（参考）   |
| ------------------------------ | -------- |
| `geosite_CN.txt`               | ~111,000 |
| `geosite_CATEGORY_ADS_ALL.txt` | ~186,000 |
| `geoip_CN.txt`                 | ~9,600   |
| `geoip_PRIVATE.txt`            | ~18      |

没有本地 dat 就下载（Loyalsoldier 维护，每天更新）：

```bash
curl -fL -o /tmp/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
curl -fL -o /tmp/geoip.dat   https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
```

### 4. 写配置文件

`/etc/mosdns/config.yaml`：

```yaml
log:
  level: info
  file: "/var/log/mosdns/mosdns.log"

api:
  http: "127.0.0.1:9080"

include: []

plugins:
  # ================= 规则数据 =================
  - tag: geosite_cn
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/geosite_CN.txt"

  - tag: geosite_ads
    type: domain_set
    args:
      files:
        - "/etc/mosdns/rules/geosite_CATEGORY_ADS_ALL.txt"

  - tag: geoip_cn
    type: ip_set
    args:
      files:
        - "/etc/mosdns/rules/geoip_CN.txt"

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
  - tag: main_sequence
    type: sequence
    args:
      - exec: $cache
      - matches: qname $geosite_ads
        exec: reject 3
      - matches: qname $geosite_cn
        exec: $ali_dns
      - matches: qname $geosite_cn
        exec: accept          # 命中国内后终止序列，不再走兜底上游
      - exec: $wan_dns

  # ================= 服务入口 =================
  # 局域网终端入口
  - tag: udp_server_lan
    type: udp_server
    args: { entry: main_sequence, listen: "0.0.0.0:53" }
  - tag: tcp_server_lan
    type: tcp_server
    args: { entry: main_sequence, listen: "0.0.0.0:53" }

  # daed 上游入口
  - tag: udp_server
    type: udp_server
    args: { entry: main_sequence, listen: "0.0.0.0:5333" }
  - tag: tcp_server
    type: tcp_server
    args: { entry: main_sequence, listen: "0.0.0.0:5333" }
```

> `forward` 上游要同时写 `addr` 和 `dial_addr`：`addr` 提供 SNI（证书校验目标），  
> `dial_addr` 是实际拨号的 IP。

检查配置能否加载（用临时端口，不影响线上）：

```bash
sed -e 's/127.0.0.1:9080/127.0.0.1:19080/' \
    -e 's/0.0.0.0:53/127.0.0.1:15353/' \
    -e 's/0.0.0.0:5333/127.0.0.1:15333/' \
    /etc/mosdns/config.yaml > /tmp/shadow.yaml
timeout 8 mosdns start -c /tmp/shadow.yaml -d /etc/mosdns
# 看到 "all plugins are loaded" 即正常
```

### 5. 安装 systemd 服务

用 mosdns 官方自带的服务安装命令（自动生成 `/etc/systemd/system/mosdns.service`，含 `Restart=always` 崩溃自动拉起）：

```bash
mkdir -p /var/log/mosdns
mosdns service install -d /etc/mosdns -c /etc/mosdns/config.yaml
systemctl daemon-reload
systemctl enable --now mosdns
systemctl status mosdns --no-pager
```

> 必须用 `Type=simple`（MosDNS 不实现 sd_notify，不要用 `Type=notify`）。

### 5.1 规则自动更新（可选）

geosite / geoip 数据会持续变化，建议让规则定期更新。一键脚本会安装
`/usr/local/bin/update-rules.sh` 并写入 crontab；手动部署可照做：

```bash
# 写入 crontab：每周日 04:30 自动更新（下载最新 dat → 转换 → 重启 mosdns，失败自动回滚）
( crontab -l 2>/dev/null; \
  echo '# mosdns-rules-update'; \
  echo '30 4 * * 0 /usr/local/bin/update-rules.sh >> /var/log/mosdns/rules-update.log 2>&1' ) | crontab -
crontab -l   # 确认
```

更新日志在 `/var/log/mosdns/rules-update.log`。

### 6. 配置 daed

有两种方式。

**方式 A：WebUI（推荐）**

1. 打开 `http://<网关IP>:2023`
2. `配置 → DNS` 里把上游改成：
   ```
   dns {
     upstream {
       mosdns: 'tcp+udp://<网关IP>:5333'
     }
     routing {
       request {
         fallback: mosdns
       }
     }
   }
   ```
3. `配置 → 全局` 里把 `dial_mode` 设为 `domain++`（至少不能是 `ip`）
4. 保存并应用

**方式 B：直接改数据库**（就是脚本用的方式，改前务必停 daed 并备份）

```bash
systemctl stop daed
cp -a /etc/daed/wing.db /etc/daed/wing.db.bak.$(date +%Y%m%d-%H%M%S)

python3 - <<'PY'
import re, sqlite3
db, upstream = "/etc/daed/wing.db", "tcp+udp://192.168.1.2:5333"   # 换成你的网关 IP
con = sqlite3.connect(db); cur = con.cursor()

dns_value = ("dns {\nupstream {\n  mosdns: '%s'\n}\n\nrouting {\n  request {\n"
             "    fallback: mosdns\n  }\n}\n}\n") % upstream
cur.execute("update dns set dns=? where selected=1", (dns_value,))
if cur.rowcount == 0:
    cur.execute("update dns set dns=?", (dns_value,))

cur.execute("select id, global from configs where selected=1")
cid, g = cur.fetchone()
m = re.search(r'dial_mode\s*:\s*"([^"]*)"', g)
if not m or m.group(1) == "ip":
    g2 = re.sub(r'dial_mode\s*:\s*"[^"]*"', 'dial_mode:"domain++"', g, count=1) if m \
         else g.replace("{", '{\n  dial_mode:"domain++"', 1)
    cur.execute("update configs set global=? where id=?", (g2, cid))

con.commit(); con.close()
print("done")
PY

systemctl start daed
```

> daed 的 DNS 上游要写**宿主机的真实 IP**（如 `192.168.1.2`），不要写 `127.0.0.1`。

**方式 C：什么都不改**

在 daed WebUI 里手动把 DNS 上游填成 `tcp+udp://<网关IP>:5333` 即可，  
`dial_mode` 保持默认的 `domain` 也能用（只要不是 `ip`）。

**daed 路由规则需要具备这几条**（daed 默认模板一般已包含）：

```
dip(geoip:cn)      -> direct      # 国内 IP 直连
domain(geosite:cn) -> direct      # 国内域名直连
dip(geoip:private) -> direct      # 私有地址直连（保证 MosDNS 自身可达）
fallback: proxy                   # 其余走代理
```

---

## 验证

### 1. 服务与端口

```bash
systemctl is-active mosdns daed
ss -tulnp | grep -E ':53\b|:5333'
```

### 2. 解析结果

```bash
for d in www.baidu.com www.taobao.com www.google.com github.com; do
  printf '%-20s ' "$d"
  dig @127.0.0.1 -p 5333 "$d" A +short | head -1
done
```

预期：

| 域名 | 期望 | 实际参考 |
| -- | -- | ---- |


| `www.baidu.com`  | 国内 IP    | `www.a.shifen.com.` → `183.2.172.177`     |  
| `www.taobao.com` | 国内 IP    | `...danuoyi.tbcache.com.` → `59.36.70.79` |  
| `www.google.com` | 可解析（经代理） | `142.251.x.x`                             |  
| `github.com`     | 可解析      | `20.x.x.x`                                |

**广告拦截**：

```bash
dig @127.0.0.1 -p 5333 doubleclick.net A
# 期望 status: NXDOMAIN
```

### 3. daed 的 `:53` 劫持链路

用「MosDNS 会拦截的域名」验证劫持是否转发到了 MosDNS：

```bash
dig @223.5.5.5 doubleclick.net A
# 期望 status: NXDOMAIN（说明查询被 daed 劫持转给了 MosDNS）
```

### 4. 分流方向

```bash
IP=$(dig @127.0.0.1 -p 5333 www.baidu.com A +short | grep -E '^[0-9.]+' | head -1)
tcpdump -i <网卡名> -n "tcp[tcpflags] & tcp-syn != 0 and dst host $IP" &
curl -sS --resolve "www.baidu.com:443:$IP" https://www.baidu.com -o /dev/null -w '%{http_code}\n'
```

抓到去向该 IP 的 SYN → 说明走的是 `direct`；  
抓不到、而是出现代理节点 IP → 走的是 `proxy`。

### 5. 出口 IP 对照

```bash
curl -s https://myip.ipip.net   # 国内站点：应显示本机 ISP（direct）
curl -s https://api.ip.sb/ip    # 国外站点：应显示代理节点 IP（proxy）
```

---

## 日常运维

```bash
# 状态 / 日志
systemctl status mosdns --no-pager
tail -f /var/log/mosdns/mosdns.log

# 改完配置
systemctl restart mosdns

# 只改了 daed 的 dns / routings / configs 时需重启 daed
systemctl restart daed

# 两个入口都测一遍
dig @127.0.0.1 -p 5333 www.google.com
dig @<网关IP> www.google.com

# 检查国内域名解析归属地
dig @127.0.0.1 -p 5333 www.baidu.com +short     # 应返回国内 IP

# 更新分流规则（下载最新 dat → 转换 → 重启 mosdns，失败自动回滚）
sudo update-rules.sh

# 规则会每周日 04:30 由 crontab 自动更新（日志：/var/log/mosdns/rules-update.log）
crontab -l | grep mosdns-rules-update
# 不想自动更新就删掉这两行：
#   crontab -e 删除 "# mosdns-rules-update" 和下面一行
```

### 常见调整

- **换上游**：改 `config.yaml` 里 `ali_dns` / `wan_dns` 的 `addr` + `dial_addr`（DoH 用 `https://…/dns-query` + 443 端口）。
- **关掉广告拦截**：删掉 `matches: qname $geosite_ads` + `exec: reject 3` 两行。
- **让某个域名强制走国内上游**：在 `$ali_dns` 之前插一条  
  `- matches: qname full:example.com` + `exec: $ali_dns` + 紧接一条 `exec: accept`。
- **内存偏紧**：减小 `cache.size`，或只保留 `CN` 不导出 `CATEGORY-ADS-ALL`（18 万条）。

---

## 卸载

```bash
# 1. 停并删 MosDNS（官方卸载命令）
mosdns service uninstall
rm -rf /etc/mosdns /var/log/mosdns /usr/local/bin/mosdns /usr/local/bin/dat2rules.py

# 1.1 删规则自动更新
( crontab -l 2>/dev/null | grep -vF '# mosdns-rules-update' | grep -vF '/usr/local/bin/update-rules.sh' || true ) | crontab -
rm -f /usr/local/bin/update-rules.sh

# 2. 恢复 daed 的 DNS 上游
#    WebUI → 配置 → DNS，改回原来的上游（如 udp://223.5.5.5:53），保存并应用
#    或从备份恢复：
systemctl stop daed
cp -a /etc/daed/wing.db.bak.<时间戳> /etc/daed/wing.db
systemctl start daed
```

---

## 参考

- [IrineSistiana/mosdns](https://github.com/IrineSistiana/mosdns)
- [daeuniverse/daed](https://github.com/daeuniverse/daed)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)

## License

MIT
