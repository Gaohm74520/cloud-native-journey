# 第 13 课 · NFS 与跨机存储：从 nobody 到 ReadWriteMany

> 本文是《从零学云原生》系列第 13 篇。
> 环境：RHEL 10 + openEuler 22.03 LTS SP4 + k3s v1.36.5

**日期**：2026-11-12 ｜ **耗时**：约 6 小时（含 openEuler 安装实验）

---

## 引子：PVC 有个说不出口的限制

第 12 课我学了 PVC，当时很得意：

```yaml
accessModes:
  - ReadWriteOnce
```

直到我读到这两个词的完整含义：

| 模式 | 含义 |
|---|---|
| `ReadWriteOnce`（RWO） | **只能被一个节点**读写 |
| `ReadWriteMany`（RWX） | 可以被**多个节点同时**读写 |

**k3s 自带的 `local-path` 只支持 RWO。**

**因为它的存储就在某一台节点的磁盘上：**

```text
/var/lib/rancher/k3s/storage/pvc-xxxx/
```

**Pod 调度到别的节点，就挂不上。**

**那如果我需要三个 Pod 共享同一个上传目录呢？**

**答案是 NFS。** 这一课就是为了补上这块。

---

# 一、先搭两台机器

**机构课的要求是"两台机器"，我一开始想用单机模拟（用 Pod 当客户端），但被否了：**

> "没有切实体会到两个机器一起运行，我感觉差了很多上手体验"

**于是克隆了一台。**

## 关键：克隆后必须做的三件事

**克隆虚拟机会带来三个隐藏问题：**

| 问题 | 后果 |
|---|---|
| **带着 k3s 一起起来** | 两个节点抢同一个 hostname，集群可能被搞坏 |
| **IP 相同** | 两台机器抢同一个地址 |
| **SSH host key 相同** | 客户端报"中间人攻击嫌疑" |

**所以克隆后的顺序是：**

```bash
# ① 断网开机（VMware 里取消"启动时连接"）
# ② 立刻禁掉 k3s
systemctl disable --now k3s

# ③ 改主机名
hostnamectl set-hostname nfs-client

# ④ 重新生成 SSH host key
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A
systemctl restart sshd

# ⑤ 重连网络，改 IP
nmcli connection modify ens160 ipv4.addresses 192.168.191.130/24
nmcli connection modify ens160 ipv4.gateway 192.168.191.2
nmcli connection modify ens160 ipv4.method manual
nmcli connection up ens160
```

## 最终环境

| 机器 | IP | 角色 |
|---|---|---|
| `k3s-node1` | 192.168.191.129 | NFS 服务端（也是 k3s 节点） |
| `nfs-client` | 192.168.191.130 | NFS 客户端（克隆机） |

---

# 二、服务端：导出目录

```bash
dnf install -y nfs-utils
mkdir -p /nfs/share
```

```bash
vi /etc/exports
```

```conf
/nfs/share 192.168.191.0/24(rw,sync,no_subtree_check)
```

```bash
systemctl enable --now nfs-server
showmount -e localhost
```

```text
Export list for localhost:
/nfs/share 192.168.191.0/24
```

**四个参数的含义：**

| 参数 | 作用 |
|---|---|
| `rw` | 可读可写 |
| `sync` | 写入立刻落盘 |
| `no_subtree_check` | 不做子目录检查（性能） |
| ~~`no_root_squash`~~ | **这次故意没加——为了踩坑** |

---

# 三、客户端：挂载

```bash
dnf install -y nfs-utils
mkdir -p /nfs/data
showmount -e k3s-node1
mount -t nfs k3s-node1:/nfs/share /nfs/data
df -h /nfs/data
```

```text
Filesystem            Size  Used Avail Use% Mounted on
k3s-node1:/nfs/share   ...
```

**挂上了。**

---

# 四、⭐ 那个 `Permission denied`

## 服务端写 → 客户端读：成功

```bash
# 服务端
echo "hello from server" > /nfs/share/hello.txt

# 客户端
cat /nfs/data/hello.txt
-rw-r--r--. 1 root root 18 ... hello.txt
```

## 客户端写：失败

```bash
# 客户端
echo "111" > /nfs/data/111.txt
```

```text
bash: /nfs/data/111.txt: 权限不够
```

## 为什么

```bash
# 服务端
ll -d /nfs/share
```

```text
drwxr-xr-x. 2 root root ... /nfs/share
```

**推理链：**

```text
目录权限 755 → 只有属主 root 能写
          ↓
客户端 root 发起写入
          ↓
exports 没写 no_root_squash → 默认 root_squash
          ↓
客户端的 root 被"压缩"成 nobody
          ↓
nobody 属于"其他用户"，只有 r-x
          ↓
权限不够
```

## 加上写权限后，`nobody` 出现了

```bash
# 服务端
chmod o+w /nfs/share

# 客户端
echo "111" > /nfs/data/111.txt
ls -l /nfs/data
```

```text
-rw-r--r--. 1 nobody nobody  4 ... 111.txt     ← 客户端 root 写的
-rw-r--r--. 1 root   root   18 ... hello.txt   ← 服务端 root 写的
```

**同一目录下两个文件，属主不同。**

**`root_squash` 这个抽象概念，在这一刻变成了一行 `nobody`。**

---

# 五、三种解法，三种代价

## ① 给目录加写权限

```bash
chmod o+w /nfs/share      # 目录变 777
```

**结果：属主还是 `nobody`，而且任何人（包括匿名用户）都能写。**

## ② 改目录属主为 nobody

```bash
chown nobody:nobody /nfs/share
```

**结果：属主 `nobody`，权限干净一些，但所有客户端共用同一个身份。**

## ③ `no_root_squash`

```bash
vi /etc/exports
```

```conf
/nfs/share 192.168.191.0/24(rw,sync,no_subtree_check,no_root_squash)
```

```bash
exportfs -ra
chown root:root /nfs/share && chmod 755 /nfs/share

# 客户端要重新挂载（参数在挂载时协商）
umount /nfs/data
mount -t nfs k3s-node1:/nfs/share /nfs/data

echo "333" > /nfs/data/333.txt
ls -l /nfs/data
```

```text
-rw-r--r--. 1 root root 8 ... hello3.txt     ← 属主是 root 了
```

## 对比

| 解法 | 客户端写的文件属主 | 生产可用性 |
|---|---|---|
| ① `chmod o+w` | `nobody` | ❌ 最差 |
| ② `chown nobody` | `nobody` | ⚠️ 一般 |
| ③ `no_root_squash` | **`root`** | ⚠️ **需限定 IP** |

## 第三种的真实代价

> **`no_root_squash` 的本质，是把服务端的 root 权限交给客户端。**
> **客户端被攻破，服务端也就沦陷了。**

**所以生产上还要加限制：**

```conf
# 只允许单个 IP
/nfs/share 192.168.191.10(rw,sync,no_root_squash)

# 或者用 Kerberos
/nfs/share 192.168.191.0/24(rw,sync,sec=krb5)
```

**这不是技术问题，是信任边界的设计选择。**

---

# 六、⭐ 接进 K8s：验证 RWX

## 挂 NFS 的 Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nfs-a
spec:
  containers:
    - name: app
      image: docker.m.daocloud.io/library/busybox
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: shared
          mountPath: /shared
  volumes:
    - name: shared
      nfs:
        server: 192.168.191.129
        path: /nfs/share
```

**关键：`nfs:` 而不是 `persistentVolumeClaim:`。**

> **机制：kubelet 在宿主机上做 mount，然后 bind 给容器。**
> **所以容器里不需要 `nfs-utils`。**

## 两个 Pod，一份数据

```bash
sed 's/nfs-a/nfs-b/' pod-a.yaml > pod-b.yaml
kubectl apply -f pod-a.yaml -f pod-b.yaml
```

```bash
# A 写
kubectl exec nfs-a -- sh -c 'echo "A写的" > /shared/from-a.txt'

# B 读
kubectl exec nfs-b -- cat /shared/from-a.txt
```

```text
A写的
```

```bash
# 宿主机上也看得到
ls -l /nfs/share
```

```text
-rw-r--r--. 1 root root 8 ... from-a.txt
```

**两个完全独立的 Pod，共享同一份数据。**

## 为什么这是 RWX

| 后端 | 存储位置 | 支持的 accessMode |
|---|---|---|
| `local-path` | **某一台节点的磁盘** | RWO |
| **NFS** | **网络上的共享目录** | **RWX** |

**"存储在网络上的"，才是"任何节点都能挂"的前提。**

**面试问答：**

> **问**："多个 Pod 需要共享同一个目录，怎么办？"
>
> **答**："PVC 用 `ReadWriteMany`。但 `local-path` 这类本地存储只支持 RWO，
> 需要换成 NFS、CephFS 或对象存储这类支持多节点挂载的后端。"

---

# 七、今天踩的坑

| # | 坑 | 现象 | 真相 |
|---|---|---|---|
| 1 | **ISO 挂载随重启丢失** | `dnf install` 报 `checksum 不正确` | `/mnt/iso` 根本没挂载，文件不存在 |
| 2 | 克隆机 IP 冲突 | 两台都是 192.168.191.129 | 克隆复制了网络配置 |
| 3 | 克隆机 SSH host key 相同 | `Host key verification failed` | 没重新生成 `ssh_host_*` |
| 4 | 克隆机 k3s 自启 | 节点冲突风险 | 必须先 `disable --now k3s` |
| 5 | `root_squash` 导致写不进去 | `Permission denied` | 客户端 root 被压成 `nobody` |
| 6 | 改 exports 后不生效 | 还是旧行为 | 需要 `exportfs -ra` + **重新挂载** |
| 7 | 路径手误 | 文件写到了本地 `/data/` | 应是 `/nfs/data/` |

## 第 1 个最值得记

```text
软件包 "gssproxy-0.9.2-10.el10.x86_64" 的 checksum 不正确
```

**这句话会把人引向"包损坏""源有问题"，实际是：**

```bash
Error opening /mnt/iso/BaseOS/Packages/gssproxy-...rpm: 没有那个文件或目录
```

**报错里其实已经写了"文件不存在"，但人只看见 `checksum 不正确`。**

**根因：本地 ISO 源依赖"ISO 一直挂载着"。重启后手动 mount 丢失，整个源就失效了。**

**永久修复：**

```bash
vi /etc/fstab
```

```conf
/dev/sr0    /mnt/iso    iso9660    defaults,ro    0 0
```

```bash
mount -a
```

---

# 八、面试题

**1. NFS 的 `root_squash` 是什么？**

客户端以 root 身份访问时，服务端会把该身份映射为 `nobody`，防止客户端获得服务端的 root 权限。代价是客户端 root 写文件时受 `nobody` 的权限限制。

**2. 什么情况下用 `no_root_squash`？**

只在**客户端完全可信**且**限定 IP 范围**时使用。否则等于把服务端 root 权限交给客户端。

**3. 为什么 `local-path` 只支持 ReadWriteOnce？**

存储实现在某一台节点的本地磁盘上。Pod 调度到其他节点时无法访问该路径，所以只能保证单节点读写。

**4. K8s 挂 NFS 时，为什么容器里不需要 nfs 客户端？**

因为挂载动作由 kubelet 在**宿主机**上完成，然后通过 bind mount 暴露给容器。容器看到的是普通目录。

**5. 改了 `/etc/exports` 后为什么没生效？**

有三层：`exportfs -ra` 重新加载导出表；已挂载的客户端需要**卸载重挂**（挂载参数在挂载时协商）；重启后还需要确保 `nfs-server` 开机自启。

---

# 九、一句话总结

> **NFS 这一课真正学到的，不是怎么配 `/etc/exports`，是两个概念：**
>
> **① `nobody` —— 权限在跨机器时是有"边界"的，不是自然延续的。**
> **② `RWX` —— 存储能不能共享，取决于它在"本地"还是"网络上"。**
>
> 而坑 #1 再一次证明：**报错信息会骗人，文件是否存在，得自己去看。**
