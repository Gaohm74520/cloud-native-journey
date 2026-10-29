# 第 04 课 · 网络与端口

> 本文是《从零学云原生》系列第 4 篇。
> 环境：RHEL 10 + podman，镜像走 `docker.m.daocloud.io` 代理。

**日期**：2026-10-29 ｜ **耗时**：约 1.5 小时

---

## 引子

`-p 8087:80` 这六个字符我敲了三天。

浏览器访问宿主机 8087，为什么能看到容器里 80 端口的东西？中间到底发生了什么？

这一课讲清楚，顺便搞明白一件事：**为什么应用一容器化，配置里写 `localhost` 连数据库就必失败。**

---

## 一、容器有自己的一整套网络

每个容器启动时都会得到**独立的网络命名空间**：

- 自己的 IP（如 `10.88.0.5`）
- 自己的网卡（`eth0`）
- 自己的路由表
- 自己的端口空间——**容器里的 80 和宿主机的 80 是两个完全不同的 80**

所以：**容器里的 `localhost` 是容器自己，不是宿主机。**

---

## 二、实验 1：看清端口映射

```bash
podman run -d --name net1 -p 8087:80 docker.m.daocloud.io/library/nginx
```

### 容器自己的 IP

```bash
podman inspect net1 --format '{{.NetworkSettings.IPAddress}}'
```

```text
10.88.0.5
```

### 映射关系

```bash
podman port net1
```

```text
80/tcp -> 0.0.0.0:8087
```

读法：**容器的 80 → 宿主机的 8087**。

### 宿主机谁在监听

```bash
ss -tlnp | grep 8087
```

```text
LISTEN 0 4096 0.0.0.0:8087 users:(("conmon",pid=12864,fd=5))
```

**注意：监听 8087 的不是 nginx**，是 podman 的转发进程在宿主机上开的口子。

### 容器里谁在监听

```bash
podman exec net1 ss -tlnp
```

报错：

```text
crun: executable file `ss` not found in $PATH
```

nginx 镜像是最小镜像，**没有 `ss`**。改用配置来看：

```bash
podman exec net1 cat /etc/nginx/conf.d/default.conf
```

```nginx
listen       80;
listen  [::]:80;
```

容器里只有 **80**。

> **一句话**：`-p 宿主机:容器` 是在宿主机上开一个口子，把流量转发进容器。**8087 这个端口在容器里根本不存在。**

---

## 三、EXPOSE 不等于发布

Dockerfile 里的 `EXPOSE 80` 只是**声明**“这个镜像打算用 80”，是给人看的文档。

**没有 `-p`，宿主机照样访问不到。**

| | 作用 | 给谁看 |
|---|---|---|
| `EXPOSE 80` | 声明用途（文档） | 读镜像的人 |
| `-p 8087:80` | 真正建立映射 | 宿主机上的访问者 |

---

## 四、实验 2：localhost 陷阱

在容器里访问自己的 80：

```bash
podman exec net1 curl -s -o /dev/null -w '%{http_code}\n' http://localhost:80
```

```text
200
```

在容器里访问 8087：

```bash
podman exec net1 curl -m 2 http://localhost:8087
```

```text
curl: (7) Failed to connect to localhost port 8087: Connection refused
```

**`Connection refused` 的含义是：这个端口上没有任何进程在监听**——操作系统的明确回答，不是“网络不通”。

### 三种报错，三种病

| 报错 | 含义 |
|---|---|
| `Connection refused` | 端口没人监听（服务没起 / 端口写错） |
| `Connection timed out` | 网络不通，包被丢了（防火墙、IP 错） |
| `bad address` / `could not resolve` | DNS 解析失败 |

### 这就是真实工作里最高频的故障

配置文件写着：

```yaml
database:
  host: localhost
  port: 3306
```

单机部署没问题。**一容器化，这句话就变成“去容器自己身上找 MySQL”**，永远找不到。

改法：换成**容器名**（同一个自定义网络内）或**宿主机 IP**。

---

## 五、实验 3：默认网络没有 DNS

```bash
podman run -d --name net2 docker.m.daocloud.io/library/nginx
podman inspect net2 --format '{{.NetworkSettings.IPAddress}}'
```

**用 IP 访问（成功）：**

```bash
podman run --rm docker.m.daocloud.io/library/busybox wget -qO- http://10.88.0.6
```

返回 nginx 的 HTML。

**用名字访问（失败）：**

```bash
podman run --rm docker.m.daocloud.io/library/busybox wget -qO- http://net2
```

```text
wget: bad address 'net2'
```

**网络是通的，但名字解析不了。**

> 踩坑记录：第一次跑失败了却什么都没输出，因为 `-q` 把报错也一起静默了。**调试时别用 `-q`。**
> 另外中间那个 `-O` 是大写字母 O，不是数字零。

---

## 六、`nameserver` 到底是什么意思

看两个容器的 `/etc/resolv.conf`：

```bash
podman exec app1 cat /etc/resolv.conf
```

```text
search dns.podman localdomain
nameserver 10.89.0.1
```

```bash
podman exec net1 cat /etc/resolv.conf
```

```text
search localdomain
nameserver 192.168.191.2
```

**`nameserver` 不是“解析出来的结果”，是“去问谁”。**

它是一个**查号台的号码**，不是查到的电话号码。

- `192.168.191.2` 是 VMware NAT 的网关（宿主机那一侧）——它认外网域名，但**不认识容器名**
- `10.89.0.1` 是 `mynet` 这个网络的网关，podman 在那儿跑了一个内置 DNS（`aardvark-dns`），**认识这个网络里所有容器名**

| | DNS 指向 | 认识 `baidu.com` | 认识 `app2` |
|---|---|---|---|
| 默认 bridge | 192.168.191.2（宿主机） | ✅ | ❌ |
| 自定义 mynet | 10.89.0.1（podman 内置） | ✅ | ✅ |

---

## 七、实验 4：自定义网络，名字能用了

```bash
podman network create mynet
podman run -d --name app1 --network mynet docker.m.daocloud.io/library/nginx
podman run -d --name app2 --network mynet docker.m.daocloud.io/library/nginx
```

```bash
podman run --rm --network mynet docker.m.daocloud.io/library/busybox wget -qO- http://app2
```

```text
Connecting to app2 (10.89.0.3:80)
<!DOCTYPE html>
...
```

**`app2` 被当场解析成 `10.89.0.3`。名字变成 IP 的过程就写在屏幕上。**

### 一条容易犯的错

这条命令必须在**接入 mynet 的容器里**跑，不能在宿主机上跑：

```bash
wget -qO- http://app2        # ❌ 宿主机不认识 app2
```

宿主机没加入这个网络，自然解析不了——**就像公司内部分机号，外线打不进来。**

---

## 八、这一节为什么值钱

**自定义网络内置 DNS，容器可以用名字互相找到。**

这就是 Kubernetes 里 Service 的原理。以后写 K8s 配置：

```yaml
env:
  - name: DB_HOST
    value: mysql-service
```

`mysql-service` 能被解析，靠的是**同一套机制**。

**面试可以这么说**：

> 默认 bridge 只做二层转发，没有内嵌 DNS，容器只能靠 IP 互访。自定义网络带内嵌 DNS（aardvark-dns），容器名可直接解析——这是 K8s Service 服务发现的基础。

---

## 九、四种网络模式

| 模式 | 特点 | 场景 |
|---|---|---|
| `bridge`（默认） | 独立命名空间 + NAT 出网 | 绝大多数 |
| `host` | 和宿主机共用网络，端口直接占用 | 性能敏感 |
| `none` | 只有 loopback | 纯计算任务 |
| `container:名字` | 共用另一个容器的网络 | sidecar |

---

## 十、安全实践：只绑本地回环

```bash
-p 127.0.0.1:8087:80
```

只有**本机**能访问，外网进不来。

**`-p 8087:80` 等价于 `0.0.0.0:8087:80`——所有网卡都开放。**

生产上把数据库、管理后台暴露到 `0.0.0.0`，是安全事故的常见来源。

---

## 十一、容器里没有诊断工具

这一课连续撞了两次：

```text
crun: executable file `ss` not found in $PATH
crun: executable file `getent` not found in $PATH
```

**这不是环境坏了，是镜像设计如此。** 最小镜像只保留“能跑起来”的必需品，装快、拉快、攻击面小。

极端情况叫 **distroless**——连 shell 都没有，`podman exec` 都进不去。

**排障工具在容器外面，不在里面。** 用它：

```bash
podman inspect / podman logs / podman top / podman port
```

---

## 十二、坑

| 现象 | 原因 |
|---|---|
| `address already in use` | 宿主机端口被占（旧容器没删） |
| 容器里 `localhost` 连不上 | 那是容器自己 |
| 用容器名访问失败 | 默认 bridge 没有 DNS |
| `EXPOSE` 写了还是访问不到 | `EXPOSE` 只是声明，必须有 `-p` |
| 端口映射了但 502 | 容器内服务监听在 `127.0.0.1` 而不是 `0.0.0.0` |

最后一条最隐蔽：**容器内的服务必须监听 `0.0.0.0`**，只听 `127.0.0.1` 的话，从宿主机转发进来的流量进不去。

---

## 面试题

**1. `-p 8087:80` 里，8087 在宿主机还是容器？**

8087 在宿主机，80 在容器。容器只监听 80，8087 在容器内部根本不存在。

**2. 容器里的 `localhost` 指谁？**

容器自己。每个容器有独立网络命名空间，`localhost` 是它自己的 loopback，不是宿主机。

**3. 为什么默认网络不能用容器名访问，自定义网络就行？**

默认 bridge 只做转发，没有内嵌 DNS；自定义网络内置 DNS 服务（aardvark-dns，跑在网络网关地址上），容器名可直接解析。

**4. 应用容器化后连不上数据库，配置写的是 `localhost:3306`，问题在哪？**

`localhost` 指向容器自己，容器里没有 MySQL。改成容器名（同网络）或宿主机 IP。

---

## 一句话总结

> 容器有自己的一套网络。**它的 `localhost` 是它自己。**
> 想让它找到别人，要么给 IP，要么给它一个带 DNS 的网络。
