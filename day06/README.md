# 第 06 课 · 项目 A：nginx 反向代理 + 负载均衡

> 本文是《从零学云原生》系列第 6 篇。
> 环境：RHEL 10 + podman 5.8.2 + podman-compose 1.6.0

**日期**：2026-11-02 ｜ **耗时**：约 2 小时

---

## 为什么做这个，而不是 LNMP

课表上第 6 课原本写的是"把机构课的 LNMP 用 compose 重做一遍"。

但我换了，两个原因：

1. **成本**：MySQL 镜像约 600MB，php-fpm 约 100MB，光等下载就要很久
2. **价值**：LNMP 只是"把手工步骤搬进 compose"，架构上没什么可讲的

改成这个架构：

```
                 ┌──> app1（页面 A）
用户 → proxy ────┤
      (nginx)    └──> app2（页面 B）
```

零额外下载（nginx 本地已有），但包含了真实生产架构的三个核心：

| 概念 | 含义 |
|---|---|
| **反向代理** | 用户只看到统一入口，不知道后面有几台 |
| **负载均衡** | 请求轮流分配到多个后端 |
| **故障转移** | 一个后端挂了，流量自动切走，用户无感 |

**这是"高可用"的最小模型。**

---

## 一、两个文件，两层职责

这一课最重要的认知：**编排和配置是两件事。**

```
docker-compose.yml        ← 编排层：有几个容器、怎么连、挂什么
      ↓ podman-compose 读它
   起三个容器
      ↓ 其中 proxy 容器启动时，nginx 读自己的配置
proxy/nginx.conf          ← 应用层：nginx 怎么转发、转给谁
```

| 文件 | 回答什么问题 | 谁读它 |
|---|---|---|
| `docker-compose.yml` | 这套系统由哪些容器组成 | `podman-compose` |
| `proxy/nginx.conf` | nginx 怎么工作 | `nginx` 进程 |

**compose 文件里一个字都没提"代理"和"负载均衡"**，它只说了"把这份配置挂进容器"。

---

## 二、`nginx.conf`

```nginx
events {}

http {
    upstream backend {
        server app1:80;
        server app2:80;
    }

    server {
        listen 80;

        location / {
            proxy_pass http://backend;
        }
    }
}
```

**关键点：`server app1:80;` 里写的是服务名。**

nginx 启动时要去解析 `app1` 这个名字——能解析成功，靠的是 compose 网络的内置 DNS（第 4、5 课学的）。

写成容器名（`p_app1`）大概率解析不了。**DNS 认的是服务名。**

---

## 三、`docker-compose.yml`

```yaml
version: "3"

services:
  proxy:
    image: docker.m.daocloud.io/library/nginx
    container_name: p_proxy
    ports:
      - "8091:80"
    volumes:
      - ./proxy/nginx.conf:/etc/nginx/nginx.conf:Z
    depends_on:
      - app1
      - app2
    networks:
      - appnet

  app1:
    image: docker.m.daocloud.io/library/nginx
    container_name: p_app1
    volumes:
      - ./app1:/usr/share/nginx/html:Z
    networks:
      - appnet

  app2:
    image: docker.m.daocloud.io/library/nginx
    container_name: p_app2
    volumes:
      - ./app2:/usr/share/nginx/html:Z
    networks:
      - appnet

networks:
  appnet:
    driver: bridge
```

**注意：`app1`、`app2` 没有 `ports`。**

只有 `proxy` 对外暴露。后端藏在内部网络里，**减少攻击面**——这是真实生产的安全实践。

---

## 四、三个验证

### ① 能访问

```bash
curl http://localhost:8091
```

### ② 负载均衡生效

```bash
for i in {1..6}; do curl -s http://localhost:8091 | grep -o '我是 [AB] 服务器'; done
```

```text
我是B服务器
我是A服务器
我是B服务器
我是A服务器
我是B服务器
我是A服务器
```

**完美交替**——nginx 默认的轮询策略。

### ③ 故障转移

```bash
podman stop p_app1
```

再请求，**全部返回 B，没有报错**。

因为 nginx 的 `proxy_next_upstream` 默认会在连接失败时自动重试下一台后端。**用户完全无感。**

**这就是故障转移。**

---

## 五、一次真实的故障复盘（本课精华）

故障转移验证完之后，我把 app1 启动回来，结果——**A 一直不出现。**

### 第一次尝试：等 10 秒

我知道 nginx 有"失败摘除"机制：

```nginx
server app1:80;    # 默认 max_fails=1, fail_timeout=10s
```

含义：连续失败 1 次就标记不可用，**摘除 10 秒**，之后才重新尝试。

所以我等了 15 秒再请求——**还是全 B。**

### 第二次尝试：重启 app1

```bash
podman start p_app1
```

再请求——**还是全 B。**

### 第三次：看了日志（这是转机）

前面几轮我都在"试"，一次都没"看"。打开 nginx 日志：

```bash
podman logs p_proxy --tail 20
```

```text
[error] 24#24: *36 connect() failed (113: No route to host)
        while connecting to upstream,
        client: 10.89.3.1,
        request: "GET / HTTP/1.1",
        upstream: "http://10.89.3.2:80",
        host: "localhost:8091"
```

**三个关键信息：**

1. `upstream: "http://10.89.3.2:80"` —— nginx 正在往 **10.89.3.2** 发请求
2. `113: No route to host` —— 这个 IP **现在没有任何主机**
3. 同一时间其他请求返回 `200` —— 那些走的是 app2

**nginx 记住了一个已经不存在的 IP。**

### 根因

> **nginx 在启动时把 `app1` 解析成 IP 并缓存进内存，之后不再重新解析。**

时间线：

```
nginx 启动 → 查 DNS：app1 是谁？→ 10.89.3.2 → 存进内存
app1 被 stop    → IP 释放
app1 被 start   → 拿到新 IP
nginx 不知情    → 继续往 10.89.3.2 发请求 → No route to host
                 → 失败 → 标记摘除 → 10 秒后重试 → 还是旧 IP → 再摘除
```

**所以永远轮不到 A。**

### 修复

```bash
podman restart p_proxy
```

```bash
for i in {1..6}; do curl -s http://localhost:8091 | grep -o '我是 [AB] 服务器'; done
```

**A 回来了。**

因为重启让 nginx **重新读配置、重新解析域名、清空失败记录**。

> **重启不是"修复"，是"重新开始算一遍"。**

### 治本的方法

**① nginx 动态解析（变量写法）**

```nginx
resolver 10.89.0.1 valid=10s;

set $backend "http://app1:80";
proxy_pass $backend;
```

用了变量，nginx 才会按 `valid=10s` 定期重新解析。

**② 用服务发现**

Consul、etcd、**Kubernetes Service**——自动跟踪后端变化，不用你重启任何东西。

> 这就是为什么 K8s 里你不需要手动维护 upstream 列表。

---

## 六、顺带纠正的三个概念

### 1. `stop` ≠ `rm`

| 操作 | 容器本身 | 数据 | IP |
|---|---|---|---|
| `podman stop` | 还在 | **还在** | 释放 |
| `podman start` | 恢复 | **还在** | 重新分配（可能变） |
| `podman rm` | 没了 | **没了** | 没了 |

**停止只是暂停进程，容器和可写层完整留在磁盘上。** 只有 `rm` 才真正销毁。

所以 app1 停止期间，它的 `index.html` 一直躺在磁盘上——`start` 之后立刻就能读到。

### 2. 服务名 ≠ 容器名

```yaml
services:
  app1:                      # 服务名 → DNS 认它
    container_name: p_app1   # 容器名 → 你 podman 命令时用
```

nginx 配置必须写**服务名**。

**为什么？** 因为一个服务可以有多个副本，共享同一个名字。后端扩到 3 个，nginx 配置一个字都不用改。

### 3. `podman inspect` 取 IP 的正确写法

```bash
# 旧的，在 podman 5.x 返回空字符串（不报错，但没数据）
podman inspect p_app1 --format '{{.NetworkSettings.IPAddress}}'

# 正确的
podman inspect p_app1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

**"命令没报错但没输出"，最容易骗人。**

---

## 七、简历可以这么写

> **nginx 反向代理 + 多实例负载均衡（Docker Compose）**
> 用 Docker Compose 编排 nginx 反向代理与双实例后端，实现轮询负载均衡与故障自动转移；后端容器不对外暴露端口，仅通过内部网络被代理访问；配置与静态资源通过挂载注入，更新无需重建镜像。
> 验证：单实例宕机时请求自动切换至可用实例，服务不中断。

**这段的含金量在于：**

- 有**架构**（代理 + 多实例）
- 有**可用性设计**（故障转移）
- 有**安全考虑**（后端不暴露）
- 有**验证手段**（停一个，看流量）
- 有**排障经历**（缓存 IP 事故）

**面试官想听的不是"我会 Docker"，是"我理解为什么这么设计，以及出问题时怎么查"。**

---

## 八、面试题

**1. 为什么 `app1`、`app2` 不写 `ports`？**

只有入口需要对外暴露，后端藏在内部网络减少攻击面。这是生产环境的标准做法。

**2. nginx 配置里为什么能直接写容器名/服务名？**

同一 compose 网络有内置 DNS，服务名可解析成 IP。

**3. 停掉一个后端，用户为什么没看到报错？**

`proxy_next_upstream` 默认在连接失败时重试下一台后端。

**4. 后端重启后为什么流量没马上回来？**

`max_fails` / `fail_timeout` 机制会摘除一段时间；且 nginx 只在启动时解析 upstream 域名，**IP 变了不会自动更新**，需要重启或使用动态解析。

**5. `upstream` 默认的负载均衡策略？**

轮询（round-robin）。

---

## 九、一句话总结

> **编排和配置是两层：compose 管"有哪些容器"，nginx.conf 管"怎么转发"。**
> 而 nginx 只在启动时解析一次名字——**名字背后的 IP 变了，它会一直打在空气上。**
