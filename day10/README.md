# 第 10 课 · 探针、ConfigMap、Ingress（附一场 502 排查实录）

> 本文是《从零学云原生》系列第 10 篇。
> 环境：RHEL 10 + k3s v1.36.5 + Traefik 3.7.13

**日期**：2026-11-08 ｜ **耗时**：约 4 小时（大半时间在排障）

---

## 引子：上次的"零中断"其实有运气成分

第 9 课做滚动更新，120 次请求全部 200。

但那次能成功，有个隐藏条件：**nginx 启动只要 1 秒**。

**换成启动要 30 秒的 Java 应用呢？**

```
Pod 状态变 Running  →  K8s 认为它可以接流量  →  塞请求进去
                       ↑
                  但应用还没初始化完
                       ↓
                   502 / 连接拒绝
```

**"进程存在" ≠ "能提供服务"。**

这就是探针要解决的问题。

---

## 一、三种探针

| 探针 | 问什么 | 失败会怎样 |
|---|---|---|
| **livenessProbe** | 你还活着吗 | **重启容器** |
| **readinessProbe** | 你能接流量吗 | **从 Service 摘除**（不重启） |
| **startupProbe** | 你启动完了吗 | 慢启动应用用，期间不执行上面两个 |

**一句话区分：**

```
liveness 失败  →  杀掉重来
readiness 失败 →  先别给它发流量，但别杀它
```

**为什么两个都要？**

- 只有 liveness：应用卡住 → 重启 → 但重启很慢 → 用户等
- 只有 readiness：应用卡住 → 摘除 → 但永远不恢复

**两个配合**：先摘流量（保护用户），再考虑重启（保护服务）。

---

## 二、实验：让一个 Pod "活着但不能服务"

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: probe-demo
  template:
    metadata:
      labels:
        app: probe-demo
    spec:
      containers:
        - name: nginx
          image: docker.m.daocloud.io/library/nginx:alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 3
```

**正常状态下：`READY 1/1`。**

**把 `path: /` 改成 `path: /notexist`，再 apply：**

```bash
kubectl get pods
```

```text
NAME                          READY   STATUS
probe-demo-5c64ff8d8f-9r4hk   0/1     Running     ← 新版本
probe-demo-84dfbc5f9c-5bskr   1/1     Running     ← 旧版本
probe-demo-84dfbc5f9c-gp4v9   1/1     Running     ← 旧版本
```

### 这个状态是本节的核心

**`READY 0/1` + `STATUS Running`**

| 列 | 值 | 含义 |
|---|---|---|
| STATUS | **Running** | 进程活着，没崩 |
| READY | **0/1** | **但不接流量** |

**而且注意：新旧两个 ReplicaSet 并存。**

```
probe-demo-84dfbc5f9c   2/2   ← 旧的，健康
probe-demo-5c64ff8d8f   1/1   ← 新的，卡住
```

**滚动更新自动停住了。**

### 这件事的价值

**没有 readinessProbe：**

```
新版本起来了 → K8s 认为可以接流量 → 塞请求 → 应用还没初始化
→ 502 → 用户投诉 → 半夜爬起来回滚
```

**有 readinessProbe：**

```
新版本起来了 → 探针不通 → 不塞流量，也不杀它
→ 旧版本继续服务 → 你慢慢排查
```

> **这就是"零中断部署"的真正含义**——不是换得快，是**换得不对时能停住**。

---

## 三、endpoints：Service 只认这个

```bash
kubectl get endpoints probe-demo
```

```text
NAME          ENDPOINTS
probe-demo    10.42.1.4:80,10.42.1.5:80
```

**Pod 有 3 个，endpoints 只有 2 个。**

**那个 `0/1` 的 Pod，被完完全全排除在流量之外。**

> **Service 转发的真相**：它不看 Deployment 有几个 Pod，**只看 endpoints 列表里有谁。**

修好探针（`path: /`）后，滚动继续完成，endpoints 回到 2 个（因为 `replicas: 2`，旧的删了）。

---

## 四、ConfigMap：key 就是文件名

### 为什么需要

`index.html` 写死在镜像里。**改一行字，要走完整的 构建 → 推镜像 → 滚动更新 流程。**

ConfigMap 把配置从镜像里拿出来：

```
镜像  = 不变的（代码、运行时）
配置  = 可变的（环境变量、配置文件、端口、密码）
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
data:
  index.html: |
    <html>
    <head><meta charset="utf-8"></head>
    <body>
      <h1>这个页面来自 ConfigMap</h1>
    </body>
    </html>
```

### 关键：key 名 = 挂载后的文件名

**这是最容易踩的坑。**

我最开始把 key 写成 `INDEX_TEXT`，挂载后容器里就出现一个叫 `INDEX_TEXT` 的文件——**nginx 根本不认识它**。

要覆盖 `index.html`，**key 就必须叫 `index.html`**。

### 挂进 Pod

```yaml
spec:
  template:
    spec:
      volumes:
        - name: html
          configMap:
            name: web-config
      containers:
        - name: nginx
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
```

**层级要看清：**

```
spec.template.spec
├── volumes            ← 和 containers 同级
└── containers
    └── volumeMounts   ← 在 container 里面
```

### 验证

```bash
curl http://localhost:<NodePort>
```

```html
<h1>这个页面来自 ConfigMap</h1>
```

**这个页面不在镜像里。** 而且**挂载会遮盖镜像里原来的 `index.html`**（第 2 课学过的"遮盖"）。

### 改内容，不重建镜像

```bash
# 改 configmap.yaml 里的文字
kubectl apply -f configmap.yaml
# 等 60—90 秒（ConfigMap 同步到容器有延迟）
curl http://localhost:<NodePort>
```

**页面变了，Pod 的 AGE 一点没增加——没有重启。**

| | 改镜像里的文件 | 改 ConfigMap |
|---|---|---|
| 要 build | ✅ | ❌ |
| 要推镜像 | ✅ | ❌ |
| 要重启 Pod | ✅ | **❌（挂载方式自动同步）** |
| 耗时 | 5—10 分钟 | **90 秒** |

---

## 五、Ingress：一个入口，多个服务

### NodePort 的问题

```bash
kubectl get svc
```

```text
NAME           TYPE       PORT(S)
nginx-svc      NodePort   80:31755/TCP
probe-demo     NodePort   80:31285/TCP
```

| 问题 | 后果 |
|---|---|
| 端口 30000—32767 随机 | 用户记不住 |
| 每个服务一个端口 | 10 个服务 = 10 个端口 |
| 端口重建会变 | 实际从 32753 → 31755 → 31285 变过 |
| 没有域名 | 只能 IP 访问 |

**生产环境根本没法用。**

### 第 6 课是怎么解决的

手写 nginx：

```nginx
upstream backend { server app1:80; server app2:80; }
server { listen 80; location / { proxy_pass http://backend; } }
```

**一个 80 端口当入口，往后转发。**

**Ingress 就是把这个做法标准化了。**

### 写 Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
spec:
  rules:
    - host: app1.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-svc
                port:
                  number: 80

    - host: app2.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: probe-demo
                port:
                  number: 80
```

```bash
kubectl apply -f ingress.yaml
kubectl get ingress
```

```text
NAME           CLASS     HOSTS                   ADDRESS          PORTS
demo-ingress   traefik   app1.local,app2.local   192.168.191.129  80
```

**`CLASS: traefik`** —— k3s 自带的 Ingress Controller 接管了。

### 验证：同一个 80 端口，两个不同页面

```bash
curl -H "Host: app1.local" http://localhost/
```

```html
<h1>Welcome to nginx!</h1>
```

```bash
curl -H "Host: app2.local" http://localhost/
```

```html
<h1>这个页面来自 ConfigMap</h1>
```

**`-H "Host: xxx"` 就是模拟浏览器访问 `http://app1.local/` 时发出的请求头。**

### 和 nginx upstream 的对比

| | 第 6 课 | Ingress |
|---|---|---|
| 改配置 | 编辑 nginx.conf → reload | **改 YAML → apply** |
| 服务发现 | 手写 `server app1:80` | **自动对接 Service** |
| 多个服务 | 手写多个 location | **加一条 rule** |
| 端口 | 一个 nginx 占一个端口 | **所有服务共用 80** |

---

## 六、⭐ 一场 502 排查实录（本课精华）

**Ingress 建好了，`describe` 显示后端 IP 全都对，但 `curl` 返回：**

```
HTTP/1.1 502 Bad Gateway
```

### 我的排查过程

**① 先看 Ingress 详情**

```bash
kubectl describe ingress demo-ingress
```

```text
Rules:
  Host        Path  Backends
  app1.local  /     nginx-svc:80 (10.42.1.254:80,10.42.1.2:80,10.42.1.3:80)
  app2.local  /     probe-demo:80 (10.42.1.8:80,10.42.1.9:80)
```

**后端 IP 全都有** → 排除 Service 层。

**② 集群内部能不能访问 Service**

```bash
kubectl run nettest --rm -it --restart=Never \
  --image=docker.m.daocloud.io/library/busybox -- wget -qO- http://nginx-svc
```

**返回 nginx 欢迎页** → 排除 DNS、Pod 网络、Service。

**③ Traefik 自己有后端吗**

```bash
kubectl get endpoints -n kube-system traefik
```

```text
traefik   10.42.1.232:8443,10.42.1.232:8000
```

**有** → 排除 k3s 负载均衡组件（svclb）空转。

**④ 绕过 svclb，直接打 Traefik 的 pod**

```bash
curl -i -H "Host: app1.local" http://10.42.1.232:8000/
```

**还是 502** → 锁定问题在 Traefik。

**⑤ 进 Traefik 容器，往外打**

```bash
kubectl exec -n kube-system deploy/traefik -- wget -qO- http://10.42.1.2:80
```

```text
wget: can't connect to remote host (10.42.1.2): Host is unreachable
```

**`Host is unreachable`** —— 这是网络层里最底层的一种错误。

**三种连接错误的区别：**

| 报错 | 含义 |
|---|---|
| `Connection refused` | 端口没人听（**能到主机**） |
| `Connection timed out` | 包被丢了（不知道主机在不在） |
| **`Host is unreachable`** | **本机路由不知道往哪发** |

**⑥ 但 Traefik 的路由表看起来是正常的**

```bash
kubectl exec -n kube-system deploy/traefik -- ip route
```

```text
default via 10.42.1.1 dev eth0
10.42.0.0/16 via 10.42.1.1 dev eth0
10.42.1.0/24 dev eth0 scope link src 10.42.1.11
```

**路由有、网段对、同网段直连**——理论上不该 unreachable。

**⑦ 反方向测试：别的 pod 能不能访问 Traefik**

```bash
kubectl run t2 --rm -it --restart=Never \
  --image=docker.m.daocloud.io/library/busybox -- wget -qO- http://10.42.1.11:8000
```

```text
wget: can't connect to remote host (10.42.1.11): No route to host
```

**也不通。** 所以：**pod 到 pod 全都不通，但宿主机到 pod 是通的。**

**⑧ 这个组合指向一个非常具体的原因**

```bash
curl -i http://10.42.1.11:8000/     # 从宿主机
```

```text
HTTP/1.1 404 Not Found              ← Traefik 活着！
```

**宿主机能到 Traefik，pod 之间不能。**

> **在 Linux 上，pod 之间的流量走网桥转发，会经过 `iptables` 的 FORWARD 链。**
> **而宿主机访问 pod 是"本地流量"，走 INPUT/OUTPUT，不经过 FORWARD。**

**所以：FORWARD 被拦了。**

**⑨ 验证**

```bash
systemctl stop firewalld
kubectl exec -n kube-system deploy/traefik -- wget -qO- --timeout=3 http://10.42.1.2:80
```

```html
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title></head>
```

**立刻通了。**

**根因：firewalld。**

---

## 七、一个反直觉的细节：`policy ACCEPT` 也会被拦

排查时我看了 iptables：

```bash
iptables -L FORWARD -n
```

```text
Chain FORWARD (policy ACCEPT)
1  KUBE-ROUTER-FORWARD
2  KUBE-PROXY-FIREWALL
3  KUBE-FORWARD
4  KUBE-SERVICES
5  KUBE-EXTERNAL-SERVICES
6  ACCEPT  /* network policy */
7  FLANNEL-FWD
```

**`policy ACCEPT`**——策略是接受啊，怎么还被拦？

### 答案：你看的不是生效的那一层

**从 RHEL 8 开始，firewalld 默认用 nftables 后端。**

`iptables -L` 显示的是兼容层视图——**它显示的是 k3s 铺的链，看不到 firewalld 真正的规则。**

真实规则在 nft 里，而且**插在更前面**：

```bash
nft list ruleset | grep -B2 -A8 "hook forward"
```

**firewalld 在 `forward` hook 上加了规则，包在到达 iptables 的 FORWARD 链之前就被 DROP 了。**

> **`policy ACCEPT` 是"最后一道门敞开"，但前面三道门都锁着。**
> **永远轮不到它。**

---

## 八、根因分析：两个组件的设计理念冲突

| 组件 | 它的原则 |
|---|---|
| **firewalld** | 默认**拒绝所有转发**，只放行明确允许的 |
| **k3s（flannel）** | 必须**大量 pod 间转发** |

**一个说"都别过"，一个说"必须都过"。**

**这不是配置错误，是设计理念冲突。**

k3s 官方文档也明确写着：**用 firewalld 就必须关掉，或者专门配置放行。**

### 三种解法

**① 直接禁用（学习环境推荐）**

```bash
systemctl disable --now firewalld
```

**② 给容器网络放行（保留 firewalld）**

```bash
firewall-cmd --permanent --zone=trusted --add-interface=cni0
firewall-cmd --permanent --zone=trusted --add-interface=flannel.1
firewall-cmd --permanent --add-masquerade
firewall-cmd --reload
```

**③ 生产环境的做法**

- 关掉 firewalld，用**云安全组**或 **K8s NetworkPolicy** 做隔离
- 或者用专门的网络插件管理

> **一个讽刺的巧合**：我机构课上学 firewalld 学得很认真（它是考点），
> 结果现在为了跑 k3s，必须把它关掉。
>
> **这不是谁错了**——是它们服务于不同场景。

---

## 九、今天踩的坑

| # | 坑 | 报错看起来像 | 实际是 |
|---|---|---|---|
| 1 | 文件名 `prode.yml`（应为 `probe.yml`） | 文件找不到 | 拼写 |
| 2 | 目录名 `k8s-prode`（应为 `k8s-probe`） | 路径不存在 | 拼写 |
| 3 | 命令里 `prode-demo` | deployment not found | 拼写 |
| 4 | ConfigMap 的 key 写了 `INDEX_TEXT` | 页面 404 | key 名不是文件名 |
| 5 | `-H"Host:..."http://` 少了空格 | `no URL specified` | 空格 |
| 6 | **firewalld 拦截 pod 间转发** | **502 Bad Gateway** | **FORWARD 被 nft 规则拦** |
| 7 | `iptables -L FORWARD` 显示 ACCEPT | 误以为没被拦 | firewalld 用 nftables |

**前 5 个是手误，第 6、7 个是真正的技术坑。**

---

## 十、面试题

**1. readinessProbe 和 livenessProbe 的区别？**

liveness 失败会重启容器（判断"还活着吗"）；readiness 失败只是把 Pod 从 Service 的 endpoints 里摘除（判断"能接流量吗"），不重启。

**2. 为什么 `READY 0/1` 但 `STATUS Running`？**

Running 说明进程在跑；READY 说明 readinessProbe 通过。两者是不同的判断。

**3. ConfigMap 的 key 和挂载后的文件名是什么关系？**

key 就是文件名。key 叫 `index.html`，容器里就出现 `index.html`；key 叫 `INDEX_TEXT`，就出现一个叫 `INDEX_TEXT` 的文件。

**4. Ingress 和 Service 的区别？**

Service 是四层（IP + 端口）的稳定入口；Ingress 是七层（HTTP Host / Path）路由，一个入口可以按域名或路径分发到多个 Service。

**5. 为什么 firewalld 会拦 pod 间通信，但拦不住宿主机访问 pod？**

pod 间流量走网桥转发，经过 iptables/nftables 的 FORWARD 链；宿主机访问 pod 是本地流量，走 INPUT/OUTPUT，不经过 FORWARD。

---

## 十一、一句话总结

> **探针解决"能不能接流量"，ConfigMap 解决"配置放在哪"，Ingress 解决"入口有几个"。**
>
> 而今天真正学到的，是**如何从 502 一路查到 firewalld**——
> **每一步缩小范围，每一步都有证据，不猜。**
