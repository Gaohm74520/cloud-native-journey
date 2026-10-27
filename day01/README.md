# 第 01 课 · 容器是什么

> 本文是《从零学云原生》系列第 1 篇。
> 环境：VMware Workstation + RHEL 10 + podman。docker.io 在国内不可达，镜像走 `docker.m.daocloud.io` 代理。

**日期**：2026-10-26 ｜ **耗时**：约 1.5 小时（其中约 1 小时在搭环境）

---

## 今天做出来的东西

- ✅ 浏览器访问 `http://192.168.1.129:8080`，看到 nginx 默认页
- ✅ 把首页改成自己的文字，刷新后生效
- ✅ 删容器重建，内容变回 "Welcome to nginx!"

（截图 1：浏览器里的 nginx 页面）




（截图 2：改成自己的文字之后）


（截图 3：删容器重建，内容变回默认页）

---

## 环境准备（一次性，踩了四个坑）

### 1. RHEL 未注册，没有任何软件源

报错：`在 /etc/yum.repos.d 中没有被启用的仓库`。

RHEL 不注册就不给源。用安装光盘 ISO 做本地源，不联网、不需要账号：

```bash
mkdir -p /mnt/iso
mount /dev/sr0 /mnt/iso
vi /etc/yum.repos.d/dvd.repo
```

```ini
[BaseOS]
name=RHEL 10 DVD - BaseOS
baseurl=file:///mnt/iso/BaseOS/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release

[AppStream]
name=RHEL 10 DVD - AppStream
baseurl=file:///mnt/iso/AppStream/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
```

```bash
dnf clean all && dnf repolist
dnf install -y podman
```

### 2. docker.io 在国内不可达

报错：`dial tcp 202.160.130.52:443: connect: connection refused`。

换国内镜像代理即可：

```bash
podman run -d --name web -p 8080:80 docker.m.daocloud.io/library/nginx
```

### 3. 虚拟机起不来（VMware 锁文件残留）

VMware 提示 `This virtual machine appears to be in use`，Take Ownership 也失败。

原因是上次没正常关机，残留了锁目录。关掉 VMware 后删除：

```text
E:\cloud_computing\redhat101\Red Hat Enterprise Linux 10 64-bit.vmx.lck
```

### 4. 装 podman 别忘了 alias

```bash
echo "alias docker=podman" >> ~/.bashrc
source ~/.bashrc
```

---

## 三行笔记

- **我做了什么**：删掉后缀为 `.lck` 的文件夹，解决了虚拟机起不来；用 DVD ISO 做了本地软件源，解决了下载不了 podman 的问题；用国内镜像代理绕开了 docker.io；最后在浏览器里跑起了第一个 nginx 容器。
- **卡在哪**：① VM 起不来（`.lck` 锁）② RHEL 没有任何源 ③ docker.io 连不上 ④ `--name` 多了空格 ⑤ `rm` 少了 `podman`
- **下次先做什么**：第 2 课 Volume

---

## 我能回答的问题（面试原题）

**1. 容器和虚拟机的本质区别是什么？**

虚拟机虚拟出硬件，要在上面装完整操作系统；容器直接复用宿主机的内核，只是被 namespace 隔离视野、被 cgroup 限制资源的一个进程。

**2. 镜像和容器是什么关系？**

容器 = 镜像 + 一层可写层 + 一个进程。镜像是只读的分层文件系统，一个镜像可以起多个容器。

**3. 为什么容器启动是秒级，虚拟机要几十秒？**

容器不需要启动操作系统、不需要引导内核，只是启动一个进程；虚拟机要先引导一个完整的 OS。

**4. 我在容器里改的文件，为什么删掉容器就没了？**

改动写在可写层，可写层和容器绑定生命周期，容器删了就一起删了。镜像是只读的，从来没变。

---

## 今天踩的坑（这些比命令值钱）

1. **VMware 锁文件残留** → 删 `虚拟机名.vmx.lck` 文件夹
2. **RHEL 未注册没有任何软件源** → 用 DVD ISO 做本地源
3. **docker.io 在国内不可达** → 用 `docker.m.daocloud.io/library/...` 代理
4. **命令细节**
   - `-- name` 中间多空格 = 选项结束符，整个命令含义全变
   - `rm -f web` 少了 `podman`，`rm` 是删文件的
   - `/usr` 不是 `/user`，`index.html` 不是 `index/html`
5. **短名会触发交互** → 写完整镜像名，避免 podman 弹出 `Please select an image`

---

## 一句话总结

> 容器删掉，可写层一起没，改动消失。镜像永远只读。
> 下一课 Volume 就是来解决这个的。
