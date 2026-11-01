# 第 05 课 · Compose：从手敲六条命令到一行编排

> 本文是《从零学云原生》系列第 5 篇。
> 环境：RHEL 10 + podman 5.8.2 + podman-compose 1.6.0，镜像走 `docker.m.daocloud.io` 代理。

**日期**：2026-11-01 ｜ **耗时**：约 2 小时

---

## 引子：第 4 课留下的痛

上一课要让两个容器互相访问，我敲了三步：

```bash
podman network create mynet
podman run -d --name app1 --network mynet ...
podman run -d --name app2 --network mynet ...
```

三个容器六条命令，五个容器十几条，**还容易漏参数**。

真实项目里一个应用通常是：Web + 数据库 + 缓存 + 反向代理。

**Compose 解决的就是这件事：把整套写进一个 YAML，一条命令拉起。**

---

## 一、podman 和 podman-compose 是什么关系

一开始我以为是两个平级的东西，其实不是，是**上下级**：

```
你
 └─ podman-compose   ← 读图纸（YAML），发指令
      └─ podman      ← 真正干活（拉镜像、起容器、建网络）
           └─ crun   ← 真正创建进程
                └─ Linux 内核（namespace / cgroup）
```

**类比**：

- `podman` = **工人**，会砌墙、会装门
- `podman-compose` = **包工头**，自己不砌墙，拿着图纸指挥工人

所以 **删了 podman，podman-compose 什么都干不了**。

验证方法：

```bash
which podman-compose
head -1 $(which podman-compose)
```

第二行会输出类似 `#!/usr/bin/python3`——**它就是个 Python 脚本**。

安装方式也印证了这点：它不是 `dnf install` 装的，是 `pip3 install` 装的。

> **一句话：podman 管一个容器；podman-compose 管一组容器。**

---

## 二、写第一个 compose 文件

目录结构：

```
/data/compose-demo/
├── docker-compose.yml
└── html/
    └── index.html
```

`docker-compose.yml`：

```yaml
version: "3"

services:
  web:
    image: docker.m.daocloud.io/library/nginx
    container_name: c_web
    ports:
      - "8090:80"
    volumes:
      - ./html:/usr/share/nginx/html:Z
    depends_on:
      - cache
    networks:
      - appnet

  cache:
    image: docker.m.daocloud.io/library/redis
    container_name: c_cache
    volumes:
      - redis-data:/data
    networks:
      - appnet

networks:
  appnet:
    driver: bridge

volumes:
  redis-data:
```

### 逐段解释

| 字段 | 作用 | 等价的手工写法 |
|---|---|---|
| `services` | 每个子项是一个容器 | 每次 `podman run` |
| `image` | 用哪个镜像 | 命令最后那个镜像名 |
| `container_name` | 容器名 | `--name` |
| `ports` | 端口映射 | `-p` |
| `volumes` | 挂载 | `-v` |
| `depends_on` | 启动顺序 | 无（手工要自己控制） |
| `networks`（顶层） | 声明要创建的网络 | `podman network create` |
| `volumes`（顶层） | 声明要创建的卷 | `podman volume create` |

**注意 `./html`**：相对路径，相对于 **compose 文件所在目录**，不是你执行命令时所在的目录。

---

## 三、"一条命令"到底做了什么

```bash
podman-compose up -d
```

我一开始以为它是"把文件里的命令挨个执行一遍"。**不是。**

区别在于两种范式：

| | 命令式（imperative） | 声明式（declarative） |
|---|---|---|
| 你写的是 | **步骤**：先建网络、再起 A、再起 B | **结果**：我要一个网络、两个容器、一个卷 |
| 工具做的是 | 照着一步步执行 | 算出差多少，只补缺的 |
| 例子 | `podman network create` + `run` ×2 | `podman-compose up -d` |

**`up -d` 实际做的事：**

1. 读 YAML，得到「期望状态」
2. 查「实际状态」（现在有哪些容器/网络/卷）
3. **对比差异**
4. 只做缺的部分

所以它可以**反复执行**：

```bash
podman-compose up -d     # 第一次：拉镜像、建网络，慢
podman-compose up -d     # 第二次：几乎瞬间，发现无事可做
```

**这个性质叫「幂等」（idempotent）：执行一次和执行十次，结果一样。**

> **这就是 IaC（基础设施即代码）的核心：描述结果，不描述步骤。**

---

## 四、验证服务名能解析

第 4 课手工验证过的事，现在被自动做了。

```bash
podman exec c_web cat /etc/resolv.conf
```

```text
nameserver 10.89.1.1
```

DNS 跑在网络网关地址上。

真正验证解析：

```bash
podman run --rm --network compose-demo_appnet \
  docker.m.daocloud.io/library/busybox nslookup cache
```

```text
Server:   10.89.1.1
Address:  10.89.1.1:53

Non-authoritative answer:
Name:    cache.dns.podman
Address: 10.89.1.2
```

**`cache` 被解析成 `10.89.1.2`。**

后面还会有一行 `can't find cache.localdomain: NXDOMAIN`——**这是噪音，不是错误**。因为 `/etc/resolv.conf` 里有 `search dns.podman localdomain`，nslookup 拿两个后缀各试了一次，第一个成功，第二个失败。

---

## 五、`down` 和 `down -v`：最贵的一个字母

```bash
podman-compose down
```

**停容器 → 删容器 → 删网络。卷保留。**

```bash
podman-compose down -v
```

**多加一个 `-v`，卷也删了，数据一起没。**

实验记录（`podman-compose down` 的输出）：

```text
c_web
c_cache
compose-demo_appnet        ← 网络被删
```

**注意：没有 `compose-demo_redis-data`。** 卷还在。

再执行 `down -v`：

```text
compose-demo_redis-data    ← 卷被删了
```

（前面会有一堆 `Error: no container ... found`——因为容器已经删过了，它按清单找不着，报错但继续执行，最后照样把卷删了。）

> **真实事故：** 生产上手滑多打一个 `-v`，数据库就没了。
> `down` = 拆房子，家具留着；`down -v` = 连家具一起扔。

**一个观察**：满屏 `Error` 不代表没生效。这类"尽力而为"的脚本会边报错边往下走，要看它**最后做了什么**，不是看有没有红字。

---

## 六、多项目怎么隔离

不同的 compose 文件放在**不同目录**，就自动隔离了。

证据是名字前缀：

```
compose-demo_appnet
compose-demo_redis-data
```

那个 `compose-demo_` 就是**项目名**，默认取目录名。

想自定义：

```bash
podman-compose -p myproj up -d
```

之后网络和卷就变成 `myproj_appnet`、`myproj_redis-data`——**同一个文件，换一个项目名，就是另一套独立环境。**

所以同一台机器上跑十个项目也不会打架。

---

## 七、今天踩的 5 个坑

**1. 文件名拼错，报"找不到配置文件"**

我敲了 `vi doceker-compose.yml`（`docker` 拼成了 `doceker`），然后：

```text
CRITICAL: podman_compose: no compose.yaml, docker-compose.yml ... file found
```

**文件名拼错不会报"拼错"，只会报"找不到"。** 遇到这类错误，第一步永远是 `ls` 看实际叫什么。

**2. `podman up -d` 少了 `-compose`**

`up` 属于 `podman-compose`，不属于 `podman`。两个不同的命令。

**3. HTML 多了个 `<`，页面白屏**

我写的是：

```html
<h1><Compose 跑起来了</h1>
```

多了一个 `<`。浏览器看到 `<Compose 跑起来了</h1>`，把它当成**未知标签**，一路吃到下一个 `>`——把文字全吃掉了，所以页面一片空白。

而 `curl` 只输出原始文本，看起来"有内容"。

> **文本正确 ≠ 渲染正确。** curl 是给机器看的，浏览器才是给人看的。
> 网页白屏但 curl 有输出，第一个怀疑对象就是 HTML 结构。

**4. 我以为 `/etc/hosts` 里会有 `cache`**

没有。因为 podman 5.x **用内置 DNS（aardvark-dns），不再往 hosts 写**。

验证服务名解析，要看 `resolv.conf` 和 `nslookup`，不是看 `hosts`。

**5. 浏览器 `localhost:8090` 打不开**

在虚拟机里 `curl localhost:8090` 通，Windows 浏览器 `localhost:8090` 拒绝连接。

**因为 `localhost` 指的是"发起请求的那个程序所在的机器"。**

---

## 八、我自己推导出来的一件事：三层 localhost

现在有三层嵌套，每一层都有自己的 `localhost`：

```
Windows（浏览器）
  └── localhost = Windows
        └── 虚拟机 RHEL 10
              └── localhost = 虚拟机
                    └── 容器
                          └── localhost = 容器
```

| 在哪里敲 | `localhost` 指谁 | 访问 8090 的结果 |
|---|---|---|
| 容器里 | 容器自己 | ❌ |
| 虚拟机里 | 虚拟机 | ✅（podman 在 8090 监听） |
| Windows 浏览器 | Windows | ❌ |

**`localhost` 永远指「发起请求的那个程序所在的机器」。**

第 4 课学的是"容器里的 localhost 是容器自己"，今天这句往上一层——**换个位置，localhost 换个人**。

所以 Windows 里要访问，得用虚拟机的 IP：`http://192.168.191.129:8090`。

---

## 九、面试题

**1. Compose 解决了什么问题？**

把多个容器的定义（镜像、端口、卷、网络、依赖）写进一个 YAML，一条命令拉起整套，环境可以版本化、可重复部署。

**2. `podman` 和 `podman-compose` 什么关系？**

compose 是编排层，本身不操作容器，而是读 YAML 后调用 podman 命令。podman 才是真正的容器引擎。

**3. `up -d` 为什么可以反复执行？**

因为它是声明式的：读期望状态、查实际状态、只补差异。幂等。

**4. `down` 和 `down -v` 的区别？**

`down` 删容器和网络、保留卷；`down -v` 连卷一起删，**数据会丢**。

**5. `depends_on` 保证了什么？没保证什么？**

保证启动**顺序**；不保证服务**已经就绪**（能接受连接）。真实项目要用健康检查或重试。

---

## 十、一句话总结

> **podman 是工人，compose 是工头。**
> 你不再描述"怎么一步步做"，而是描述"最后要长什么样"——这就是 IaC 的起点。
