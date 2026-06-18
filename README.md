# Podsys Lite

基于 GRUB + Docker 的裸金属自动化部署系统，支持自动安装（Autoinstall）和 LiveOS 网络引导两种模式。专为 GB300 (aarch64) 平台设计。

## 功能

- **自动安装模式**：GRUB 引导 → TFTP 加载内核 → HTTP 拉取 ISO → cloud-init 自动安装到磁盘
- **LiveOS 模式**：GRUB 引导 → TFTP 加载内核 → HTTP 拉取 LiveOS ISO → 完整系统运行在内存中
- 支持 DHCP / TFTP / HTTP 协议栈
- ARM64 引导使用 GRUB（grubaa64.efi，从 Ubuntu ISO 提取），兼容 GB300 UEFI 固件
- 容器化部署，一键启动

## 架构

```
目标机 (GB300)
  │ UEFI PXE 网络启动
  ▼
管理节点 (Docker 容器)
  ├── dnsmasq  ── DHCP (67/udp) + TFTP (69/udp)
  ├── nginx    ── HTTP 文件服务 (5001)
  └── GRUB     ── ARM64 引导菜单 (grubaa64.efi)
```

## 引导流程

```
目标机 UEFI PXE → DHCP 分配 IP，返回 grubaa64.efi →
TFTP 下载 grubaa64.efi → TFTP 下载 grub.cfg → GRUB 菜单 →
  [LiveOS]: TFTP 下载 vmlinuz + initrd → 内核启动 → HTTP 下载 liveos.iso → 挂载 ISO → 加载 squashfs → 进入系统
  [Install]: TFTP 下载 vmlinuz + initrd → 内核启动 → HTTP 下载 ISO → 自动安装到磁盘
```

## 目录结构

```
.
├── docker/                    # Docker 构建文件
│   ├── Dockerfile             # 镜像构建定义
│   ├── dnsmasq.conf           # DHCP/TFTP 配置模板
│   ├── nginx-podsys.conf      # HTTP 服务配置
│   └── entrypoint.sh          # 容器入口脚本
├── ipxe/                      # iPXE 引导脚本（备用，GB300 上有兼容性问题，未使用）
│   ├── autoexec.ipxe          # iPXE 自动执行脚本
│   ├── menu.ipxe              # iPXE 主引导菜单
│   ├── install.ipxe           # 自动安装模式
│   └── liveos.ipxe            # LiveOS 网络引导模式
├── tftp-grub/                 # GRUB 引导配置模板
│   └── grub.cfg.template      # grub.cfg 模板
├── tftp-root/                 # TFTP 根目录（运行时生成）
│   ├── grubaa64.efi           # ARM64 GRUB 引导器（从 Ubuntu ISO 提取，grub-mkimage 重建）
│   ├── grub.cfg               # GRUB 菜单配置（运行时生成）
│   ├── liveos-vmlinuz         # LiveOS 内核（从 Ubuntu ISO 提取）
│   ├── liveos-initrd          # LiveOS initrd（从 Ubuntu ISO 提取，需修补）
│   └── casper/                # 安装模式内核（从 ISO 提取）
├── scripts/                   # 辅助脚本
│   ├── build_docker.sh        # Docker 镜像构建
│   ├── build_liveos_iso.sh    # 将 squashfs 打包成 casper 可识别的 ISO
│   ├── prepare_liveos.sh      # 黄金机 squashfs 打包（只读模式）
│   ├── patch_initrd.sh        # 修补 initrd 移除 live-server 分层挂载
│   └── inject_casper.sh       # initrd casper 模块注入（备用）
├── workspace/                 # 运行时数据（挂载进容器）
│   ├── config.yaml            # 主配置文件
│   ├── iplist.txt             # 机器清单
│   ├── iso/                   # ISO 文件目录（含 LiveOS ISO 和安装 ISO）
│   ├── user-data/             # cloud-init 配置
│   └── liveos/                # 黄金机 squashfs（构建 LiveOS ISO 的源文件）
├── install_compute.sh         # 一键启动脚本
├── install_progress.sh        # SSH 连通性检测
└── ainexus-lite.tar           # Docker 镜像（LFS）
```

## 快速开始

### 前置条件

- 管理节点：Ubuntu 24.04，已安装 Docker
- 目标机：GB300 (aarch64)，支持 PXE 网络启动
- 管理节点与目标机在同一二层网络
- Ubuntu 24.04 ARM64 Server ISO 文件

### 1. 构建 Docker 镜像

```bash
# amd64 管理节点
bash scripts/build_docker.sh

# arm64 管理节点
bash scripts/build_docker.sh --arch arm64
```

### 2. 配置

编辑 `workspace/config.yaml`：

```yaml
# 管理节点 IP（必须）
manager_ip: 192.168.0.183

# DHCP 地址池（必须与管理网卡同一子网）
dhcp_s: 192.168.0.10
dhcp_e: 192.168.0.100

# 管理网卡
manager_nic: enx00e04c450d02

# 安装用 ISO（放在 workspace/ 目录下）
iso: ubuntu-24.04.4-live-server-arm64.iso

# LiveOS 配置
liveos_enable: yes
liveos_iso: liveos.iso    # LiveOS ISO 文件名（放在 workspace/iso/ 目录下）
```

### 3. 准备 LiveOS 镜像

> 详见下方 [LiveOS 完整流程](#liveos-完整流程)

### 4. 放置 ISO 文件

```bash
# 安装用 ISO
ls workspace/ubuntu-24.04.4-live-server-arm64.iso

# LiveOS ISO（由 build_liveos_iso.sh 生成）
ls workspace/iso/liveos.iso
```

`install_compute.sh` 会自动从 Ubuntu ISO 提取 `grubaa64.efi`、安装用内核、LiveOS 内核等文件。

### 5. 启动

```bash
bash install_compute.sh
```

### 6. 目标机启动

设置目标机 PXE/网络启动为第一启动项，开机后会看到 GRUB 菜单：

```
LiveOS (Network Boot)
Auto Install OS
```

---

## LiveOS 完整流程

LiveOS 模式将完整的操作系统通过网络加载到内存中运行，无需安装到磁盘。整个流程分为三个阶段：**黄金机打包 → 管理节点构建 ISO → 启动服务**。

更新操作系统镜像时，只需重新执行前两个阶段，代码无需任何修改。

### 阶段一：黄金机打包（在黄金机上执行）

`scripts/prepare_liveos.sh` 完全只读，**不修改黄金机任何系统文件**，不影响客户测试环境。

```bash
# 1. 拷贝打包脚本到黄金机
scp scripts/prepare_liveos.sh root@<golden-machine>:/root/

# 2. 在黄金机上执行（需要 root 权限）
bash /root/prepare_liveos.sh /home/nexus/podsys-liveos
```

脚本执行内容（均为只读）：
- 检查 igb 网卡驱动是否加载
- mksquashfs 只读压缩根文件系统（排除 /proc /sys /dev /tmp 等虚拟文件系统）

产出文件：
```
/home/nexus/podsys-liveos/
  filesystem.squashfs    # 根文件系统压缩镜像（黄金机完整环境，5~15 GB）
```

> **注意**：黄金机的 vmlinuz 和 initrd 不适用于 LiveOS。LiveOS 的内核和 initrd 必须从 Ubuntu Server ISO 提取（自带 casper 网络引导模块），由 `install_compute.sh` 自动完成。

### 阶段二：管理节点构建 ISO（在管理节点上执行）

`scripts/build_liveos_iso.sh` 将黄金机的 squashfs 打包成 casper 可识别的 ISO 格式。

```bash
# 1. 将黄金机的 squashfs 拷贝到管理节点
scp root@<golden-machine>:/home/nexus/podsys-liveos/filesystem.squashfs \
  /root/podsys-lite/workspace/liveos/

# 2. 构建 LiveOS ISO
bash scripts/build_liveos_iso.sh workspace/liveos/filesystem.squashfs workspace/iso/liveos.iso
```

构建过程自动完成：
- 创建 ISO 目录结构（`casper/`、`.disk/`）
- 复制 squashfs 到 `casper/filesystem.squashfs`
- 生成 `casper/filesystem.size`（casper 需要此文件确认 squashfs 大小）
- 生成 `.disk/info`、`.disk/cd_type`、`.disk/casper-uuid`
- 使用 `xorriso -iso-level 3` 构建 ISO（支持 >4G 文件）

产出文件：
```
workspace/iso/liveos.iso    # 可通过 HTTP 提供的 LiveOS ISO
```

### 阶段三：启动服务

```bash
bash install_compute.sh
```

`install_compute.sh` 自动完成：
- 从 Ubuntu Server ISO 提取 `grubaa64.efi`（用 grub-mkimage 重建，内嵌 early.cfg 设置 root=(tftp) prefix=(tftp)/boot/grub）
- 从 Ubuntu Server ISO 提取 LiveOS 用 vmlinuz 和 initrd 到 `tftp-root/`
- 用 `scripts/patch_initrd.sh` 修补 initrd（移除 Ubuntu Server 安装器专用脚本）
- 根据 `config.yaml` 生成 `grub.cfg`
- 启动 Docker 容器（dnsmasq + nginx）

### 更新操作系统镜像

当黄金机的系统更新后（安装新驱动、更新软件等），重新制作 LiveOS 镜像只需重复阶段一和阶段二：

```bash
# 1. 黄金机：重新打包
bash /root/prepare_liveos.sh /home/nexus/podsys-liveos

# 2. 拷贝到管理节点
scp root@<golden-machine>:/home/nexus/podsys-liveos/filesystem.squashfs \
  /root/podsys-lite/workspace/liveos/

# 3. 管理节点：重新构建 ISO
bash scripts/build_liveos_iso.sh workspace/liveos/filesystem.squashfs workspace/iso/liveos.iso

# 4. 重启服务（如果容器已在运行）
docker restart <container_name>
# 或者重新执行
bash install_compute.sh
```

**代码无需任何修改。** 只需替换 `workspace/liveos/filesystem.squashfs` 文件，重新构建 ISO 即可。

### LiveOS 文件说明

| 文件 | 位置 | 来源 | 作用 |
|---|---|---|---|
| `filesystem.squashfs` | `workspace/liveos/` | 黄金机 `prepare_liveos.sh` | 黄金机根文件系统压缩镜像 |
| `liveos.iso` | `workspace/iso/` | 管理节点 `build_liveos_iso.sh` | casper 可识别的 ISO，包含 squashfs |
| `liveos-vmlinuz` | `tftp-root/` | Ubuntu Server ISO（`install_compute.sh` 提取） | LiveOS 内核，自带 casper 网络模块 |
| `liveos-initrd` | `tftp-root/` | Ubuntu Server ISO（`install_compute.sh` 提取 + `patch_initrd.sh` 修补） | LiveOS initrd，已移除 server 安装器脚本 |
| `grubaa64.efi` | `tftp-root/` | Ubuntu Server ISO（`install_compute.sh` 提取 + grub-mkimage 重建） | ARM64 GRUB 引导器 |
| `grub.cfg` | `tftp-root/` + `tftp-root/boot/grub/` | `install_compute.sh` 从模板生成 | GRUB 引导菜单 |

### 内存要求

| 项目 | 说明 |
|---|---|
| squashfs 文件大小 | 取决于黄金机系统，通常 5~15 GB |
| 解压后大小 | 约 squashfs 的 2~3 倍 |
| 目标机最低内存 | 解压后大小 + 4 GB |
| GB300 推荐配置 | 32 GB 内存 |

---

## 脚本说明

### `scripts/prepare_liveos.sh` — 黄金机打包

在黄金机上运行，只读操作，生成 `filesystem.squashfs`。

```bash
bash prepare_liveos.sh [输出目录]
# 默认输出: /home/nexus/podsys-liveos/filesystem.squashfs
```

### `scripts/build_liveos_iso.sh` — 构建 LiveOS ISO

在管理节点上运行，将 squashfs 打包成 casper 可识别的 ISO。

```bash
bash build_liveos_iso.sh [squashfs路径] [输出ISO路径]
# 默认: workspace/liveos/filesystem.squashfs → workspace/iso/liveos.iso
```

依赖：`xorriso`（脚本会自动安装）

### `scripts/patch_initrd.sh` — 修补 initrd

修补 Ubuntu Server ISO 的 initrd，移除 `live-server` 安装器专用脚本（该脚本硬编码挂载 server 分层 squashfs，自定义 LiveOS ISO 不包含这些文件，会导致 kernel panic）。

```bash
sudo bash patch_initrd.sh <input-initrd> [output-initrd]
# 不指定 output-initrd 则原地修补（自动备份原文件为 .bak）
```

> `install_compute.sh` 在提取 initrd 后会自动调用此脚本，通常无需手动执行。

### `scripts/build_docker.sh` — 构建 Docker 镜像

```bash
bash scripts/build_docker.sh           # amd64
bash scripts/build_docker.sh --arch arm64  # arm64
```

---

## 机器清单格式

`workspace/iplist.txt` 每行 5 列：

```
<机器ID>  <主机名>  <IP/掩码>  <网关>  <DNS>
```

示例：
```
2xxxxxx5  cu01  192.168.2.1/24  192.168.2.102  8.8.8.8
```

---

## 服务端口

| 端口 | 协议 | 服务 |
|---|---|---|
| 67 | UDP | DHCP |
| 69 | UDP | TFTP |
| 5001 | TCP | HTTP（GRUB 配置、内核、ISO） |

---

## LiveOS 踩坑记录与技术细节

> 本节记录了在 GB300 (aarch64) 平台上实现 LiveOS 网络引导过程中遇到的所有问题及解决方案，供后续参考和排障。

### 1. iPXE 在 GB300 上 Synchronous Exception

**现象**：交叉编译的 iPXE 在 GB300 上启动时报 Synchronous Exception。

**原因**：GB300 的 UEFI 固件与 iPXE 存在兼容性问题。

**解决**：改用 GRUB（grubaa64.efi）作为 ARM64 引导器。grubaa64.efi 从 Ubuntu ARM64 ISO 提取，用 `grub-mkimage` 重建，内嵌 `early.cfg` 设置 `root=(tftp) prefix=(tftp)/boot/grub`。

### 2. casper URL 参数为空（`wget: bad address ''`）

**现象**：内核启动后 casper 尝试 wget 空地址，报 `bad address ''`。

**原因**：使用了错误的内核参数 `netboot=url` 和 `live-media-url=`。casper 的 `parse_cmdline()` 中，`netboot=url` 只设置 `NETBOOT=url` 变量，不设置 `URL` 变量；`live-media-url=` 不被 casper 识别。

**解决**：只使用 `url=ISO地址` 参数。casper 的 `parse_cmdline()` 对 `url=*.iso)` 的处理会同时设置 `NETBOOT=url` 和 `URL` 变量。不要使用 `netboot=url` 或 `live-media-url=`。

### 3. GRUB 读取错误的 grub.cfg

**现象**：修改了 `/tftp/grub.cfg`（TFTP 根目录），但目标机始终使用旧参数。

**原因**：`grubaa64.efi` 内嵌 `prefix=(tftp)/boot/grub`，GRUB 实际通过 TFTP 读取的是 `/boot/grub/grub.cfg`，不是根目录的 `/grub.cfg`。

**解决**：`install_compute.sh` 生成 grub.cfg 时同时写入两个位置：`tftp-root/grub.cfg` 和 `tftp-root/boot/grub/grub.cfg`。两个文件内容必须一致。

### 4. casper 报 "Unable to find a live file system on the network"

**现象**：ISO 下载成功（7654M 100%），手动 mount 和 ls 验证正常，但 casper 仍报错。

**原因**：initrd 的 `/conf/uuid.conf` 保存了原始 Ubuntu ISO 的 UUID，casper 的 `matches_uuid()` 函数检查 ISO 里 `.disk/casper-uuid` 是否匹配。自定义 LiveOS ISO 的 UUID 与原 ISO 不匹配，`matches_uuid()` 返回失败，casper 卸载 ISO 并报错。

**解决**：在内核参数中添加 `ignore_uuid`，让 casper 跳过 UUID 检查。同时 `build_liveos_iso.sh` 会生成 `.disk/casper-uuid` 文件作为后备。

### 5. casper 报 "File system layers missing"

**现象**：ISO 挂载成功后，casper 报找不到 `ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs` 等分层文件。

**原因**：Ubuntu Server ISO 的 initrd 设置 `LAYERFS_PATH=ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs`，casper 按点号分层查找（installer.generic → installer → ubuntu-server → minimal）。自定义 LiveOS ISO 只有 `filesystem.squashfs`，没有这些分层文件。

**解决**：在内核参数中添加 `layerfs-path=filesystem.squashfs` 覆盖默认值。`filesystem` 按点号分割只有一个层级，不会产生额外的层依赖。

**注意**：`layerfs-path` 的值不要加 `casper/` 前缀。casper 会在相对路径前自动拼接 `image_directory`（已含 `LIVE_MEDIA_PATH=casper`），加了会变成 `/cdrom/casper/casper/filesystem.squashfs` 导致路径重复。

### 6. Kernel Panic: mount /dev /proc /sys /run 失败

**现象**：casper 成功加载 squashfs 后，在 init-bottom 阶段报 mount 失败，最终 kernel panic。

```
mount: mounting /root/cdrom/casper/ubuntu-server-minimal.squashfs on /root/media/minimal failed: No such file or directory
mount: mounting /dev on /root/dev failed: No such file or directory
mount: mounting /run on /root/run failed: No such file or directory
mount: mounting /sys on /root/sys failed: No such file or directory
mount: mounting /proc on /root/proc failed: No such file or directory
/init: line 386: can't open /root/dev/console: no such file
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100
```

**原因**：Ubuntu Server ISO 的 initrd 包含 `/scripts/init-bottom/live-server` 脚本，该脚本硬编码尝试挂载 `ubuntu-server-minimal.squashfs` 和 `ubuntu-server-minimal.ubuntu-server.squashfs`。这些文件只存在于 Ubuntu Server ISO，自定义 LiveOS ISO 没有。mount 失败后根文件系统状态异常，导致后续 /dev /proc /sys /run 全部挂载失败。

**解决**：用 `scripts/patch_initrd.sh` 修补 initrd，将 `live-server` 脚本中的 squashfs 挂载命令移除，只保留 `echo linux-generic > /run/kernel-meta-package`。`install_compute.sh` 在提取 initrd 后会自动调用此脚本。

### 7. casper 只接受 ISO 文件

**现象**：尝试用 `url=` 指向 squashfs 文件或目录，casper 无法识别。

**原因**：casper 的 `url=` 参数只接受 ISO 文件。casper 下载 ISO 后用 `mount -o ro -t iso9660` 挂载，然后搜索 `casper/*.squashfs`。

**解决**：使用 `scripts/build_liveos_iso.sh` 将 squashfs 打包成 ISO 格式。ISO 结构必须包含：
- `casper/filesystem.squashfs` — 根文件系统
- `casper/filesystem.size` — squashfs 大小（字节）
- `.disk/info` — ISO 描述信息
- `.disk/cd_type` — 内容类型
- `.disk/casper-uuid` — UUID（配合 `ignore_uuid` 可省略，但建议保留）

### 8. squashfs >4G 打包 ISO 报错

**原因**：标准 ISO 9660 Level 1 不支持 >4G 的单个文件。

**解决**：`build_liveos_iso.sh` 使用 `xorriso -iso-level 3` 参数，支持 >4G 文件。

### 9. DHCP 冲突导致目标机获取错误网关

**现象**：网络上有其他 DHCP 服务器时，目标机可能获取错误网关，无法访问管理节点的 HTTP 服务。

**解决**：在 dnsmasq 中用 `dhcp-option=3,MANAGER_IP` 强制指定网关为管理节点 IP。

---

## LiveOS 内核参数说明

```
boot=casper                    # 使用 casper 模块（Live 系统引导）
url=http://IP:5001/iso/liveos.iso  # ISO 下载地址（只接受 .iso 结尾的 URL）
root=/dev/ram0                 # 根设备为内存盘
ramdisk_size=33554432          # 内存盘大小（32GB，KB 单位）
ip=dhcp                        # 网络配置方式
ignore_uuid                    # 跳过 ISO UUID 校验（自定义 ISO 的 UUID 与原 ISO 不匹配）
layerfs-path=filesystem.squashfs  # squashfs 文件名（不加 casper/ 前缀，casper 会自动拼接）
console=tty0                   # 控制台输出
net.ifnames=0                  # 禁用可预测网络接口命名（使用 eth0）
biosdevname=0                  # 禁用 biosdevname 命名
cloud-config-url=/dev/null     # 禁用 cloud-init
---                             # 分隔符，之后为 initrd 参数
```

**关键约束**：
- `url=` 必须以 `.iso` 结尾，casper 只认 ISO 文件
- `ignore_uuid` 必须添加，否则 casper 的 UUID 校验会拒绝自定义 ISO
- `layerfs-path` 不要加 `casper/` 前缀，casper 会自动拼接导致路径重复
- 不要使用 `netboot=url` 或 `live-media-url=`，这些参数不会正确设置 URL 变量

---

## 常见问题

### Docker Hub 访问慢

配置镜像加速：

```bash
cat > /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
systemctl restart docker
```

### DHCP 分配失败（no address range available）

DHCP 范围必须与管理网卡在同一子网。如果网卡 IP 是 `192.168.0.183`，DHCP 范围也必须是 `192.168.0.x`。

### docker load 后 tag 不一致

`install_compute.sh` 会自动将 `docker load` 产出的镜像 re-tag 为统一名称 `ainexus-lite:v2.0`。

---

## 技术栈

- Shell (Bash) — 主控脚本
- Docker — 容器化运行环境
- dnsmasq — DHCP + TFTP 服务
- nginx — HTTP 文件服务（端口 5001）
- GRUB (grubaa64.efi) — ARM64 网络引导（从 Ubuntu ISO 提取，grub-mkimage 重建）
- Ubuntu 24.04 — 容器基础镜像和目标系统

## License

MIT
