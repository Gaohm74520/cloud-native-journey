# 第 15 课 · DNS + NFS + NGINX 综合案例：从零搭一套五机架构

> 本文是《从零学云原生》系列第 15 篇。
> 环境：RHEL 10 / openEuler 22.03 / VMware Workstation 17

**日期**：2026-11-18 ~ 11-21 ｜ **总耗时**：约 6 小时（跨 4 天）

---

## 引子：一个「五台机器」的作业

机构留了个综合案例：

```
主机规划：
client  192.168.10.7    客户端
web     192.168.10.8    nginx
nfs     192.168.10.9    nfs-server
dns1    192.168.10.10   named（主）
dns2    192.168.10.11   named（从）

要求：
1. HTTPS 访问 www.chengke.com
2. 欢迎页面由 NFS 提供
3. DNS 主从同步，能解析 www.chengke.com
4. 四台服务器时间同步（用阿里 NTP）
5. 自绘架构图
```

**看着像「四个服务拼一起」，做起来是「六个坑连成串」。**

**这篇就写这六个坑——它们比配置步骤值钱得多。**

---

# 一、资源规划：16 GB 装 4 台

**物理机 16 GB，已用 7.1 GB，可用 8.5 GB。**

| 角色 | 机器 | IP | 内存 |
|---|---|---|---|
| web | k3s-node1 | .129 | 4 GB |
| nfs | nfs-client | .130 | 2.8 GB |
| dns1 | openEuler | .131 | 4 GB |
| dns2 | 新建（克隆） | .132 | 1 GB |
| client | Windows 宿主机 | .1 | — |

**加第 4 台后总分配 11.8 GB，物理机还有 4 GB 余量。**

**client 用宿主机，不单独开虚拟机——理由写在报告里：**

> ① 资源限制（再开一台 Windows 会开始大量换页）；
> ② client 只是「验证角色」，Windows 的 nslookup + 浏览器完全够；
> ③ 从真实场景看，用户就是从外部终端访问。

**老师一般认这种说明——它说明你想过，不是偷懒。**

---

# 二、六个坑

## 坑 1：VMware 克隆默认放 C 盘

**克隆时没注意，Location 默认是：**

```
C:\Users\15091\Documents\Virtual Machines\dns2
```

**结果：**

```
An error occurred while cloning: Insufficient permission to access the file.
```

**原因：C 盘的 `C:\Users\...\Documents` 有 Windows 的权限保护，完整克隆要往那里写几 GB。**

**改到 `E:\VM\dns2`（先建目录），解决。**

**记住：VMware 的 Location 就是 `.vmx` 所在目录，不会自动加子目录。**

---

## 坑 2：克隆机继承 fstab，开机进紧急模式 ⭐

**dns2 开机后：**

```
You are in emergency mode. After logging in, type "journalctl -xb" ...
Give root password for maintenance
```

**进去后 `hostnamectl` 也报错：**

```
Failed to connect to system scope bus via local transport: No such file or directory
```

**一开始以为是 hostnamectl 坏了，其实是：**

```
fstab 挂载失败 → systemd 进 emergency mode
                     ↓
              dbus 没启动 → hostnamectl 报错
```

**根因：nfs-client 的 `/etc/fstab` 里有这一行（为了永久挂 ISO）：**

```conf
/dev/sr0    /mnt/iso    iso9660    defaults,ro    0 0
```

**克隆出的 dns2 光驱没连 → `/mnt/iso` 挂不上 → 系统进紧急模式。**

**修复三步：**

```bash
mount -o remount,rw /                        # 让根分区可写
sed -i 's|^/dev/sr0|#/dev/sr0|' /etc/fstab   # 注释掉那一行
reboot
```

**正确写法（以后所有 fstab 都这么写）：**

```conf
/dev/sr0    /mnt/iso    iso9660    defaults,ro,nofail    0 0
```

**`nofail` = 挂不上就算了，别拦着系统启动。**

**适用：光驱、移动硬盘、网络存储、NFS——凡是「可能不存在」的设备。**

---

## 坑 3：克隆机 `/mnt/iso` 没挂 → dnf 失败

**在 dns2 上装 bind：**

```
Errors during downloading metadata for repository 'BaseOS':
  - Curl error (37): Could not read a file:// file for file:///mnt/iso/BaseOS/repodata/repomd.xml
```

**原因：**

```
dns2 继承了 nfs-client 的 /etc/yum.repos.d/dvd.repo（指向 file:///mnt/iso）
     但没继承「ISO 已挂载」这个状态
```

**修：VMware 里给 dns2 挂 ISO → `mount /dev/sr0 /mnt/iso` → 重试。**

## 坑 2 和坑 3 是同一个模式

| 继承的 | 缺失的 | 后果 |
|---|---|---|
| `/etc/fstab` 里的 `/dev/sr0` | ISO 没挂 | 紧急模式 |
| `dvd.repo` 指向 `/mnt/iso` | 同上 | dnf 失败 |

> **克隆一台机器，得到的是「它的配置文件」，不是「它的运行时状态」。**
> **所有依赖外部设备的配置，都要在克隆后重新检查。**

**克隆后必查清单：**

| 配置 | 查什么 |
|---|---|
| `/etc/fstab` | 挂载点是否都存在（加 `nofail`） |
| `/etc/yum.repos.d/` | 本地源是否可访问 |
| 网络配置 | IP 是否和原机冲突 |
| 自启服务 | 有没有多余的（k3s / nfs 挂载） |
| SSH host key | 和原机相同（会导致 `Host key verification failed`） |

---

## 坑 4：`su root` 一直「拒绝权限」

**现象：**

```
[ghm-stu@openEuler-gaohm ~]$ su root
密码：
su: 拒绝权限
```

**试了多次都不行，但 `sudo` 是好的：**

```
[ghm-stu@openEuler-gaohm ~]$ sudo vi /etc/named.conf
[sudo] ghm-stu 的密码:
（成功打开）
```

**结论：别在这上面耗。**

| 方案 | 说明 |
|---|---|
| **用 `sudo`** | 每条命令前加 sudo，够用 |
| **Xshell 直接 root 登录** | 最干净，少一层 PAM |

**既然都要输 root 密码，不如直接登 root。**

> **`su` 的权限控制在 `/etc/pam.d/su` 里，可能被 `pam_wheel.so` 或 `pam_faillock` 拦。**
> **但这是「运维配置问题」，不是「你操作错了」——绕过去就行。**

---

## 坑 5：`stop` 不等于 `disable`——Traefik 抢了 80 端口 ⭐ 最有价值

**背景：k3s-node1 上原来跑 k3s，现在要当纯 web 服务器，所以停掉 k3s。**

**停了，装 nginx，启动，然后：**

```bash
curl -i http://127.0.0.1
```

```
HTTP/1.1 404 Not Found
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Content-Length: 19

404 page not found
```

**但 nginx 的 `access.log` 是空的。**

**排查用了四步：**

### ① 看响应特征

```
没有 Server: nginx 头
X-Content-Type-Options: nosniff
Content-Length: 19            ← "404 page not found\n" 正好 19 字节
```

**这是 Go 的 `http.Error()` 的标准输出，不是 nginx。**

### ② 看谁在听 80

```bash
sudo ss -tlnp | grep ':80'
```

**显示 nginx 在听。**

**但请求没到 nginx——矛盾。**

### ③ 再看 k3s 状态

```bash
sudo systemctl status k3s --no-pager | head -3
```

```
Active: active (running) since Sat 2026-11-21 08:44:57 CST; 18min ago
```

**k3s 又起来了。**

### ④ 根因

**`systemctl stop k3s` 只是「现在停」，没改 `enabled`。**

**重启后 k3s 自启 → 它的 `svclb`（klipper-lb）往 iptables 里写 DNAT 规则，把 80 转发到 Traefik Pod → 你 curl 到的是 Traefik。**

**修：**

```bash
sudo systemctl disable --now k3s
sudo reboot        # 清掉 iptables 残留规则
```

**重启后：**

```bash
curl -i http://127.0.0.1
```

```
HTTP/1.1 200 OK
Server: nginx/1.26.3
```

## 这个坑的三个知识点

**① `stop` 和 `disable` 的区别**

| 命令 | 现在 | 下次开机 |
|---|---|---|
| `systemctl stop` | 停 | **自动启动** |
| `systemctl disable --now` | 停 | **不启动** |

**② iptables 规则不会因为服务停止而消失**

**k3s 的 `svclb` 用 DNAT 做负载均衡，规则写在 iptables 里。停服务只杀进程，规则还在。**

**只能靠重启（或者手工删规则）清掉。**

**③ 从响应特征反推「是谁在回答」**

| 响应特征 | 谁 |
|---|---|
| `Server: nginx` + HTML 404 | nginx |
| **纯文本 `404 page not found` + `nosniff`** | **Go 程序（Traefik/K8s/kubelet）** |
| `clnt_create: RPC: Timed out` | rpcbind 没起 |
| `host unreachable` | 网络层到不了 |
| `connection timed out` | 到了，但端口没响应 |

**这套「看响应认服务」的本事，比记命令有用。**

---

## 坑 6：IP 悄悄从 .131 变成了 .133

**Windows 上 `nslookup` 一直超时，但 dns1 上 `dig @127.0.0.1` 正常。**

**查 UDP 监听：**

```bash
sudo ss -ulnp | grep ':53'
```

```
UNCONN 0 0  192.168.191.133:53     ← 不是 .131！
```

**这台机器的 IP 变了。**

**再查：**

```bash
ip a show ens160 | grep inet
```

```
inet 192.168.191.133/24 ... dynamic      ← dynamic = DHCP
```

```bash
cat /etc/sysconfig/network-scripts/ifcfg-ens160
（空）
```

**两个发现：**

1. **IP 是 DHCP 分配的**
2. **`ifcfg-ens160` 是空的**

**原因：openEuler 22.03 默认用 NetworkManager 的 keyfile 格式，配置在 `/etc/NetworkManager/system-connections/ens160.nmconnection`，不在 `ifcfg-ens160`。**

**所以之前改 `ifcfg` 根本没生效。**

**修：用 `nmcli`（唯一可靠的方式）：**

```bash
sudo nmcli connection modify ens160 ipv4.method manual ipv4.addresses 192.168.191.131/24 ipv4.gateway 192.168.191.2 ipv4.dns 223.5.5.5
sudo nmcli connection up ens160
```

**验证（最关键的判断）：**

```bash
ip a | grep dynamic
```

**有 `dynamic` 就是 DHCP，不管你在配置文件里写了什么。**

**四台最后都统一成 static。**

---

# 三、DNS：为什么我设计了「正反两个测试」

**配完 DNS 主从，如果只做一件事——`dig` 通了就完事——那你只是「配对了」，不是「懂了」。**

**我设计了两个测试：**

## 测试 A：改记录 + 改 serial

```conf
serial 2026111904 → 2026111905
加一行 test1 IN A 192.168.191.130
```

**结果：dns1 返回 `.130`，dns2 也返回 `.130`。**

**同步成功。**

## 测试 B：改记录 + 不改 serial

```conf
serial 保持 2026111905
test1 的 IP 从 .130 改成 .131
```

**结果：**

```
dns1：test1 → .131   （新）
dns2：test1 → .130   （旧）
两台 serial 都是 2026111905
```

**这才是真正理解 serial 的地方。**

> **从服务器判断「要不要同步」，唯一依据是 serial 有没有变大。**
> **它不比对内容，不算哈希，不比时间戳。**

**这个现象叫 `stale data`（陈旧数据），在真实运维里是事故：**

```
客户端问 dns1 → 拿到新 IP ✅
客户端问 dns2 → 拿到旧 IP ❌
   ↓
"为什么我这边打不开，别人能打开？"
```

**最难查的故障，因为「有时候好有时候坏」。**

## 一个副产品：`allow-transfer` 为什么不能配 `any`

**AXFR 是把整个 zone 一次传走。**

**如果 `allow-transfer { any; };`：**

```bash
dig axfr chengke.com @你的IP
```

**一条命令拉走你所有域名和服务器 IP。**

**这是渗透测试的标准第一步，叫 Zone Transfer 信息收集。**

**正确写法：**

```conf
allow-transfer { 192.168.191.132; };    # 只允许 dns2
```

---

# 四、四件事各管一段

**这套架构最容易混淆的地方：以为它们是「配合」，其实是「串联」。**

```
DNS   →  名字变 IP
HTTPS →  加密传输
nginx →  提供页面
NFS   →  存文件
```

| 环节 | 只管 | 不管 |
|---|---|---|
| DNS | `www.chengke.com` → `192.168.191.129` | 那个 IP 上跑什么、开什么端口 |
| HTTPS | 加密 + 证书 | 页面内容从哪来 |
| nginx | 读文件、返回 HTTP | 文件存在本地还是远端 |
| NFS | 提供文件系统 | 谁在读 |

**所以排障必须「一段一段切」：**

```
① nslookup 通吗？        → DNS 段
② curl http 通吗？       → nginx 段
③ curl https 通吗？      → 证书段
④ 改 NFS 文件页面变吗？  → 存储段
⑤ chronyc sources 有 ^* 吗？ → 时间段
```

**任何一段断了，都表现为「浏览器打不开」——但原因完全不同。**

**这次四个错误恰好覆盖了四段：**

| 错误 | 断在哪段 |
|---|---|
| `DNS request timed out` | DNS 段（IP 变了） |
| `404 page not found` | nginx 段（Traefik 抢端口） |
| `ERR_SSL_UNRECOGNIZED_NAME_ALERT` | 证书段（连错服务器） |
| 页面没变 | 存储段（挂载没生效） |

**能从报错看出断在哪段，这套架构就懂了。**

---

# 五、HTTPS 的两个细节

## ① 自签证书必须有 SAN

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/chengke.key \
  -out /etc/nginx/ssl/chengke.crt \
  -subj "/C=CN/ST=Chongqing/L=Chongqing/O=Chengke/OU=IT/CN=www.chengke.com" \
  -addext "subjectAltName=DNS:www.chengke.com"
```

**关键是 `-addext "subjectAltName=DNS:..."`。**

**现代浏览器只认 SAN，不看 CN。**

**只写 CN 不写 SAN → `NET::ERR_CERT_COMMON_NAME_INVALID`。**

## ② 两种证书错误要分清

| 错误 | 含义 |
|---|---|
| `ERR_SSL_UNRECOGNIZED_NAME_ALERT` | **连错了服务器**（对方证书里没这个域名） |
| `NET::ERR_CERT_AUTHORITY_INVALID` | **连对了**，只是自签不被信任 |

**第一次看到 `UNRECOGNIZED_NAME_ALERT`，是因为 `chengke.com` 这个域名在公网上真实存在，浏览器连到了别人的服务器。**

**改 hosts 指向 `.129` 后，才变成第二种——那才是我们要的。**

---

# 六、架构图

**用 Python + Pillow 生成的（3200×2000）。**

**三个部分：**

```
左侧：5 个角色 + 5 条链路
右侧：8 项关键参数（域名 / A 记录 / serial / 证书有效期 / 挂载点）
底部：时间同步说明
```

**画图时踩了个小坑：用 `Consolas`（等宽字体）渲染中文，全部变成方框。**

**因为 Consolas 不含中文字形。**

**修：中文一律用微软雅黑，英文/路径用等宽。**

---

# 七、这六小时学到什么

## 1. 「克隆」继承配置，不继承状态

**fstab、yum 源、IP、host key——全部要重新检查。**

## 2. `stop` 和 `disable` 是两件事

**这条在真实运维里排名前列。**

## 3. 从响应特征能认出「是谁在回答」

| 特征 | 服务 |
|---|---|
| `Server: nginx` | nginx |
| 纯文本 `404 page not found` | Go 程序 |
| `RPC: Timed out` | rpcbind |
| `host unreachable` | 网络层 |
| `connection timed out` | 端口/防火墙 |

## 4. serial 是 DNS 主从的唯一开关

**而且「不改 serial → 数据陈旧」这个反面测试，比正向测试更有说服力。**

## 5. 改网络要用工具（`nmcli`），不要手改配置文件

**openEuler 用 keyfile 格式，RHEL 9+ 也可能用。改错文件 = 白改。**

**验证方法：`ip a | grep dynamic`。**

## 6. 排障顺序：先确认「在哪台」，再确认「是不是它」

**这次在 k3s-node1 上装 bind，以为在 openEuler 上——白装一遍。**

**以后每个命令前，先看提示符里的主机名。**

---

# 一句话总结

> **四个服务本身都不难，难的是「它们各自出错时长得不一样」。**
>
> **而「看懂错误属于哪一段」，是这套架构真正的门槛。**
