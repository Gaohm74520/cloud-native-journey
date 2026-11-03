# 第 07 课 · Git：从网页上传到命令行版本控制

> 本文是《从零学云原生》系列第 7 篇。
> 环境：RHEL 10 + git 2.4x

**日期**：2026-11-03 ｜ **耗时**：约 2 小时

---

## 引子：为什么必须补这一课

前面六课的笔记，我都是用 GitHub **网页上传**的。

能解决"存起来"，但解决不了三件事：

**① 改坏了想回退**

改了 `nginx.conf`，网站 502。想回到一小时前——但网页上传只保留**最后一次**的样子。

**② 不知道为什么改**

三个月前有人把端口从 8080 改成 8090，你翻遍记录也找不到原因。

**③ 两个人改同一个文件**

复制来复制去，最后不知道谁覆盖了谁。

> 网页上传 = 存最终版。
> Git = 记录每一次修改，**以及为什么改**。

而且下一课要做 CI/CD——**流水线是靠 `git push` 触发的**，不会 Git 就进不去。

---

## 一、核心模型：三个区域

**这是 Git 最容易晕的地方，先建立这个模型。**

```
工作区                暂存区               仓库
(你编辑的文件)  --add-->  (准备提交)  --commit-->  (历史记录)
```

| 区域 | 是什么 | 命令 |
|---|---|---|
| **工作区** worktree | 你正在编辑的文件 | 直接改文件 |
| **暂存区** stage | "我打算提交这些" | `git add` |
| **仓库** repo | 已经存进历史 | `git commit` |

### 为什么要中间这一层

因为一次提交应该是**一个完整的小改动**。

你改了 5 个文件，其中 2 个是实验性的、不该提交。暂存区就是让你**挑**。

**用超市理解最清楚：**

| Git | 超市 |
|---|---|
| 工作区 | 货架上的商品 |
| 暂存区 | 购物车 |
| `git add` | 把商品放进购物车 |
| `git commit` | **结账**，存进小票（历史） |

---

## 二、实验：从零建一个仓库

```bash
mkdir -p /data/git-demo && cd /data/git-demo
git init
```

第一次用**必须配身份**，否则 commit 会报 `Author identity unknown`：

```bash
git config --global user.name "你的名字"
git config --global user.email "你的邮箱"
git config --global init.defaultBranch main
```

### 三个阶段，看状态变化

```bash
echo 第一行内容 > a.txt
git status
```

```text
未跟踪的文件:
        a.txt
```

**`Untracked` = Git 看见了它，但没在管它。**

```bash
git add a.txt
git status
```

```text
要提交的变更:
        新文件:   a.txt
```

```bash
git commit -m "feat: 添加第一个文件"
git log --oneline
```

```text
a75c9f3 (HEAD -> main) feat: 添加第一个文件
```

**`HEAD -> main`** = 你站在 main 分支上，而 main 指向这次提交。

> **`HEAD` 是"你当前所在的位置"**——Git 里最重要的指针。

---

## 三、提交信息怎么写

**最容易忽视、但最影响别人对你评价的细节。**

| 差的 | 好的 |
|---|---|
| `update` | `docs: 补充第07课 Git 笔记` |
| `修改` | `fix: 修正 fstab 挂载点写错导致重启失败` |
| `123` | `feat: 增加 nginx 反向代理配置` |

常用前缀：

| 前缀 | 用于 |
|---|---|
| `feat:` | 新功能 |
| `fix:` | 修 bug |
| `docs:` | 文档 |
| `refactor:` | 重构 |
| `chore:` | 杂务 |

**原则：三个月后的你，看这句话能明白为什么改。**

> 顺带说：GitHub 的 Copilot 会自动生成提交信息，但它的产出大致是 `Revise README for...`——通顺，但**零信息量**。别偷这个懒。

---

## 四、回退：三种 restore 的区别

### 场景 1：改了文件，但还没 add

```bash
echo 第二行 >> a.txt
git status
```

```text
尚未暂存的变更:
        修改:   a.txt
```

看看改了什么：

```bash
git diff
```

**这是提交前最该做的事**——先看自己改了什么。

后悔了：

```bash
git restore a.txt
```

**`cat a.txt` 只剩第一行，第二行没了。**

> `restore` 丢弃的是**工作区**的修改，执行后**找不回来**。

### 场景 2：add 了，但不想提交

```bash
echo 第三行 >> a.txt
git add a.txt
git restore --staged a.txt
git status
```

```text
尚未暂存的变更:
        修改:   a.txt
```

**注意：文件内容没变，第三行还在。**

### 这是我今天最大的困惑

> 我当时的想法：取消了暂存，那内容不也应该撤销吗？为什么 `cat a.txt` 还有第三行？

**答案：取消暂存 ≠ 取消修改。**

回到超市比喻：

- `add` = 把商品放进购物车
- `restore --staged` = **把商品从购物车拿回货架**

**商品还在货架上，只是不在车里了。**

| 命令 | 管哪一层 | 后果 |
|---|---|---|
| `git restore 文件` | 工作区 | **改动消失** |
| `git restore --staged 文件` | 暂存区 | 改动还在，只是没暂存 |
| `git reset --hard HEAD` | 全部 | **所有未提交改动消失**（最危险） |

### 状态对照表

| 状态 | `git status` | 含义 | 消除方法 |
|---|---|---|---|
| 已暂存 | 要提交的变更 | 在购物车里 | `restore --staged` |
| 未暂存 | 尚未暂存的变更 | 在货架上 | `restore` |
| 已提交 | 不显示 | 进历史了 | 只能回退提交 |

---

## 五、分支：我一开始理解错了

### 我的错误理解

> "分支 main 是不是相当于一个缓存区？如果有多个 main，那是不是多个缓存区？"

**不是。**

- **暂存区只有一个，全局共享**
- **分支有无数个，而且分支不是"存储空间"**

### 分支是什么

**分支 = 一个指向某次提交的指针。**

```
a75c9f3  ← main 也 ← HEAD
```

`main` 只是贴在 `a75c9f3` 上的一个**标签**。`HEAD` 表示"我现在站在 main 上"。

新建 `dev`：

```
a75c9f3  ← main
         ← dev  ← HEAD
```

两个标签贴在同一个提交上。在 dev 上提交后：

```
a75c9f3 ← main
    └── f9550bc ← dev ← HEAD
```

**dev 往前走了一步，main 停在原地。**

### 关键：切换分支时，文件会"变"

这才是分支的实感。

```bash
git checkout main
cat a.txt        # 只有第一行
git checkout dev
cat a.txt        # 第一行 + dev的内容
```

**我没有删任何东西，文件自己"变"了。**

> 分支不是"复制了一份文件"，而是"同一个文件在不同时间线的不同样子"。
> **切换分支 = 跳到另一条时间线。**

### 一个仓库只有一个 main

分支名唯一，所以"多个 main"不成立。但可以有任意多个**其他名字**：`dev`、`feature-x`、`hotfix`……

---

## 六、合并：fast-forward

```bash
git checkout main
git merge dev
git log --oneline --graph
```

```text
* f9550bc (HEAD -> main) feat:dev 分支添加内容
* a75c9f3 feat:添加第一个文件
```

**一条直线。**

因为 main 从头到尾没动过，dev 只是往前走了一步——所以合并就是**把 main 的标签挪到 dev 的位置**，不需要真的合并。

这叫 **快进合并（fast-forward）**。

### 三种合并情况

| 情况 | 结果 | 名字 |
|---|---|---|
| main 没动过 | 挪标签 | 快进 fast-forward |
| 两边都改过但不冲突 | 自动生成合并提交 | 三方合并 3-way |
| 改到同一行 | 报冲突，手动选 | conflict |

冲突长这样：

```text
<<<<<<< HEAD
你的版本
=======
别人的版本
>>>>>>> dev
```

手动编辑文件，删掉标记，选一个版本（或自己融合），然后 `git add` + `git commit`。

---

## 七、.gitignore：本课最重要的一节

### 我差点犯的错

我之前在笔记里**明文写过 API key**。如果那个文件被提交到公开仓库，这个 key 就等于公开了。

而且**大多数人不知道**：把文件删掉再提交，**历史记录里还在**。别人 `git log` 能翻出来。

> 真实事故：有人把 AWS 密钥推到公开仓库，几小时内被爬虫扫到，开了几十台矿机，账单几万美元。

### 怎么写

```text
# 密钥和密码
*.env
.env*
*.key
*.pem
id_rsa*

# 日志
*.log
logs/

# 临时文件
*.tmp
*.swp
```

### 已经提交了怎么办

```bash
git rm --cached 文件名
```

从 Git 移除（**保留在磁盘上**），再提交一次。

**但对密钥来说，光删文件没用**——历史里还有。**正确做法是立刻去平台吊销，重新生成。**

---

## 八、推到 GitHub

### GitHub 不能用密码了

2021 年之后必须用 **Personal Access Token**：

Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token → 勾 `repo`

**Token 只显示一次**，立刻复制。

### 推送

```bash
git remote add origin https://github.com/用户名/仓库名.git
git push -u origin main
```

```text
Username: 用户名
Password: 粘贴 token（不是密码）
```

`-u` 的意思是"记住对应关系"，以后直接 `git push`。

**输 token 时屏幕不显示任何字符**，粘完直接回车。

---

## 九、今天踩的 5 个坑

### 1. 中文全角引号

```bash
echo "第一行内容" > a.txt
     ↑          ↑    中文引号，bash 不认
```

结果：终端出现 `>` 继续提示符，命令卡住。

**`>` 提示符 = 上一条命令没写完**，最常见就是引号没闭合。

**Linux 里所有符号必须是英文半角**：引号、冒号、分号、括号、管道符。

### 2. 把"预期输出"当成"要执行的命令"

看到我贴的代码块：

```text
On branch main
No commits yet
nothing to commit
```

我以为这是要提交的内容——其实那是"**你应该看到什么**"的示例。

**新手常见的混淆：分不清"命令"和"输出"。**

一般约定：`$` 开头或紧跟提示符的是命令，纯文本块是输出。

### 3. `http://` 少了个 `s`

```bash
git clone http://github.com/...     # ✗
git clone https://github.com/...    # ✓
```

报错 `Recv failure: 连接被对方重置`。

**http 走 80 端口明文，https 走 443 加密。现在所有服务都应该是 https。**

### 4. `git clone` 超时：443 端口连不上

```text
Failed to connect to github.com port 443 after 21132 ms
```

**这不是配置错误，是网络不通。** 而且讽刺的是——**五分钟前我刚 push 成功过**。

GitHub 在国内是"时通时不通"，同一个网络环境下也可能几分钟就变。

### 5. `podman inspect` 取不到 IP（上一课遗留）

```bash
podman inspect xxx --format '{{.NetworkSettings.IPAddress}}'
# 输出空字符串，不报错
```

podman 5.x 里要改成：

```bash
podman inspect xxx --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

**"命令没报错但没输出"，最容易骗人。**

---

## 十、日常工作流：四条命令

```bash
git status                          # ① 我现在什么状态（最常用）
git add .                           # ② 改动加入暂存
git commit -m "feat: 做了什么"      # ③ 提交
git push                            # ④ 推到远程
```

**`git status` 是最好的朋友。** 不确定的时候敲它，它会告诉你下一步该干什么。

---

## 十一、面试题

**1. 工作区、暂存区、仓库分别是什么？**

工作区是正在编辑的文件；暂存区是"准备提交的改动清单"；仓库是历史记录。`add` 把改动从工作区放进暂存区，`commit` 把暂存区存成一条历史。

**2. `git restore` 和 `git restore --staged` 的区别？**

前者丢弃工作区的修改（内容消失）；后者只把文件移出暂存区，**内容不变**。

**3. 分支是什么？**

指向某次提交的指针，代表一条独立的开发时间线。切换分支时工作区文件会变成那个分支的版本。

**4. `.gitignore` 为什么重要？密钥提交了怎么办？**

防止密钥/密码/日志进入仓库。密钥一旦提交，历史里仍在，**必须去平台吊销并重新生成**，光删文件无效。

**5. `git push` 为什么不能用密码？**

GitHub 2021 年起禁用密码认证，必须用 Personal Access Token 或 SSH 密钥。

---

## 十二、一句话总结

> **Git 不存"文件"，存"变化"和"为什么变"。**
> 三个区域是它的骨架，分支是它的时间线。
