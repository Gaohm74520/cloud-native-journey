# 第 11 课 · 把第 6 课的项目搬上 K8s

> 本文是《从零学云原生》系列第 11 篇。
> 环境：RHEL 10 + k3s v1.36.5 + Traefik

**日期**：2026-11-09 ｜ **耗时**：约 3 小时

---

## 引子：同一个架构，两套实现

第 6 课我在 Docker 里搭过一个"反向代理 + 多后端"的架构：

```
                 ┌──> app1
用户 → proxy ────┤
      (nginx)    └──> app2
```

**当时我手写了这些：**

```nginx
upstream backend {
    server app1:80;
    server app2:80;
}
server {
    listen 80;
    location / { proxy_pass http://backend; }
}
```

**今天把它搬到 K8s，同样是这个架构，但我一个字都没写 nginx 配置。**

---

## 一、两个架构的对比

### Docker 版（第 6 课）

```
proxy（nginx 容器，手写 upstream）
  ├── app1
  └── app2
```

| 要素 | 怎么做的 |
|---|---|
| 反向代理 | 手写 `nginx.conf` |
| 负载均衡 | nginx 的 `upstream` 轮询 |
| 副本 | `podman run` 两次 |
| 配置 | 挂载 html 目录 |
| 健康检查 | 无 |
| 故障转移 | nginx 的 `proxy_next_upstream` |

### K8s 版（今天）

```
                 ┌──> Pod × 3
用户 → Ingress ──┤   （Deployment 管）
      (Traefik)  │
                 └──> Service（自动负载均衡）
```

| 要素 | 怎么做的 |
|---|---|
| 反向代理 | **Ingress，一条 rule** |
| 负载均衡 | **Service 自动** |
| 副本 | `replicas: 3` |
| 配置 | **ConfigMap** |
| 健康检查 | `readinessProbe` |
| 故障转移 | **K8s 摘除 + 重建** |

**注意：`proxy` 这个容器不见了。**

**因为 Ingress 就是那个 proxy。** 不用写 `nginx.conf`、不用 `upstream`、不用 reload。

---

## 二、三个 YAML 文件

```bash
mkdir -p /data/k8s-project && cd /data/k8s-project
```

### ① ConfigMap（页面内容）

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: webapp-html
data:
  index.html: |
    <html>
    <head><meta charset="utf-8"></head>
    <body>
      <h1>这是 K8s 版的反向代理项目</h1>
      <p>3 个副本，由 Service 负载均衡</p>
      <p>页面内容来自 ConfigMap</p>
    </body>
    </html>
```

### ② Deployment + Service（一个文件放两个对象）

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: web
          image: docker.m.daocloud.io/library/nginx:alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
      volumes:
        - name: html
          configMap:
            name: webapp-html

---
apiVersion: v1
kind: Service
metadata:
  name: webapp
spec:
  selector:
    app: webapp
  ports:
    - port: 80
      targetPort: 80
```

**`---` 是 YAML 的分隔符**，一个文件可以放多个对象。

### ③ Ingress（入口）

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webapp
spec:
  rules:
    - host: webapp.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: webapp
                port:
                  number: 80
```

### 部署

```bash
kubectl apply -f .
```

**一条命令，创建 4 个对象**（ConfigMap + Deployment + Service + Ingress）。

---

## 三、四个验证

### ① 域名访问

```bash
curl -H "Host: webapp.local" http://localhost/
```

```html
<h1>这是 K8s 版的反向代理项目</h1>
```

### ② 三副本负载均衡

```bash
for i in {1..30}; do curl -s -H "Host: webapp.local" http://localhost/ > /dev/null; done
kubectl logs -l app=webapp --prefix --since=30s | grep -o 'pod/[^/]*' | sort | uniq -c
```

```text
     6 pod/webapp-5c584bf485-9zql7
     6 pod/webapp-5c584bf485-hnqlw
     6 pod/webapp-5c584bf485-wm29b
```

**三个 Pod 完全均分。**

> **这里的坑**：一开始我用 `--tail=30`，结果每个 Pod 都显示 30 条——因为 **`--tail` 是"每个 Pod 各取 N 条"，不是总数**。
> 要做统计，得用 `--since`（时间窗口）。

### ③ 自愈

```bash
kubectl delete pod webapp-5c584bf485-97kb8
kubectl get pods -l app=webapp
```

```text
NAME                          READY   STATUS    AGE
webapp-5c584bf485-9zql7       1/1     Running   53m
webapp-5c584bf485-hnqlw       1/1     Running   39m
webapp-5c584bf485-wm29b       1/1     Running   33s   ← 新补的
```

**删掉的 `97kb8` 没了，回来的是 `wm29b`，AGE 只有 33 秒。**

### ④ 改配置，不重建

```bash
vi configmap.yaml     # 把标题改成「这是 哦哈哈哈」
kubectl apply -f configmap.yaml
sleep 90
curl -H "Host: webapp.local" http://localhost/
```

```html
<h1>这是 哦哈哈哈 </h1>
```

**页面变了，Pod 没重启。**

> 这个「哦哈哈哈」其实是我随手打的——但它成了一个很好的证据：**页面内容确实来自 ConfigMap，不是镜像里的死内容。**

---

## 四、资源限制：一个新知识点

```yaml
resources:
  requests:
    cpu: "50m"
    memory: "32Mi"
  limits:
    cpu: "200m"
    memory: "128Mi"
```

| 字段 | 含义 |
|---|---|
| **requests** | **保证**给你的资源，调度器按这个找节点 |
| **limits** | **上限**，超了就出事 |

**`200m` = 0.2 核**（1000m = 1 核）。

### 超了会怎样

| 超了 | 后果 |
|---|---|
| **CPU 超 limit** | **被限流**（变慢，但不杀） |
| **内存超 limit** | **容器被 OOMKilled**（杀掉重启） |

**这是面试高频题**：「为什么 Pod 一直重启？」

```bash
kubectl describe pod <名字> | grep -i oom
```

看到 `OOMKilled`，就是内存超了 limit。

---

## 五、你少写了什么

| | 第 6 课 | 今天 |
|---|---|---|
| nginx.conf 里的 upstream | **手写 8 行** | **不用写** |
| 反向代理配置 | **手写 server 块** | **Ingress 一条 rule** |
| 负载均衡 | nginx 轮询 | **Service 自动** |
| 副本数 | 手动 run 两次 | `replicas: 3` |
| 健康检查 | 无 | `readinessProbe` |
| 资源限制 | 无 | `resources` |
| 故障转移 | nginx 重试 | **K8s 摘除 + 重建** |
| 部署命令 | `podman-compose up -d` | `kubectl apply -f .` |

**少写了一个 nginx 配置文件，多了自愈、滚动更新、资源隔离。**

---

## 六、今天踩的坑

### ① 两条命令写在一行

```bash
for i in {1..9}; do ...; done kubectl logs ...
                              ↑ done 后面直接跟命令
```

```text
bash: 未预期的记号 "kubectl" 附近有语法错误
```

**`done` 是命令块的结束符，后面必须用 `;` 或换行。**

### ② `curl -H` 少了 `Host:` 前缀

```bash
curl -H "webapp.local" ...        # ✗ 不生效
curl -H "Host: webapp.local" ...  # ✓
```

**`-H` 的格式是 `"头名: 值"`。少了头名，curl 不会把它当 Host 头。**

### ③ kubectl 两种写法混用

```bash
kubectl delete pod 名字/web     # ✗ 两个斜杠
```

```text
error: arguments in resource/name form may not have more than one slash
error: there is no need to specify a resource type as a separate argument
```

**两种写法不能混：**

| 写法 | 例子 |
|---|---|
| 分开写 | `kubectl delete pod 名字` |
| 组合写 | `kubectl delete pod/名字` |

### ④ 标签拼错

```bash
kubectl get pods -l app=wenapp
No resources found in default namespace.
```

**`wenapp` → `webapp`。**

**`No resources found` 的报错很"温柔"**——它不说"你拼错了"。

> **看到这句，第一反应应该是核对标签和拼写**，而不是怀疑"Pod 是不是挂了"。

### ⑤ `--tail` 和 `--since` 混用

**要统计"这段时间发生了什么"，用 `--since`。**
**要看"最新的输出"，用 `--tail`。**

---

## 七、面试题

**1. Ingress 和 Service 的区别？**

Service 是四层（IP + 端口）的稳定入口；Ingress 是七层（HTTP Host / Path）路由，一个入口按域名或路径分发到多个 Service。

**2. `resources.requests` 和 `limits` 的区别？**

requests 是调度依据（保证量），limits 是硬上限。CPU 超 limit 被限流，内存超 limit 会 OOMKilled。

**3. 为什么 Pod 一直重启？**

常见原因：OOMKilled（内存超 limit）、livenessProbe 失败、启动命令错误。先看 `kubectl describe pod` 的 Events 和 Reason。

**4. 从 Docker 迁到 K8s，最大的变化是什么？**

从"管理容器"变成"声明状态"。不用再手写反向代理配置（Ingress 取代），不用手工保证副本数（Deployment 接管），不用手动重启挂掉的服务（control loop 自愈）。

---

## 八、一句话总结

> **同一个架构，Docker 版你写配置文件，K8s 版你写声明。**
>
> 少写的那部分，正是 K8s 替你做的事。
