# 第 03 课 · Dockerfile：自己造一个镜像

> 本文是《从零学云原生》系列第 3 篇。
> 环境：RHEL 10 + podman，镜像走 `docker.m.daocloud.io` 代理。

**日期**：2026-10-27 ｜ **耗时**：约 1.5 小时

---

## 引子：2 秒 还是 5 分钟？

改了一行代码，重新构建镜像。为什么有的项目 2 秒就完，有的要 5 分钟？

差的不是电脑性能，是**镜像分层的顺序**。

---

## 六条核心指令

| 指令 | 什么时候执行 | 作用 |
|---|---|---|
| `FROM` | 构建时 | 从哪个基础镜像开始 |
| `COPY` | 构建时 | 把宿主机文件复制进镜像 |
| `RUN` | **构建时** | 装软件、编译，结果固化进镜像层 |
| `EXPOSE` | 仅声明 | 说明镜像使用哪个端口 |
| `CMD` | **容器启动时** | 默认执行的命令 |
| `ENV` | 构建时 | 设置环境变量 |

**最容易混的一对**：`RUN` 是造镜像时跑的，`CMD` 是容器跑起来时跑的。

---

## 实验 1：造出第一个镜像

```bash
mkdir -p /data/myapp && cd /data/myapp
echo '<html><head><meta charset="utf-8"></head><body><h1>这是我自己造的镜像</h1></body></html>' > index.html
```

`Dockerfile`：

```dockerfile
FROM docker.m.daocloud.io/library/nginx
LABEL description="my first custom image"
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

构建并运行：

```bash
podman build -t myweb:v1 .
podman run -d --name myweb1 -p 8084:80 myweb:v1
curl http://localhost:8084
```

**这个镜像里有我自己的东西，不是从网上拉的。**

看它的层：

```bash
podman history myweb:v1
```

下面是 nginx 的几层，上面两三层是我加的。镜像是分层叠起来的——这次是实物。

---

## 实验 2：缓存命中

在 `COPY` **前面**加一个耗时步骤：

```dockerfile
FROM docker.m.daocloud.io/library/nginx
RUN sleep 5
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

第一次构建，`sleep 5` 真的停 5 秒：

```bash
podman build -t myweb:v2 .
```

然后改内容，再构建：

```bash
echo '<html><head><meta charset="utf-8"></head><body><h1>改了一行</h1></body></html>' > index.html
podman build -t myweb:v3 .
```

**这次瞬间完成**，输出里有：

```text
STEP 2/4: RUN sleep 5
--> Using cache
```

`sleep 5` 命中了缓存，没重跑。

原因：只改了 `index.html`，而它只被 `COPY` 用到，`COPY` 在 `RUN` 后面——前面的层完全没变，直接复用。

---

## 实验 3：顺序反过来，缓存全废

```dockerfile
FROM docker.m.daocloud.io/library/nginx
COPY index.html /usr/share/nginx/html/index.html
RUN sleep 5
EXPOSE 80
```

```bash
echo '<html><head><meta charset="utf-8"></head><body><h1>又改了一行</h1></body></html>' > index.html
podman build -t myweb:v4 .
```

**这次又要等 5 秒。**

因为 `COPY` 在前面：文件一变，`COPY` 层失效，后面的所有层跟着失效。

### 本课最重要的一句

> **不常变的东西放前面，常变的东西放后面。**

真实项目里的写法：

```dockerfile
COPY requirements.txt .                 # 依赖，很少变
RUN pip install -r requirements.txt     # 很慢，但能长期命中缓存
COPY . .                                # 代码，天天变
```

代码改一百次，`pip install` 只跑一次。**这就是 2 秒和 5 分钟的区别。**

---

## 三个版本同时运行

```bash
podman run -d --name myweb1 -p 8084:80 localhost/myweb:v1
podman run -d --name myweb3 -p 8085:80 localhost/myweb:v3
podman run -d --name myweb4 -p 8086:80 localhost/myweb:v4
```

浏览器分别打开 8084 / 8085 / 8086，三个页面同时存在，互不干扰。

**回滚就是这么做**：新版本出问题，用旧镜像再起一个容器，几十秒退回。传统部署要重装、改配置、承担人为失误风险。

---

## 我犯的一个"错误"：v2 显示的是旧内容

构建完 `v2` 之后，我发现访问 `v2` 起的容器，页面还是第一版的文字。当时以为是镜像出错了。

查了才明白：**`podman build -t myweb:v2 .` 执行时，`index.html` 还没改。**

`echo ... > index.html` 那一步，是在 `v2` 构建**完成之后**才执行的。所以：

- `v1` = 旧内容
- `v2` = **旧内容** + `RUN sleep 5`（改的是 Dockerfile，不是页面）
- `v3` = 新内容 + `RUN sleep 5`
- `v4` = 再次修改后的内容

不是镜像坏了，是**镜像的时间点被我记错了**。

### 镜像是快照

> **镜像在 `build` 的那一瞬间就冻结了。之后改宿主机上的任何文件，已造好的镜像都不会变。**

`COPY` 做的事是**复制一份内容进镜像层**，复制的是当时的字节。之后镜像里那份拷贝和宿主机文件再无关系。

### 和绑定挂载正好相反

| | `COPY`（构建时） | `-v` 绑定挂载（运行时） |
|---|---|---|
| 本质 | **复制一份**进镜像 | **引用同一个目录** |
| 改宿主机源文件 | 镜像**不变** | 容器**立刻变** |
| 生效时机 | 下次 `build` | 立刻 |

同一个文件，两种关系，两种行为。这就是镜像和挂载的根本区别。

### 生产上的铁律

正因为镜像是不可变的快照：

> **永远不要进容器里改文件。**

改的东西容器一删就没了；线上运行的容器和镜像内容对不上，下次重启变回去，还查不出原因。

正确做法：改代码 → 重新 build → 部署新镜像。配置用环境变量或挂载，不写死在镜像里。

---

## CMD 和 ENTRYPOINT

| | `CMD` | `ENTRYPOINT` |
|---|---|---|
| 作用 | 默认启动命令 | 固定启动命令 |
| 被 `podman run 镜像 命令` 覆盖 | **会** | **不会**，命令变成它的参数 |
| 用途 | 提供默认值 | 定义"这个镜像就是干这件事的" |

```dockerfile
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
```

用户执行 `podman run 镜像 -v`，实际跑的是 `nginx -v`。

**面试标准答法**：CMD 会被 `run` 后面的命令覆盖，ENTRYPOINT 不会，只会追加参数。

---

## 今天踩的坑

1. **`podman build -t myweb:v3` 漏了最后的 `.`** → `no context directory and no Containerfile specified`
2. **`FROM` 忘了写代理地址** → 构建时去连 docker.io，直接失败
3. **短名触发交互** → `podman run myweb:v4` 弹菜单问你去哪个仓库找。自己构建的镜像一律写 `localhost/myweb:v4`
4. **容器名被占** → `container name "myweb4" is already in use`。`myweb4` 这个名字属于**容器**，不属于镜像，先 `podman rm -f myweb4`
5. **构建了新镜像，但没跑新容器** → 浏览器看到的还是旧页面。**构建镜像 ≠ 更新容器**，这是生产上"改了没生效"的头号原因

---

## 面试题

**1. `RUN` 和 `CMD` 的区别？**

`RUN` 在构建镜像时执行，结果固化进镜像层（装软件、编译）；`CMD` 是容器启动时的默认命令，会被 `podman run` 后面的命令覆盖。

**2. `podman build -t myweb:v1 .` 最后那个 `.` 是什么？**

构建上下文，告诉 podman 把哪个目录的文件发给构建器。漏了会报 `no context directory`。

**3. 为什么 `COPY requirements.txt` 要写在 `COPY . .` 前面？**

依赖很少变、代码天天变。依赖装在前面，改代码不会让依赖层失效，能长期命中缓存。写反了每次改代码都要重装依赖。

**4. 镜像分层节省了什么？**

存储（多个镜像共用底层，v1/v2/v3 共用 nginx 那么大的底层）和时间（未变的层直接复用缓存，不重跑）。

---

## 一句话总结

> 镜像是**快照**，不是**引用**。
> 想让它变，只能重新 build；build 想快，就把不常变的东西放前面。
