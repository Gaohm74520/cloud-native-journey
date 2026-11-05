# 第 08 课 · CI/CD：让 `git push` 自动构建镜像

> 本文是《从零学云原生》系列第 8 篇，也是 Docker 部分的最后一课。
> 环境：GitHub Actions + podman/ghcr.io

**日期**：2026-11-04 ｜ **耗时**：约 2.5 小时（含大量排错）

---

## 引子：手工构建的尽头

前七课，构建镜像是这样：

```bash
vi Dockerfile
podman build -t myweb:v5 .
podman run -d ...
```

**每次改代码，都得手动敲一遍。**

而且——**凭记忆敲的步骤，迟早会漏。** 忘了加某个参数、忘了重新 build、在错误的目录执行……

**能不能我 push 完，机器自己构建？**

这就是 CI/CD。

---

## 一、三个词，别混

| 缩写 | 全称 | 做什么 |
|---|---|---|
| **CI** | Continuous Integration 持续集成 | 每次提交**自动构建 + 测试** |
| **CD** | Continuous Delivery 持续交付 | 自动产出**可发布**的包 |
| **CD** | Continuous Deployment 持续部署 | 自动**发布上线** |

本课做到 **CI + 交付**：push 后自动构建镜像，推到镜像仓库（ghcr.io）。

---

## 二、GitHub Actions 的五个概念

| 概念 | 是什么 | 在哪 |
|---|---|---|
| **workflow** | 一条流水线 | `.github/workflows/*.yml` |
| **event** | 什么触发 | `on: push` |
| **job** | 一组任务（同一台机器） | `jobs: build:` |
| **step** | job 里的一步 | `steps:` |
| **runner** | 执行任务的机器 | `runs-on: ubuntu-latest` |

**一句话：在仓库里放一个 YAML 说明"push 之后做什么"，GitHub 找一台干净的机器执行一遍。**

### 一个巨大的好处

**runner 在 GitHub 的机房（国外），拉 docker.io 完全不需要镜像代理。**

我在本地被这个问题折磨了半小时（第 1 课），在 workflow 里直接写 `FROM nginx` 就行。

> **环境决定写法。** 同一行代码，换个地方跑，写法就不同。

---

## 三、实验 1：最小 workflow

```yaml
name: hello

on:
  push:
    branches: [main]

jobs:
  say-hi:
    runs-on: ubuntu-latest
    steps:
      - name: 打印一句话
        run: echo "流水线跑起来了"

      - name: 看当前目录
        run: pwd && ls -la
```

Commit 后去仓库顶部 **Actions**，能看到一条记录，30 秒后变绿。

### 我踩的第一个坑：目录是空的

点开「看当前目录」，输出是：

```text
/home/runner/work/cloud-native-journey/cloud-native-journey
total 8
drwxr-xr-x 2 runner runner 4096 .
drwxr-xr-x 3 runner runner 4096 ..
```

**只有 `.` 和 `..`，一个文件都没有。**

原因：**我漏了 `actions/checkout`。**

runner 是一台**全新的空机器**，它知道你的仓库地址（目录结构都建好了），但**不会自动拉代码**。

加上这一行：

```yaml
      - uses: actions/checkout@v4
```

再跑，目录变成 `total 52`，`README.md`、`day01~day07`、`redhat-challenge` 全在。

**空 vs 有内容，这个对比比任何解释都清楚。**

> **几乎所有 workflow 的第一步都是 checkout。** 没有它，`docker build .` 里的 `.` 就是个空目录。

---

## 四、实验 2：自动构建镜像

**Dockerfile**（仓库根目录）：

```dockerfile
FROM nginx
RUN echo '<h1>这个镜像由 CI 自动构建</h1>' > /usr/share/nginx/html/index.html
EXPOSE 80
```

**workflow**：

```yaml
name: build-image

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: 构建镜像
        run: docker build -t myapp:${{ github.sha }} .

      - name: 看镜像
        run: docker images
```

跑完 10 秒，绿勾。

点开「构建镜像」，能看到 Docker 一层层构建——**和本地 `podman build` 输出几乎一样**，只是机器在 GitHub 的机房。

**`${{ github.sha }}`** 是这次提交的哈希，用它当 tag，保证每个镜像都能对应到具体代码——**这就是可追溯。**

---

## 五、实验 3：推送到 ghcr.io

构建完就销毁太可惜。推到 **ghcr.io**（GitHub Container Registry）：

```yaml
name: push-image

on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: 登录 ghcr.io
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: 构建并推送
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/gaohm74520/cloud-native-journey:latest
```

**三个关键点：**

| 行 | 为什么 |
|---|---|
| `permissions: packages: write` | 没它推不上去 |
| `${{ secrets.GITHUB_TOKEN }}` | **GitHub 自动提供**，不用手配密钥 |
| 镜像名**全小写** | Docker 规范要求 |

---

## 六、今天踩的 6 个坑（全是真金白银）

### 1. Token 缺 `workflow` 权限

```text
refusing to allow a Personal Access Token to create or update workflow
`.github/workflows/hello.yml` without `workflow` scope
```

**GitHub 对 `.github/workflows/` 目录单独加了一层保护。** 因为流水线能执行任意命令，token 被偷就能在里面塞恶意代码。

修：去 token 设置里勾上 **`workflow`**。

> **classic token 编辑权限不会改变 token 值**，所以旧的 token 字符串仍然可用。

### 2. YAML 冒号后面必须空格

我手敲 workflow 时写成：

```yaml
name:push-image
branches:[main]
runs-on:ubuntu-latest
```

**满屏红色波浪线。**

YAML 的硬规则：**`键: 值`，冒号后面必须有一个空格。**

**三条铁律：**

1. 冒号后必须有空格
2. 缩进只能用空格（2 个一组），**不能用 Tab**
3. 列表项 `-` 后面也要空格

> **YAML 不是适合手敲的格式。** 真实工作里这类配置靠"复制模板 + 改值"，没人从零打。这不是偷懒，是降低出错率。

### 3. `job` 写成了 `jobs`

```yaml
job:      # ✗
  build:

jobs:     # ✓ 复数，固定键名
  build:
```

### 4. 镜像名必须全小写

```text
invalid tag "ghcr.io/Gaohm74520/cloud-native-journey:latest":
repository name must be lowercase
```

我的 GitHub 用户名是 `Gaohm74520`，`${{ github.repository }}` 原样返回带大写，被拒。

**因为镜像名会成为 DNS 域名的一部分，而域名不区分大小写，所以强制小写避免歧义。**

两种修法：

```yaml
# ① 写死小写
tags: ghcr.io/gaohm74520/cloud-native-journey:latest
```

```yaml
# ② 自动转小写（bash 的 ${VAR,,} 语法）
- run: echo "REPO=${GITHUB_REPOSITORY,,}" >> $GITHUB_ENV
...
tags: ghcr.io/${{ env.REPO }}:latest
```

### 5. `Error in the HTTP2 framing layer`

Git 走 HTTP/2 时的已知问题（国内网络下常见）：

```bash
git config --global http.version HTTP/1.1
```

一劳永逸。

### 6. `Failed to connect to github.com port 443`

```text
Failed to connect to github.com port 443 after 21054 ms
```

**这不是配置错误，是网络不通。** 而且讽刺的是——**几分钟前刚 push 成功过**。

GitHub 在国内时通时不通，同一个环境也会变。

**处理：重试。**

```bash
for i in 1 2 3 4 5; do git push && break; echo "第 $i 次失败"; sleep 10; done
```

> **重试不是无能，是应对网络不确定性的标准手段。** 真实自动化脚本都配重试机制（指数退避），不是为了掩盖问题，是因为网络本来就不稳定。

---

## 七、一个实用的变通：用网页建 workflow

网络死活不通时，我用了一个办法：**在 GitHub 网页上直接创建文件**。

- 网页提交**不需要 token**（浏览器已登录）
- 但打开网页需要能访问 github.com（可以用 Watt Toolkit 加速）

**目标不是"必须用 git push"，而是"把文件放到仓库里"。** 手段可以换。

> **分清目标和手段。** 这个习惯在排障时特别重要——你卡住的常常只是某一种手段，而目标往往还有别的路径。

---

## 八、这套东西到底省了什么

| | 手工 | 流水线 |
|---|---|---|
| 谁执行 | 你 | GitHub 的机器 |
| 什么时候 | 你记得的时候 | **每次 push 自动** |
| 环境 | 你的电脑（可能配错） | 干净 ubuntu（每次一致） |
| 记录 | 没有 | 每次运行都有完整日志 |
| 一致性 | 靠自觉 | **强制** |

**最后一条最重要。**

> **runner 每次都是全新的机器**，没有你电脑上的缓存、环境变量、临时文件。
> 所以"在我机器上是好的"这个千古难题，在 CI 里根本不存在。

---

## 九、CD 部分：自动部署怎么做

真正的"自动部署到服务器"，还需要：

1. 一台能接受部署的服务器
2. 一种连接方式：
   - **SSH**：workflow 里 ssh 登录服务器，`docker pull && docker run`
   - **Webhook**：服务器上跑服务，收到通知就拉镜像
   - **K8s**：`kubectl set image` 滚动更新（最标准）

**典型链路：**

```
git push
  → Actions 构建镜像
  → 推到 ghcr.io
  → kubectl set image deployment/app app=ghcr.io/xxx:sha
  → K8s 滚动更新
```

**这就是下一阶段学 K8s 会接触的完整流程。**

---

## 十、我的仓库现在的样子

```
cloud-native-journey/
├── .github/workflows/
│   └── push.yml          ← 构建 + 推送镜像
├── Dockerfile            ← FROM nginx（不需要代理）
├── README.md
├── day01 ~ day07/
└── redhat-challenge/
```

**push 一次，自动构建、自动推送。** 镜像在 `ghcr.io/gaohm74520/cloud-native-journey:latest`。

---

## 十一、面试题

**1. CI 和 CD 分别是什么？两个 CD 有什么区别？**

CI 是持续集成，每次提交自动构建和测试；CD 有两个含义：持续交付（自动产出可发布包）和持续部署（自动发布上线）。

**2. workflow 文件放在哪？不放在那儿会怎样？**

`.github/workflows/`，且必须是 `.yml`。放错地方 GitHub 不会识别，Actions 页面没有任何记录。

**3. 为什么 workflow 里写 `FROM nginx` 不需要镜像代理？**

runner 跑在 GitHub 机房（国外），访问 docker.io 没有障碍。本地才需要代理。

**4. 为什么几乎每个 workflow 第一步都是 `actions/checkout`？**

runner 是全新的空机器，不会自动拉代码。不 checkout，工作目录里只有 `.` 和 `..`。

**5. `${{ secrets.GITHUB_TOKEN }}` 需要自己配吗？**

不需要。GitHub 每次运行自动生成临时令牌，但要配 `permissions: packages: write` 才能推镜像。

---

## 十二、一句话总结

> **CI/CD 不是"自动化工具"，是把"构建方式"从人的记忆里，搬进了可版本化的文件里。**
> 人的记忆会漏，文件不会。
