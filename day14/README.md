# 第 14 课 · YAML 反向工程：字段、报错，与两次「我说错了」

> 本文是《从零学云原生》系列第 14 篇。
> 环境：RHEL 10 + k3s v1.36.5

**日期**：2026-11-16 / 11-17 ｜ **耗时**：约 3 小时

---

## 引子：一句自我评价

到第 13 课，我已经能跑通一堆实验了。但某天晚上我说了这么一句：

> **「闭卷写不出来；开卷看的话，我其实也很多看不懂。YAML 文件都是直接复制粘贴的。」**

**这句话点出了问题：我一直在「跟着做」，没有「理解」。**

- 闭卷写不出来 = 没记住（不可怕）
- **开卷也看不懂 = 没理解（这才是问题）**

**于是有了这三课。**

**规则也变了：**

```
旧模式：我给完整 YAML → 你复制 → 跑通
新模式：我让你加/删一个字段 → 你先猜 → apply 验证 → 看猜得对不对
```

**猜错是好事。猜错的那些，记得最牢。**

---

# 一、从 7 行开始

**不从 40 行的完整清单开始，从最小的能跑的东西开始：**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo
spec:
  containers:
    - name: c
      image: docker.m.daocloud.io/library/nginx:alpine
```

```bash
kubectl apply -f pod.yaml
kubectl get pod demo
```

**跑起来了。**

## 逐个删，看哪个是必须的

| 删掉什么 | 报错 | 结论 |
|---|---|---|
| `apiVersion` | `apiVersion not set, kind not set` | 必须 |
| `metadata.name` | `name or generateName is required` | 必须 |
| `containers` | `spec.containers: Required value` | 必须 |
| `containers[].name` | `spec.containers[0].name: Required value` | 必须 |
| **`containers[].image`** | **不报错，但容器起不来（ImagePullBackOff）** | 必须 |

**最后一行值得单独说：**

> **`image` 是唯一一个「apply 成功但运行失败」的字段。**
> **这类错误最难查，因为它不在 YAML 校验阶段暴露，要等到 Pod 状态里才看得见。**

---

# 二、`containerPort` 只是「声明」

**加上 `ports`：**

```yaml
      containers:
        - name: c
          image: docker.m.daocloud.io/library/nginx:alpine
          ports:
            - containerPort: 80
```

**我以为加了这个就能从外面访问。**

**答案：不能。**

```bash
kubectl get pod demo -o wide
```

**还是 `10.42.x.x` 的集群内 IP。**

**那 `containerPort` 干什么用？**

| 它做了 | 它没做 |
|---|---|
| 文档作用（别人看 YAML 知道端口） | ❌ 不开放端口 |
| Service 可以按名字引用（`targetPort: 80`） | ❌ 不创建 Service |

**对比 Docker：**

```bash
podman run -p 8080:80     # 这才真的开放端口
```

> **K8s 的 `containerPort` ≈ Dockerfile 里的 `EXPOSE`，不是 `-p`。**

---

# 三、Pod → Deployment：`selector` 到底管什么

**把 Pod 改成 Deployment，多了三样东西：**

```yaml
apiVersion: apps/v1        # ← 注意：从 v1 变成 apps/v1
kind: Deployment           # ← 从 Pod 变成 Deployment
metadata:
  name: demo
spec:
  replicas: 2              # ← 新增
  selector:                # ← 新增
    matchLabels:
      app: demo
  template:                # ← 原来 Pod 的内容被包进这里
    metadata:
      labels:
        app: demo
    spec:
      containers:
        - name: c
          image: docker.m.daocloud.io/library/nginx:alpine
```

**`selector` 和 `template.labels` 必须一致**，否则报：

```
`selector` does not match template `labels`
```

**为什么必须一致？**

> **`selector` 是「我要管哪些 Pod」，`template.labels` 是「我造出来的 Pod 带什么标签」。**
> **对不上，Deployment 就管不到自己造的 Pod —— 会导致互相抢 Pod，所以 K8s 直接拒绝。**

---

# 四、第一次我说错了：`pod-template-hash`

## 我做了一个实验，预测错了

**我说：手工建一个带 `app=demo` 标签的 Pod，Deployment 会把它算进副本数，然后删掉多余的。**

**执行：**

```bash
kubectl run fake --image=docker.m.daocloud.io/library/nginx:alpine --labels=app=demo
kubectl get pods
```

```
demo-74bb9ff68b-p49hw   Running
demo-74bb9ff68b-snw9j   Running
fake                    Running    ← 3 个，replicas 是 2
```

**等了 20 秒，`fake` 还在。**

**Deployment 没有删它。**

## 为什么

**看 ReplicaSet 的完整 selector：**

```bash
kubectl get rs demo-74bb9ff68b -o jsonpath='{.spec.selector}'
```

```json
{"matchLabels":{"app":"demo","pod-template-hash":"74bb9ff68b"}}
```

**多了 `pod-template-hash`。**

## 这个标签是谁加的

| 谁加的 | 加在哪 |
|---|---|
| Deployment controller | **ReplicaSet 的 selector** |
| Deployment controller | **Pod 的 labels**（在 template 基础上追加） |

**所以 `fake` 只有 `app=demo`，缺少 `pod-template-hash` → 不匹配 → ReplicaSet 不管它。**

**验证：**

```bash
kubectl get pod fake --show-labels
```

**只有 `app=demo`。**

## 为什么要这么设计

**假设没有 `pod-template-hash`：**

```
改镜像 → 新建一个 ReplicaSet
两个 RS 的 selector 都是 app=demo
→ 互相抢 Pod → 一边建一边删 → 无限循环
```

**有了 hash：**

```
demo-74bb9ff68b（旧版本，selector 带 hash=74bb9ff68b）
demo-8f7b6c5d4 （新版本，selector 带 hash=8f7b6c5d4）
→ 各管各的 Pod → 互不干扰
```

## 这一个 hash 解释了三件事

**第 9 课我见过这个现象，当时不知道为什么：**

```bash
kubectl set image deployment/nginx-deploy nginx=...:alpine
kubectl get rs
```

```
nginx-deploy-75c6d59d89   0    0    0    ← 旧的，缩到 0
nginx-deploy-8f7b6c5d4    3    3    3    ← 新的
```

**现在明白了：**

| 改动 | hash 变吗 | 会滚动吗 |
|---|---|---|
| 改 `replicas`（2→3） | ❌ 不变 | **不滚动**，只扩缩容 |
| 改 `image` | ✅ 变 | **滚动更新** |
| 改环境变量 / 探针 | ✅ 变 | 滚动更新 |

**「改副本数不重启，改镜像会重启」的底层原因，就是这个 hash。**

> **`hash` 是根据 `template` 的内容算出来的。**
> **模板变了，hash 就变，就新建一个 ReplicaSet。**

---

# 五、六个破坏动作：报错长什么样

**第二课换了个方法：不教对怎么写，只教认错。**

**每个任务：给一个破坏动作 → 先猜报错 → 再执行验证。**

| # | 破坏动作 | 报错 |
|---|---|---|
| 1 | `replicas:` → `replica:` | `unknown field "spec.replica"` |
| 2 | `replicas: 2` → `replicas: "2"` | **`cannot unmarshal string into ... int32`** |
| 3 | 用 Tab 缩进 | `found character that cannot start any token` |
| 4 | 重复写两个 `replicas` | `key "replicas" already set in map` |
| 5 | `image:` → `images:` | `unknown field "spec.template.spec.containers[0].images"` |
| 6 | `replicas:2`（缺空格） | `could not find expected ':'` |

**还顺带踩了一个新错：**

```yaml
apiVersion: app/v1        # 少了个 s
```

```
error: resource mapping not found ... no matches for kind "Deployment" in version "app/v1"
ensure CRDs are installed first
```

**那句 `ensure CRDs are installed first` 是误导** —— 用内置资源不需要装 CRD。

---

# 六、第二次我说错了：`replicas: "2"`

## 我当时的断言

**我说：「`"2"` 能过，K8s 会自动把 `"2"` 转成数字；但 `"two"` 不行，因为要 integer。」**

## 实测

```bash
sed 's/replicas: 2/replicas: "2"/' base.yaml > t2.yaml
kubectl apply -f t2.yaml
```

```
Error from server (BadRequest): error when creating "t2.yaml":
Deployment in version "v1" cannot be handled as a Deployment:
json: cannot unmarshal string into Go struct field
DeploymentSpec.spec.replicas of type int32
```

**报错了。我错了。**

## 这个报错信息量很大

```
Error from server (BadRequest)
       ↑
  这是服务端报的

json: cannot unmarshal string into Go struct field
DeploymentSpec.spec.replicas of type int32
                    ↑                    ↑
              精确到结构体字段        目标类型
```

**翻译：JSON 里给的是 string，但这个字段在 Go 结构体里是 int32，转不过去。**

## 为什么客户端校验没拦住

```
replicas: "2"  →  通过客户端 schema 校验  →  到服务端才炸
```

**说明 `kubectl apply` 的客户端校验，对「类型」是宽松的。**

**它主要检查：**

- 字段名存不存在（`unknown field`）
- 必填字段有没有（`Required value`）

**它不太检查：**

- **类型是否匹配**（`"2"` vs `2`）
- 值的范围是否合理

**真正的类型校验，在服务端 Go 反序列化那一刻。**

## 正确的类型规则

| 字段类型 | 正确 | 错误 |
|---|---|---|
| 整数（replicas、port、containerPort） | `2` | `"2"`、`2.0` |
| 布尔 | `true` | `"true"` |
| 字符串（name、image） | `"text"` | — |

**加不加引号不是风格问题，是类型问题。**

---

# 七、5 层报错模型

**两次"我说错了"之后，我把报错按发生位置分了层：**

```
① YAML 解析  →  ② API 发现  →  ③ 客户端校验  →  ④ 服务端反序列化  →  ⑤ 服务端逻辑
   本地            本地            本地            apiserver           apiserver
```

| 层 | 报错特征 | 典型原因 |
|---|---|---|
| ① | `error parsing` / `converting YAML to JSON` | 缩进、Tab、重复 key、冒号后缺空格 |
| ② | `no matches for kind X in version Y` | `apiVersion` 错 |
| ③ | `error validating` / `unknown field` / `Required value` | 字段名错、缺必填 |
| ④ | **`Error from server (BadRequest)`** + `cannot unmarshal` | **类型错** |
| ⑤ | `NotFound` / `AlreadyExists` / `Forbidden` | 对象状态、权限 |

## 一句话判断

| 开头 | 谁报的 |
|---|---|
| **`error:`**（小写） | **kubectl 本地，根本没发给集群** |
| **`Error from server`** | **apiserver 拒绝了** |
| **`The ... is invalid:`** | 客户端校验 |

**这一眼就能定「客户端还是服务端」，比逐字读报错快十倍。**

---

# 八、我的 6 次猜测 vs 结论

**我不只是做实验，还先把猜测写下来，再对照答案。结果很有意思：**

| 任务 | 我的猜测 | 判定 |
|---|---|---|
| 1 `replica` | 「英文从复数变单数，所以只建 1 个」 | ❌ 错，K8s 直接拒绝 |
| 2 `"2"` | 「字符串，无法识别会报错」 | ✅ 对（连 AI 都说错了，我猜对了） |
| 3 Tab | 「tab 只是自动填充，应该没影响」 | ❌ 错，YAML 硬禁 Tab |
| 4 重复 key | 「重复冲突，无法识别用哪个」 | ✅ 对 |
| 5 `images` | 「复数不对，单数才对」 | ✅ 结论对，理由错 |
| 6 `replicas:2` | 「会被当成数值」 | ✅ 结论对，理由错 |

## 统计

| | 次数 |
|---|---|
| **猜对结论** | 5/6 |
| **猜对原因** | **3/6** |

## 这说明什么

**我已经能「感觉到哪里不对」，但推理链条还是从「英文语义 / 日常经验」出发，而不是从「schema 和规范」出发。**

**任务 1 最典型：**

```
我的模型：K8s 理解 "replica 是单个" → 所以只建 1 个
实际机制：K8s 只做字符串匹配 → schema 里没有这个 key → 直接拒绝
```

> **程序不认识英文单复数，只认识 schema 里列出的名字。**

**这个差别在真实排障里很致命：**

- 从语义推 → 花时间验证一个错误的假设
- 从 schema 推 → 查 `kubectl explain`，30 秒定位

---

# 九、一个顺手解决的小疑问

**我问：「为什么一会用 `rm -f` 删除，一会又用 `kubectl delete -f` 删除？」**

**答案：两者作用域完全不同。**

| 命令 | 删的是 |
|---|---|
| `rm -f bad1.yaml` | **本地文件**（磁盘） |
| `kubectl delete -f bad1.yaml` | **集群里的对象**（K8s） |

**为什么课里两种都出现：**

| 任务 | apply 结果 | 集群里有对象吗 |
|---|---|---|
| 1、2、5 | 可能成功 | 有 → 需要 `kubectl delete` |
| 3、4、6 | 解析错误，没提交 | **没有 → 只需 `rm`** |

**标准做法应该统一成两步：**

```bash
kubectl delete -f bad1.yaml --ignore-not-found   # 删集群对象（没有也不报错）
rm -f bad1.yaml                                   # 删本地文件
```

---

# 十、三课下来学到了什么

## 1. 字段不是「写着好看」，每个都有实际作用

| 字段 | 删了会怎样 |
|---|---|
| `apiVersion` / `kind` | 直接报错 |
| `name` | 直接报错 |
| `containers` | 直接报错 |
| `image` | apply 成功，但容器起不来 |
| `containerPort` | 删了没影响（只是声明） |

**「必须」和「可选」的边界，只能一个个试出来。**

## 2. `selector` 认的是「标签」，不是「我造的东西」

**`pod-template-hash` 的存在，让每个 ReplicaSet 只认自己那一批 Pod。**

**这一个机制，同时解释了：**

- 为什么手工 Pod 不会被管
- 为什么改镜像会新建 RS
- 为什么改副本数不重启

## 3. 报错的第一行就告诉你「错在哪一层」

```
error: ...                   → 本地，YAML/字段问题
Error from server ...        → 服务端，发过去了但被拒
The ... is invalid: ...      → 客户端校验
```

**先分层，再定位。** 和之前查 502 时的「逐层切分」是同一个方法。

## 4. 我说错了两次，都是被实测纠正的

| 我说 | 实际 |
|---|---|
| Deployment 会把手工 Pod 算进副本数 | **不会**，缺 `pod-template-hash` |
| `replicas: "2"` 能过 | **不能**，`cannot unmarshal string into int32` |

> **文档会过时，AI 会说错，别人的经验未必适用你的版本。**
> **能跑一遍的，就跑一遍。**

---

# 一句话总结

> **YAML 不是作文，是填空；报错不是障碍，是文档。**
>
> **而最重要的收获不是记住了哪个字段，是养成了一个习惯：**
> **别人给结论，自己跑一遍。**
