# 第 02 课 · 数据持久化（Volume）

> 本文是《从零学云原生》系列第 2 篇。
> 环境：RHEL 10 + podman，镜像走 `docker.m.daocloud.io` 代理。

**日期**：2026-10-27 ｜ **耗时**：约 3 小时（含环境折腾）

---

## 上一课留下的问题

第 1 课最后，我改了容器里的首页，`podman rm` 删掉容器重新跑，改动消失了。

如果数据必须活下来，它应该存在哪？

答案：**存在容器外面。** 容器是干活的工人，不是存钱的保险箱。

---

## 两种“柜子”

| | **Volume（卷）** | **Bind mount（绑定挂载）** |
|---|---|---|
| 谁管 | 容器引擎管 | 你自己管 |
| 位置 | `/var/lib/containers/storage/volumes/` | 你指定的任意宿主机路径 |
| 命令 | `-v 卷名:/容器路径` | `-v /宿主机路径:/容器路径` |
| 适合 | **数据**（数据库、上传文件、日志） | **代码和配置** |
| 可移植 | 好 | 差，依赖宿主机目录结构 |

**一句话记法：卷存数据，绑定挂载放代码。**

---

## 实验 1：bind mount

```bash
mkdir -p /data/html
echo '<html><head><meta charset="utf-8"></head><body><h1>数据活下来了</h1></body></html>' > /data/html/index.html
```

```bash
podman run -d --name web2 -p 8081:80 -v /data/html:/usr/share/nginx/html:Z docker.m.daocloud.io/library/nginx
curl http://localhost:8081
```

**删掉容器重建：**

```bash
podman rm -f web2
podman run -d --name web2 -p 8081:80 -v /data/html:/usr/share/nginx/html:Z docker.m.daocloud.io/library/nginx
curl http://localhost:8081
```

内容还在。**昨天删容器数据消失，今天删容器数据还在，差别只在 `-v` 那一小段。**

再在宿主机上改文件：

```bash
echo '<html><head><meta charset="utf-8"></head><body><h1>我在宿主机改的</h1></body></html>' > /data/html/index.html
curl http://localhost:8081
```

容器立刻跟着变——**它们看的不是两份拷贝，是同一个目录。**

---

## 实验 2：volume

```bash
podman volume create webdata
podman run -d --name web3 -p 8082:80 -v webdata:/usr/share/nginx/html docker.m.daocloud.io/library/nginx
curl -i http://localhost:8082
```

**这里有个意外**：我原以为会看到 403（卷是空的），实际返回的是 200 和 nginx 默认页。

查了才发现：**命名卷有“初始化复制”行为**——卷为空且挂载点下镜像有内容时，引擎会先把镜像里的内容复制进卷。

证据在这里，`ls` 输出：

```text
-rw-r--r--. 1 root root 497 10月21日 22:24 50x.html
-rw-r--r--. 1 root root  26 10月27日 09:46 index.html
```

`50x.html` 是 nginx 镜像自带的错误页，日期 **10月21日** 就是镜像构建时间——它是从镜像复制进来的，连时间戳都保留了。而 `index.html` 是 26 字节、今早 09:46，是我刚写进去的。

**一个目录里，两种来源的文件，时间戳把它们区分开了。**

### 往卷里写数据

```bash
podman run --rm -v webdata:/html docker.m.daocloud.io/library/nginx sh -c 'echo "<h1>data-from-volume</h1>" > /html/index.html'
curl http://localhost:8082
```

### 删了重建，验证持久化

```bash
podman rm -f web3
podman run -d --name web3 -p 8082:80 -v webdata:/usr/share/nginx/html docker.m.daocloud.io/library/nginx
curl http://localhost:8082
```

仍然是 `data-from-volume`。

### 看卷的真身

```bash
podman volume inspect webdata | grep Mountpoint
```

```text
"Mountpoint": "/var/lib/containers/storage/volumes/webdata/_data"
```

```bash
ls -l /var/lib/containers/storage/volumes/webdata/_data/
cat /var/lib/containers/storage/volumes/webdata/_data/index.html
```

**数据就在磁盘上，不在容器里。**

---

## SELinux：RHEL 上必踩的坑

故意不加 `:Z` 跑一次：

```bash
mkdir -p /data/html2
echo '<h1>no-Z</h1>' > /data/html2/index.html
podman run -d --name web4 -p 8083:80 -v /data/html2:/usr/share/nginx/html docker.m.daocloud.io/library/nginx
curl -i http://localhost:8083
```

结果：**403 Forbidden**。

看日志：

```bash
podman logs web4
```

```text
open() "/usr/share/nginx/html/index.html" failed (13: Permission denied)
```

**注意：这不是权限位问题，`chmod 777` 也没用。** 看标签：

```bash
ls -Zd /data/html2
```

```text
... unconfined_u:object_r:default_t:s0 /data/html2
```

`default_t` 是普通文件类型。容器进程的类型是 `container_t`，读不了它。

加上 `:Z` 之后：

```bash
podman run -d --name web4 -p 8083:80 -v /data/html2:/usr/share/nginx/html:Z docker.m.daocloud.io/library/nginx
ls -Zd /data/html2
```

```text
... system_u:object_r:container_file_t:s0 /data/html2
```

标签从 `default_t` 变成 `container_file_t`，访问恢复 200。

**一句话**：`:Z` 不是"加个保险"，它是**真的在改文件的安全标签**。

---

## 403 有两种，日志不一样

| 日志内容 | 原因 |
|---|---|
| `Permission denied` | SELinux 拦的，缺 `:Z` |
| `directory index of "..." is forbidden` | 目录是空的，没有 index.html |

**同样是 403，原因完全不同。所以第一件事永远是看日志，不是猜。**

---

## 三行笔记

- **我做了什么**：用 bind mount 和 volume 两种方式把数据挂到容器外，验证了删容器重建数据不丢；顺手复现并解决了 SELinux 导致的 403。
- **卡在哪**：① 多行命令粘贴断了，`-v` 丢失导致挂载没生效 ② heredoc 卡住，`E0F` 把零写成 O ③ 中文页面乱码，缺 `<meta charset="utf-8">` ④ 忘了加 `:Z`
- **下次先做什么**：第 3 课 Dockerfile

---

## 面试题

**1. 数据存在容器里和存在卷里，本质区别是什么？**

容器里的数据写在可写层，可写层的生命周期等于容器，容器删了数据就没了。卷存在宿主机上，生命周期独立于容器，容器删多少次它都在。

**2. 什么情况用卷、什么情况用绑定挂载？**

卷存数据（数据库、上传文件、日志），因为归引擎管理、可移植、好备份。绑定挂载放代码和配置，因为能直接改宿主机文件，容器立刻看到，不用重建镜像。

**3. RHEL 上不加 `:Z` 会怎样？**

目录的 SELinux 标签是 `default_t`，容器进程类型是 `container_t`，读不到，返回 403，日志里是 `Permission denied`。加 `:Z` 会把标签改成 `container_file_t`。

**4. 卷挂到 `/usr/share/nginx/html` 后，原来的 Welcome 页面为什么不见了？**

挂载会**遮盖**镜像同路径下的内容，容器看到的只有挂载源。镜像本身没变，只是被挡住了。

---

## 今天踩的坑

1. **多行命令粘贴会断** → `-v` 丢失，容器建出来了但没挂载。改成一行。
2. **heredoc 要精确匹配结束符** → 把 `EOF` 敲成 `E0F`（零），永远结束不了，后面所有内容都被当成文件内容写进去。
3. **中文页面必须带 `<meta charset="utf-8">`** → 否则浏览器按 GBK 猜，UTF-8 中文变乱码。
4. **`:Z` 加在 `-v` 值的最末尾**，用英文冒号，分段是 `宿主机路径:容器路径:选项`。

---

## 一句话总结

> 容器可以随便删，因为它本来就不负责存东西。
> **“容器是无状态的”这句话，今天有了实感。**
