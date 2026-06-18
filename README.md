# Podsys Lite

基于 GRUB + Docker 的裸金属自动化部署系统，支持自动安装（Autoinstall）和 LiveOS 网络引导两种模式。专为 GB300 (aarch64) 平台设计。

## 功能

- **自动安装模式**：GRUB 引导 → TFTP 加载内核 → HTTP 拉取 ISO → cloud-init 自动安装到磁盘
- **LiveOS 模式**：GRUB 引导 → TFTP 加载内核 → HTTP 拉取 squashfs → 完整系统运行在内存中
- 支持 DHCP / TFTP / HTTP 协议栈
- 支持 BIOS、UEFI x86-64、UEFI ARM64 客户端
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
  [LiveOS]: TFTP 下载 vmlinuz + initrd → 内核启动 → HTTP 下载 squashfs → 进入系统
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
├── ipxe/                      # 引导脚本和内核文件
│   ├── autoexec.ipxe          # iPXE 自动执行脚本（备用）
│   ├── menu.ipxe              # iPXE 主引导菜单（备用）
│   ├── install.ipxe           # 自动安装模式（备用）
│   ├── liveos.ipxe            # LiveOS 网络引导模式（备用）
│   ├── liveos-vmlinuz         # LiveOS 内核（TFTP 分发）
│   └── liveos-initrd          # LiveOS initrd（TFTP 分发）
├── tftp-grub/                 # GRUB 引导配置模板
│   └── grub.cfg.template      # grub.cfg 模板
├── tftp-root/                 # TFTP 根目录（运行时自动生成）
│   ├── grubaa64.efi           # ARM64 GRUB 引导器（从 ISO 提取）
│   ├── grub.cfg               # GRUB 菜单配置（动态生成）
│   └── casper/                # 安装模式内核（从 ISO 提取）
├── scripts/                   # 辅助脚本
│   ├── build_docker.sh        # Docker 镜像构建
│   ├── prepare_liveos.sh      # 黄金机 LiveOS 打包（只读）
│   └── inject_casper.sh       # initrd casper 模块注入
├── workspace/                 # 运行时数据（挂载进容器）
│   ├── config.yaml            # 主配置文件
│   ├── iplist.txt             # 机器清单
│   ├── iso/                   # ISO 文件目录
│   ├── user-data/             # cloud-init 配置
│   └── liveos/                # LiveOS 文件
├── install_compute.sh         # 一键启动脚本
├── install_progress.sh        # SSH 连通性检测
└── ainexus-lite.tar           # Docker 镜像（LFS）
```

## 快速开始

### 前置条件

- 管理节点：Ubuntu 24.04，已安装 Docker
- 目标机：GB300 (aarch64)，支持 PXE 网络启动
- 管理节点与目标机在同一二层网络
- Ubuntu 24.04 ARM64 ISO 文件

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

# 安装用 ISO
iso: ubuntu-24.04.4-live-server-arm64.iso

# LiveOS 模式
liveos_enable: yes
liveos_ramdisk_size: 33554432  # 32GB
```

### 3. 放置 ISO

将 Ubuntu ARM64 ISO 放入 `workspace/` 目录：

```bash
ls workspace/ubuntu-24.04.4-live-server-arm64.iso
```

`install_compute.sh` 会自动从 ISO 提取 `grubaa64.efi`、安装用内核等文件。

### 4. 启动

```bash
bash install_compute.sh
```

### 5. 目标机启动

设置目标机 PXE/网络启动为第一启动项，开机后会看到 GRUB 菜单：

```
LiveOS (Network Boot)
Auto Install OS
```

---

## LiveOS 模式

LiveOS 模式将完整的操作系统通过网络加载到内存中运行，无需安装到磁盘。

### 制作 LiveOS 镜像（安全版，只读操作）

`scripts/prepare_liveos.sh` 完全只读，**不修改黄金机任何系统文件**，不影响客户测试环境。

在已装好驱动和软件的 GB300 黄金机上：

```bash
# 1. 拷贝打包脚本到黄金机
scp scripts/prepare_liveos.sh root@<golden-machine>:/root/

# 2. 在黄金机上执行（只读，安全）
bash /root/prepare_liveos.sh /home/nexus/podsys-liveos
```

脚本只做三件事（均为只读）：
- 检查 igb 网卡驱动是否加载
- mksquashfs 只读压缩根文件系统
- cp 复制内核和 initrd

产出三个文件：
```
/home/nexus/podsys-liveos/vmlinuz              # ARM64 内核
/home/nexus/podsys-liveos/initrd               # 原始 initramfs
/home/nexus/podsys-liveos/filesystem.squashfs  # 根文件系统压缩镜像
```

### 部署 LiveOS 文件

```bash
# 1. 拷贝到管理节点
scp /home/nexus/podsys-liveos/{vmlinuz,initrd,filesystem.squashfs} \
  root@<manager>:/root/podsys-lite/workspace/liveos/

# 2. 如果 initrd 缺少 casper 模块，在管理节点上注入
bash scripts/inject_casper.sh workspace/liveos/initrd
```

> **说明**：黄金机的 initrd 可能不含 casper 模块。`inject_casper.sh` 在管理节点上用 Docker 容器提取 casper 文件注入到 initrd，不污染管理节点系统。

### 内存要求

| 项目 | 说明 |
|---|---|
| squashfs 文件大小 | 取决于黄金机系统，通常 5~10 GB |
| 解压后大小 | 约 squashfs 的 2~3 倍 |
| 目标机最低内存 | 解压后大小 + 4 GB |
| GB300 推荐配置 | 32 GB ramdisk（内存充裕） |

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
| 5001 | TCP | HTTP（GRUB 配置、内核、ISO、LiveOS 文件） |

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

### LiveOS 文件缺失

容器启动时会检查并警告缺失文件，不影响 install 模式。将 vmlinuz、initrd、filesystem.squashfs 放入 `workspace/liveos/` 即可。

### docker load 后 tag 不一致

`install_compute.sh` 会自动将 `docker load` 产出的镜像 re-tag 为统一名称 `ainexus-lite:v2.0`。

### iPXE Synchronous Exception（GB300）

交叉编译的 iPXE 在 GB300 上存在兼容性问题，已改用 GRUB（grubaa64.efi）作为 ARM64 引导器。grubaa64.efi 从 Ubuntu ARM64 ISO 自动提取。

---

## 技术栈

- Shell (Bash)
- Docker
- dnsmasq (DHCP + TFTP)
- nginx (HTTP)
- GRUB (ARM64 网络引导)
- Ubuntu 24.04

## License

MIT
