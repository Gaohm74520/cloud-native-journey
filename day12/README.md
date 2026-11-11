# 第 12—13 课 · 数据、密钥与打包：PV/PVC、Secret、Helm

> 本文是《从零学云原生》系列第 12 篇。
> 环境：RHEL 10 + k3s v1.36.5 + Helm v3.16.3

**日期**：2026-11-09 / 11-11 ｜ **耗时**：约 6 小时（跨两天）

---

## 引子：三个问题

到这里，我的 K8s 集群上已经跑得起来东西了。

但有三件事还没解决：

| 问题 | 后果 |
|---|---|
| **Pod 会被删，数据怎么办** | 重启一次，写的东西全没 |
| **密码放哪** | 写进 YAML 就是明文 |
| **7 个 YAML 散在 4 个目录** | 换个环境要复制粘贴改 20 处 |

**这一篇解决这三个。**

---

# 一、PV / PVC：数据怎么活过 Pod

## 三个概念

| 对象 | 是什么 | 类比 |
|---|---|---|
| **PV**（PersistentVolume） | 集群里**一块真实的存储** | **停车位** |
| **PVC**（PersistentVolumeClaim） | **用户的申请**（"我要 1Gi"） | **停车证** |
| **StorageClass** | **自动分配器** | **停车场管理系统** |

**流程：**

```
写 PVC（我要 1Gi）
      ↓
StorageClass 看到申请
      ↓
自动创建 PV（1Gi）
      ↓
PVC 与 PV 绑定（Bound）
      ↓
Pod 挂载 PVC
```

## 写一个 PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mydata
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

```bash
kubectl apply -f pvc.yaml
kubectl get pvc
```

```text
NAME     STATUS    VOLUME    CAPACITY   STORAGECLASS
mydata   Pending   <unset>              local-path
```

**`Pending`。**

---

## 二、那个卡了 12 分钟的 Pending

第一反应是"坏了"。但 `describe` 里有完整故事：

```bash
kubectl describe pvc mydata
```

```text
Events:
  Normal   WaitForFirstConsumer   8m12s (x21 over 12m)   waiting for first consumer...
  Normal   ExternalProvisioning   7m27s (x5 over 8m27s)  Waiting for a volume to be created...
  Warning  ProvisioningFailed     6m     failed to provision volume with StorageClass "local-path":
                                          create process timeout after 120 seconds
  Normal   Provisioning           5m45s  External provisioner is provisioning volume...
  Normal   ProvisioningSucceeded  5m42s  Successfully provisioned volume
```

**两个信息：**

**① `WaitForFirstConsumer` 是正常的**

`kubectl get pvc` 里有一列：

```text
VOLUMEBINDINGMODE: WaitForFirstConsumer
```

意思是**"等第一个消费者出现再分配"**。

**因为 `local-path` 的存储就在某台节点的磁盘上**——必须先知道 Pod 调度到哪台机器，才能在那台机器上建目录。

**如果 Pod 在 A 节点，存储却在 B 节点，就挂不上。**

| 模式 | 行为 | 适用 |
|---|---|---|
| `Immediate` | 立即分配 | 云盘（不绑节点） |
| **`WaitForFirstConsumer`** | **等 Pod 出现再分配** | **本地盘（绑节点）** |

**所以 PVC 一直 `Pending`，不是故障——是还没人用。**

**② 但建了 Pod 之后还是 Pending**

那才是真问题。Events 给出了答案：

```text
create process timeout after 120 seconds
```

**local-path-provisioner 创建卷时会起一个 helper pod（用 busybox）在节点上 `mkdir`。第一次拉镜像慢，120 秒超时；重试时镜像已缓存，秒成功。**

**不是配置错，是环境慢。**

**5 次重试后，`ProvisioningSucceeded`。**

---

### 这条经验值得单独记

> **PVC 卡在 `Pending`，第一件事看 `VOLUMEBINDINGMODE`。**
>
> - `Immediate` + Pending → **真有问题**（无可用 PV、容量不够）
> - `WaitForFirstConsumer` + Pending → **先看有没有 Pod 在用**
>
> **而且：`Pending` 不是答案，`Events` 才是。**

**这和上一篇那个 `READY 0/1` 是同一类事——"看起来像故障，其实是设计"。**

---

## 三、验证数据真的活着

```bash
kubectl exec -it pvc-demo -- sh
```

容器里：

```bash
echo "这行数据必须活下来" > /data/test.txt
cat /data/test.txt
exit
```

**删掉 Pod：**

```bash
kubectl delete pod pvc-demo
```

**重建，再读：**

```bash
kubectl apply -f pod.yaml
kubectl exec -it pvc-demo -- cat /data/test.txt
```

```text
这行数据必须活下来
```

**Pod 死了一次，数据活着。**

**对比 `emptyDir`：**

```yaml
volumes:
  - name: data
    emptyDir: {}     # 生命周期 = Pod，删了就没了
```

**PVC 的生命周期独立于 Pod。Pod 删十次，数据都在。**

**数据真正躺在：**

```bash
ls /var/lib/rancher/k3s/storage/
```

```text
pvc-fb461150-..._default_mydata/
```

**又在磁盘上。又是第 2 课那句话：数据在容器外面。**

---

# 四、Secret：base64 不是加密

## 和 ConfigMap 的关系

| | ConfigMap | Secret |
|---|---|---|
| 存什么 | 非敏感配置 | **密码、token、证书** |
| 内容形式 | 明文 | **base64 编码** |
| 挂载方式 | 完全一样 | 完全一样 |

**本质上，Secret 就是"加了 base64 的 ConfigMap"。**

## 创建

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
stringData:
  DB_USER: admin
  DB_PASSWORD: "S3cr3t!2026"
```

| 字段 | 你写什么 | K8s 存什么 |
|---|---|---|
| `stringData` | **明文**（好写） | — |
| `data` | base64 | base64 |

**用 `stringData` 最省事**——不用自己算 base64。

## ⭐ 证明 base64 不是加密

```bash
kubectl get secret db-secret -o yaml
```

```yaml
data:
  DB_PASSWORD: UzNjcjN0ITIwMjY=
  DB_USER: YWRtaW4=
```

```bash
echo 'UzNjcjN0ITIwMjY=' | base64 -d
```

```text
S3cr3t!2026
```

**一行命令，密码就出来了。**

> **base64 是"编码"，不是"加密"。**
> 它只是让内容不直观。**任何有读 Secret 权限的人，一行命令还原。**

**那 Secret 存在的意义？**

| 它做了 | 它没做 |
|---|---|
| 和普通配置**分开管理** | ❌ 不加密 |
| 可以单独授权（RBAC） | ❌ 不防解码 |
| 不在 `describe` 里直接显示 | ❌ 不防 `-o yaml` |

**真实生产还要额外做：**

- etcd 静态加密（`EncryptionConfiguration`）
- 外部密钥管理（Vault、云厂商 KMS）
- RBAC 严格控制 `get secret` 权限

---

## 五、一个很少有人讲的泄露：annotation

用 `stringData` + `kubectl apply` 之后，看这个：

```yaml
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {..."stringData":{"DB_PASSWORD":"S3cr3t!2026","DB_USER":"admin"},"type":"Opaque"}
```

**你写的明文密码，被 `kubectl apply` 自动记在了 annotation 里。**

**结果：**

| 你以为 | 实际 |
|---|---|
| 密码在 Secret 里，受保护 | **annotation 里还有一份明文** |

**任何能 `get secret` 的人，从这里直接读到明文——连 base64 都不用解。**

### 怎么避免

**① 用 `kubectl create secret`（不落 annotation）**

```bash
kubectl create secret generic db-secret \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD='S3cr3t!2026'
```

**② 或用 `data` 字段自己写 base64**

```yaml
data:
  DB_PASSWORD: UzNjcjN0ITIwMjY=
```

**这样 annotation 里存的也是 base64。**

**③ 最根本：Secret 的 YAML 永远不要提交到 Git**

**验证：**

```bash
kubectl get secret db-secret -o yaml
```

```text
（没有 annotations 了）
```

---

## 六、挂进 Pod 的两种方式

### 环境变量

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-secret
        key: DB_PASSWORD
```

```bash
kubectl exec -it secret-demo -- env | grep DB_
```

```text
DB_USER=admin
DB_PASSWORD=S3cr3t!2026
```

**坑：Secret 改了，已经运行的 Pod 不会更新，要重启。**

### 挂成文件（推荐）

```yaml
volumeMounts:
  - name: creds
    mountPath: /etc/secret
    readOnly: true
volumes:
  - name: creds
    secret:
      secretName: db-secret
      defaultMode: 0400      # 只有属主可读
```

| | 环境变量 | 挂成文件 |
|---|---|---|
| 权限控制 | ❌ 进程能读到 | ✅ `0400` |
| 自动更新 | ❌ 要重启 | ✅ 自动同步 |
| 容易泄露 | ✅ `env` 一查就看到 | 较难 |

**生产推荐「挂成文件」+ `0400`。**

---

# 七、Helm：把 7 个文件装进一个包

## 问题：资产散在 4 个目录

```text
/data/k8s-probe/     probe.yml
/data/k8s-project/   app.yaml configmap.yaml ingress.yaml
/data/k8s-storage/   pod.yaml pvc.yaml
/data/k8s-secret/    secret.yaml pod.yaml
```

**4 个目录、7 个 YAML、两个重名的 `pod.yaml`。**

**而且文件之间有关系：** `app.yaml` 引用 `configmap: webapp-html`，`pod.yaml` 引用 `claimName: mydata`。

**换环境怎么办？**

| 需求 | 你得做什么 |
|---|---|
| 部署到测试（1 副本、test.local） | 复制 6 个文件，逐个改 |
| 部署到生产（5 副本、prod.local） | 再复制 6 个，再逐个改 |
| 回滚上一版 | 手动还原每个文件 |

**12 个文件、改 20 处、还可能漏改一处。**

> **Helm 的第一价值不是"少敲命令"，是"让一套东西待在一个地方"。**

---

## 三个概念

| 概念 | 是什么 | 类比 |
|---|---|---|
| **Chart** | **一个包**（模板 + 默认值） | **安装包** |
| **Release** | **一次安装的实例** | **装好的那份程序** |
| **Values** | **参数** | **安装时的选项** |

**关键：同一个 Chart 可以装成多个 Release。**

```bash
helm install shop ./myapp
helm install blog ./myapp
```

**两份独立实例，差异只在 values。**

---

## Chart 的结构

```text
myapp/
├── Chart.yaml        # 包的名字和版本
├── values.yaml       # 默认参数
└── templates/
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

**只有 6 行是真配置，其余全是 `#` 注释：**

```yaml
apiVersion: v2
name: myapp
description: A Helm chart for Kubernetes
type: application
version: 0.1.0        # Chart（安装包）的版本
appVersion: "1.16.0"  # 里面装的程序的版本
```

**两个版本别混：**

| 字段 | 什么时候改 |
|---|---|
| `version` | 改了模板/配置 |
| `appVersion` | 里面的程序升级了 |

---

## 两个占位符

```yaml
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
```

| 占位符 | 来源 |
|---|---|
| `{{ .Values.xxx }}` | **values.yaml** |
| **`{{ .Release.Name }}`** | **安装时给的名字** |

**`{{ .Release.Name }}` 是关键设计：**

```bash
helm template demo .   →  name: demo, demo-html
helm template blog .   →  name: blog, blog-html
```

**同一份模板，两个完全不同的实例，资源名不冲突。**

> 这就是为什么真实项目里 `{{ .Release.Name }}` 几乎出现在每个 `metadata.name` 里。

---

## 先渲染，不安装

```bash
helm template demo .
```

**把所有模板渲染成普通 YAML 打印出来。**

**每个对象前面有一行：**

```yaml
# Source: myapp/templates/ingress.yaml
```

**排错神器**——混在几十个对象里，一眼知道来自哪个文件。

---

## 安装、升级、回滚

```bash
helm install shop .
```

```bash
helm upgrade shop . --set replicaCount=1
```

```bash
helm rollback shop 1
```

```bash
helm history shop
```

```text
REVISION   STATUS       DESCRIPTION        CHART
1          superseded   Install complete   myapp-0.1.0
2          superseded   Upgrade complete   myapp-0.1.0
3          deployed     Rollback to 1      myapp-0.1.0
```

**注意第 3 条：回滚不是"撤销第 1 条"，而是"新建第 3 条，内容等于第 1 条"。**

**所以历史永远只增不减**——随时能回到任意 revision。

### 这是 Helm 独有的能力

| 工具 | 记录什么 |
|---|---|
| `git log` | **代码**历史 |
| `docker history` | **镜像**分层 |
| **`helm history`** | **部署**历史 |

**只有 Helm 知道"这个集群上装过什么、什么时候装的、回滚过几次"。**

**面试问"线上怎么回滚"，标准答案的两级：**

```bash
kubectl rollout undo    # 回滚一个 Deployment
helm rollback           # 回滚一整套应用（含 ConfigMap/Service/Ingress）
```

---

# 八、坑清单（这一篇踩了 9 个）

| # | 坑 | 现象 | 真相 |
|---|---|---|---|
| 1 | PVC 一直 Pending | 像故障 | `WaitForFirstConsumer`，等 Pod |
| 2 | provisioner 超时 | `create process timeout after 120 seconds` | helper pod 拉镜像慢，重试成功 |
| 3 | `\` 续行后面带空格 | `exactly one NAME is required, got 3` | `\` 必须是行尾最后一字符 |
| 4 | `--from-listral` | `unknown flag` | **literal 拼错** |
| 5 | `vi` 打开不存在的文件 | 进去一片空白 | **静默新建**，不报错 |
| 6 | `cat -f` | `无效的选项 -- f` | cat 没有 `-f` |
| 7 | `cat` 二进制文件 | 满屏乱码 | kubectl 是 ELF 二进制，用 `file` 判断 |
| 8 | helm 找不到集群 | `http://localhost:8080/connection refused` | k3s 的 kubeconfig 在 `/etc/rancher/k3s/`，helm 只找 `~/.kube/config` |
| 9 | stringData + apply | annotation 里存明文密码 | `last-applied-configuration` |

**第 5、8、9 是最值得记的三个：**

- **`vi` 静默新建** —— 会让你以为"文件被清空了"
- **`kubectl` 能用 ≠ `helm` 能用** —— 它们读配置的方式不一样
- **`apply` 会把明文存进 annotation** —— Secret 的 YAML 永远别提交 Git

---

# 九、面试题

**1. PV 和 PVC 的关系？**

PV 是集群里一块真实存储（由管理员或 StorageClass 提供），PVC 是用户对存储的申请。两者通过 binding 配对。这样用户不用关心"存储在哪台机器、什么类型"。

**2. `WaitForFirstConsumer` 为什么要这样设计？**

本地盘或云盘可能只能挂在特定节点上。先知道 Pod 会调度到哪个节点，才能在那个节点分配存储。否则会出现"Pod 在 A 节点，存储绑在 B 节点"的情况。

**3. Secret 是加密的吗？**

不是。Secret 的内容只是 base64 编码，任何人都能 `base64 -d` 还原。真正的保护要靠 RBAC 控制访问、etcd 静态加密、或外部密钥管理。

**4. Helm 的 Chart 和 Release 是什么关系？**

Chart 是"包"（模板 + 默认值），Release 是"这个包的一次安装实例"。同一个 Chart 可以安装成多个 Release，靠 `{{ .Release.Name }}` 让资源名不冲突。

**5. `helm rollback` 和 `kubectl rollout undo` 的区别？**

`rollout undo` 只回滚一个 Deployment；`helm rollback` 回滚整套应用（Deployment + Service + ConfigMap + Ingress 等），并且有完整的 revision 历史。

---

# 十、一句话总结

> **PVC 让数据活过 Pod，Secret 让密码不进镜像，Helm 让一堆 YAML 变成一个可以安装的包。**
>
> 而三个坑教会我一件事：**`Pending`、`Running`、`deployed` 这些状态都不是答案，`describe` 里的 Events 才是。**
