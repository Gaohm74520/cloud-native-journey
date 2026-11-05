# 第 09 课 · Kubernetes 入门：Pod / Deployment / Service

> 本文是《从零学云原生》系列第 9 篇。
> 环境：RHEL 10 + k3s v1.36.5

**日期**：2026-11-05 ｜ **耗时**：约 2.5 小时

---

## 引子：从 podman 到 kubectl

前八课，我用的是 `podman`：

```bash
podman run -d --name web -p 8080:80 镜像
```

**一台机器、一个容器、手动起停。**

但真实场景是这样的：

- 一台机器不够用了怎么办？
- 容器半夜挂了，谁去重启？
- 要升级版本，能不能不停机？

**这三个问题，podman 都答不上来。**

K8s 答得上。这一课装它，然后跑通最核心的三个对象。

---

## 一、装 k3s

k3s 是轻量版 K8s，一条命令装完，内存占用只有标准 K8s 的 1/3。

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_MIRROR=cn sh -
```

**`INSTALL_K3S_MIRROR=cn` 让安装脚本走国内镜像**，不然那个 70MB 的二进制会等到怀疑人生。

```bash
systemctl is-active k3s
kubectl get nodes
```

```text
NAME       STATUS   ROLES           AGE   VERSION
k3s-node1  Ready    control-plane   30s   v1.36.5+k3s1
```

`Ready` 就成了。

> **注意**：如果你改了 hostname（`hostnamectl set-hostname`）再重启 k3s，**旧名字的 Node 对象会留在集群里，状态变成 NotReady**。
> 因为 K8s 只会按声明做事，不会自动清理历史。要手动删：
>
> ```bash
> kubectl delete node localhost.localdomain
> ```

---

## 二、第一个坑：镜像拉不下来

装好 k3s 后起 Pod，报错：

```text
Failed to pull image "rancher/mirrored-pause:3.10.2":
dial tcp 3.113.87.34:443: connect: connection refused
```

**k3s 内置的 containerd 在拉 docker.io，被墙了。**

节点能 `Ready`，是因为它不需要拉镜像；**一跑 Pod 就露馅。**

### 解法：给 containerd 配镜像加速

```bash
mkdir -p /etc/rancher/k3s
vi /etc/rancher/k3s/registries.yaml
```

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
```

```bash
systemctl restart k3s
```

**这和第 1 课给 podman 配镜像源是同一件事，只是配置文件不同：**

| 工具 | 配置文件 |
|---|---|
| podman | `/etc/containers/registries.conf.d/` |
| k3s（containerd） | `/etc/rancher/k3s/registries.yaml` |
| Docker | `/etc/docker/daemon.json` |

**同一件事，四套配置。** 国内做容器，这一关谁都躲不掉。

---

## 三、第二个坑：一个字母，报错完全变了样

配好镜像后，再起 Pod：

```bash
kubectl run nginx-pod --image=docekr.m.daocloud.io/library/nginx
```

> **看清楚：`docekr`，e 和 k 反了。**

`kubectl get pods` 显示 `ErrImagePull`，`describe` 里是：

```text
failed to pull and unpack image "docekr.m.daocloud.io/library/nginx:latest":
failed commit on ref "unknown-sha256:9dc168b87f40...":
failed size validation: 288072 != 287992: failed precondition
```

**`failed size validation`** —— 字节数对不上。

看起来像"镜像代理和 containerd 协议不兼容"，**实际是域名拼错了**。

`docekr.m.daocloud.io` 这个域名不存在，DNS 泛解析返回了某个 CDN 的错误页，containerd 当成 registry 响应去解析，字节数当然对不上。

改回 `docker`：

```bash
kubectl delete pod nginx-pod
kubectl run nginx-pod --image=docker.m.daocloud.io/library/nginx
```

```text
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          52s
```

**Running。**

### 这个坑的教训

**报错的"表层原因"会骗人。**

| 你看到的 | 你以为 | 实际 |
|---|---|---|
| `failed size validation` | 镜像代理不兼容 | 域名拼错了 |
| `Could not resolve host` | 网络问题 | 主机名拼错了 |
| YAML 满屏红线 | 语法太复杂 | 冒号后少个空格 |

**所以排障顺序应该是：**

```
① 拼写 / 路径 / 文件名      ← 最容易错，最容易忽略
② 权限 / 所有权
③ 网络 / 端口
④ 协议 / 版本兼容          ← 最后才怀疑这里
```

**大多数人反过来**——一上来怀疑"版本不兼容"，折腾两小时才发现是拼写。

---

## 四、Pod：最小单位

```bash
kubectl run nginx-pod --image=docker.m.daocloud.io/library/nginx
kubectl get pods
```

### 四个必须会的动词

| 命令 | 作用 | 对应 podman |
|---|---|---|
| `kubectl get` | 列表 | `podman ps` |
| `kubectl describe` | 详情 + **事件** | `podman inspect` |
| `kubectl logs` | 日志 | `podman logs` |
| `kubectl delete` | 删除 | `podman rm` |

**`describe` 最重要**——Pod 起不来时，答案八成在它最后那几行 `Events` 里。

### Pod 能直接访问吗

**不能。**

```bash
kubectl get pods -o wide
```

```text
NAME        READY   STATUS    IP           NODE
nginx-pod   1/1     Running   10.42.0.8    k3s-node1
```

`10.42.0.8` 是**集群内部**地址，外面访问不到。

> **这和 Docker 不一样。** Docker 用 `-p 8080:80` 一句话就映射出来了。
> K8s 要让外部访问，得用 **Service**。

**这不是麻烦，是故意的**：Pod 天天被销毁重建，IP 一直在变，**不能让它直接对外**。

---

## 五、Deployment：一个永远在跑的循环

### 裸 Pod 死了就死了

```bash
kubectl delete pod nginx-pod
```

**删了就没了，不会自己回来。**

因为 `kubectl run` 起的是**裸 Pod**，没有任何东西管它。

### Deployment：声明"我要几个"

```bash
kubectl create deployment nginx-deploy \
  --image=docker.m.daocloud.io/library/nginx --replicas=3
```

```bash
kubectl get pods
```

```
nginx-deploy-57fc977bc-b59pd   1/1   Running
nginx-deploy-57fc977bc-lcltr   1/1   Running
nginx-deploy-57fc977bc-zdqbk   1/1   Running
```

3 个副本。注意名字后面的随机串——**Pod 的名字是自动生成的，因为它是消耗品**。

### ⭐ 删一个，看它自己回来

```bash
kubectl delete pod nginx-deploy-57fc977bc-lcltr
kubectl get pods
```

```text
nginx-deploy-57fc977bc-7pdbn   1/1   Running   17s   ← 新的
nginx-deploy-57fc977bc-b59pd   1/1   Running   99s
nginx-deploy-57fc977bc-zdqbk   1/1   Running   99s
```

**删掉的是 `lcltr`，回来的是 `7pdbn`——一个全新的 Pod。**

而且 **AGE 只有 17 秒，另外两个是 99 秒**。这个时间差就是证据。

### 谁在补

```bash
kubectl get rs
```

```text
NAME                      DESIRED   CURRENT   READY
nginx-deploy-57fc977bc    3         3         3
```

`DESIRED 3 / CURRENT 3` —— **期望状态和实际状态**。

```
        ┌─────────────────────────────┐
        │  我想要 3 个（DESIRED）      │
        └──────────────┬──────────────┘
                       ↓
        ┌─────────────────────────────┐
        │  现在有几个？（CURRENT）      │
        └──────────────┬──────────────┘
              3 > 2？那就删
              3 < 2？那就建
              3 = 3？什么都不做
                       ↓（每秒重复）
```

这叫 **control loop（控制循环）**。

**你删 Pod 的那一刻，CURRENT 变成 2，循环发现差异，立刻建了一个新的。**

> 这就是 K8s 能扛住"半夜一台机器挂了"的原因——**它的循环一夜没停。**

---

## 六、Service：因为 IP 会变

### 先看一个事实

```bash
kubectl get pods -o wide
```

记下三个 IP。

**删一个，再看：**

```bash
kubectl delete pod <挑一个>
kubectl get pods -o wide
```

| | 删之前 | 删之后 |
|---|---|---|
| Pod 名 | `7pdbn` | **`xnpq4`** |
| IP | `10.42.1.238` | **`10.42.1.239`** |

**Pod 换了，名字换了，IP 也换了。**

外部程序如果直连这个 IP，**下次就断了**。

### Service 做三件事

| 作用 | 说明 |
|---|---|
| **稳定地址** | 给一个 ClusterIP，Pod 换一百次它不变 |
| **稳定名字** | 集群内可以直接用服务名访问 |
| **负载均衡** | 请求分给后面所有健康的 Pod |

```bash
kubectl expose deployment nginx-deploy --type=NodePort --port=80
kubectl get svc
```

```text
NAME           TYPE       CLUSTER-IP     PORT(S)        AGE
nginx-deploy   NodePort   10.43.98.158   80:32753/TCP   3s
```

| 字段 | 含义 |
|---|---|
| `CLUSTER-IP` | 集群内部稳定地址 |
| `80` | 集群内部访问端口 |
| **`32753`** | **NodePort，外部访问端口**（30000—32767） |

### 从外面访问

Windows 浏览器打开：

```
http://192.168.191.129:32753
```

**看到 nginx 欢迎页。**

### 验证负载均衡

```bash
for i in {1..9}; do curl -s http://localhost:32753 > /dev/null; done
kubectl logs -l app=nginx-deploy --prefix --tail=9
```

`--prefix` 会标出每条日志来自哪个 Pod：

```text
[pod/nginx-deploy-...-b59pd/nginx] "GET / HTTP/1.1" 200
[pod/nginx-deploy-...-xnpq4/nginx] "GET / HTTP/1.1" 200
[pod/nginx-deploy-...-zdqbk/nginx] "GET / HTTP/1.1" 200
```

**9 个请求均分到 3 个 Pod。**

### 三层结构

```
外部用户
   ↓ NodePort 32753
┌─────────────────┐
│  Service        │  ← 稳定入口
└────────┬────────┘
         ↓ 轮询
   ┌─────┼─────┐
   ↓     ↓     ↓
 Pod1  Pod2  Pod3     ← 一次性的，随时被替换
   ↑
   └── Deployment 保证"永远是 3 个"
```

---

## 七、从命令行到 YAML

### 为什么

那三条命令现在在哪？

**在终端历史和记忆里。**

- 关掉终端 → 没了
- 换台电脑 → 重敲一遍
- 三个月后重建 → 记不清 `--replicas` 是几

| | 命令行 | YAML |
|---|---|---|
| 存在哪 | 终端历史 | **文件** |
| 能进 Git | ❌ | ✅ |
| 能 review | ❌ | ✅ |
| 能复现 | 靠记忆 | **一条 apply** |

### deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: docker.m.daocloud.io/library/nginx:latest
          ports:
            - containerPort: 80
```

| 字段 | 含义 |
|---|---|
| `apiVersion` / `kind` | 用哪个 API、创建什么对象 |
| `metadata.name` | 对象名字（相当于 `--name`） |
| `spec` | **期望状态** |
| `spec.replicas` | 副本数 |
| `spec.selector` | **选哪些 Pod 归我管**（靠标签） |
| `spec.template` | **Pod 长什么样** |

**最关键的一对**：`selector.matchLabels` 和 `template.metadata.labels` **必须对得上**，否则报 `selector does not match template labels`。

### service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-svc
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
```

**注意**：Deployment 和 Service **互不知晓**，它们只靠标签"隔空对接"。

> 这是 K8s 的设计精髓：**组件之间不直接引用，靠标签解耦。**

### 应用

```bash
kubectl apply -f .
```

### 验证幂等

把 `replicas: 3` 改成 `5`，再 apply：

```bash
kubectl apply -f deployment.yaml
kubectl get pods
```

**5 个。它只加了 2 个，另外 3 个原封不动。**

改回 3，再 apply，它自己删掉 2 个。

> **`apply` 不是"执行命令"，是"把实际状态对齐到文件描述的状态"。**

**所以可以反复 apply，永远不会出问题。**

预览变化：

```bash
kubectl diff -f deployment.yaml
```

---

## 八、滚动更新：零中断

### 实验设计

**先起一个探针**（后台每 0.5 秒请求一次，记录状态码）：

```bash
for i in {1..120}; do curl -s -o /dev/null -w "%{http_code}\n" \
  http://localhost:31755; sleep 0.5; done > /tmp/codes4.txt &
```

**立刻**改镜像（用 `kubectl set image`，比改文件快）：

```bash
kubectl set image deployment/nginx-deploy \
  nginx=docker.m.daocloud.io/library/nginx:alpine
```

```bash
kubectl rollout status deployment/nginx-deploy
```

### 结果

```text
deployment.apps/nginx-deploy image updated

Waiting for deployment "nginx-deploy" rollout to finish:
  1 old replicas are pending termination...
Waiting for deployment "nginx-deploy" rollout to finish:
  1 old replicas are pending termination...
deployment "nginx-deploy" successfully rolled out
```

```bash
sort /tmp/codes4.txt | uniq -c
```

```text
    120 200
```

**60 秒内 120 次请求，一次失败都没有。**

### 为什么不断

默认滚动策略：

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%          # 最多超出 25%
    maxUnavailable: 25%    # 最多不可用 25%
```

3 个副本时，**任何时刻都有 ≥2 个 Pod 在服务**，所以用户无感。

### 回滚

```bash
kubectl rollout undo deployment/nginx-deploy
kubectl rollout history deployment/nginx-deploy
```

**几十秒回滚**，因为旧的 ReplicaSet 还在（缩到 0，但没删）。

### 和传统部署对比

| | 传统 | K8s |
|---|---|---|
| 升级 | 停服务 → 换文件 → 启动 | **边换边服务** |
| 中断 | 几十秒到几分钟 | **0** |
| 回滚 | 找旧包重新部署 | `rollout undo` |
| 新版本坏了 | 服务直接挂 | **旧 Pod 还在，滚动自动停** |

**最后一行最值钱**：部署失败不会变成事故，**因为旧版本一直在服务**。

---

## 九、配置漂移：一个容易忽略的坑

`kubectl set image` 改了集群，**但没改文件**：

```bash
grep image: deployment.yaml                            # latest
kubectl get deploy -o jsonpath='{..image}'              # alpine
```

**文件和行为不一致了。**

下次谁再 `apply` 这个文件，**镜像会被打回 `latest`**——而且没人知道为什么。

> **铁律：文件是唯一真相。改配置只改文件，再 apply。**
> `kubectl set image` / `kubectl edit` 都是调试用的。

---

## 十、今天踩的 5 个坑

| # | 坑 | 报错看起来像 | 实际是 |
|---|---|---|---|
| 1 | containerd 拉不到 docker.io | 网络超时 | 没配 registries.yaml |
| 2 | 镜像名打成 `docekr` | **镜像协议不兼容** | 域名拼错 |
| 3 | `--type=ModePort` | 无效的类型 | 拼错（NodePort） |
| 4 | `localhost` 打成 `laocalhost` | 主机名解析失败 | 拼错 |
| 5 | `sed -i 's|nginx:alpine|'` | sed 语法错误 | 少写了原字符串 |

**2、3、4、5 全是拼写问题，但报错信息指向了完全不同的方向。**

### 两个立刻能用的解法

**① 开补全**

```bash
kubectl completion bash > /etc/bash_completion.d/kubectl
source /etc/bash_completion.d/kubectl
```

`kubectl expose ... --type=<Tab>` 会直接列出四个合法值。

**② `Ctrl+R` 搜历史**

不要把长命令重新打一遍。`Ctrl+R` 搜关键词，找到旧命令，改几个字符。

> **这两个设置省下的时间，比一条命令本身值钱得多。**

---

## 十一、面试题

**1. Pod 和容器的关系？**

Pod 是 K8s 的最小调度单位，可以包含一个或多个容器，**它们共享网络命名空间**（靠一个 `pause` 容器占住这个 namespace）。

**2. Deployment 保证了什么？**

通过 control loop 持续对比期望副本数和实际副本数，少了补、多了删。跨机器、自动重启、滚动更新。

**3. 为什么需要 Service？**

Pod 的 IP 随重建而变，不能对外暴露稳定地址。Service 提供固定的 ClusterIP 和名字，并把请求负载均衡到后端所有健康 Pod。

**4. `kubectl apply` 和 `kubectl create` 的区别？**

`create` 只能创建，对象已存在会报错；`apply` 是声明式，创建或更新，**可反复执行**（幂等）。

**5. 滚动更新为什么能不停机？**

`maxSurge` / `maxUnavailable` 控制替换节奏，任何时刻都有足够数量的 Pod 在服务。

---

## 十二、一句话总结

> **你不再"启动容器"，你"声明期望状态"，然后让一个循环来维持它。**
>
> 这个循环一秒没停——所以你删 Pod 它会补，机器挂了它会重建，升级时它能一边换一边服务。
