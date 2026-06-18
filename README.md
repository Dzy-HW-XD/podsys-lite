# Podsys Lite

基于 iPXE + Docker 的裸金属自动化部署系统，支持自动安装（Autoinstall）和 LiveOS 网络引导两种模式。专为 GB300 (aarch64) 平台设计。

## 功能

- **自动安装模式**：iPXE 引导 → 拉取 ISO → cloud-init 自动安装到磁盘
- **LiveOS 模式**：iPXE 引导 → 网络加载 squashfs → 完整系统运行在内存中
- 支持 DHCP / TFTP / HTTP 协议栈
- 支持 BIOS、UEFI x86-64、UEFI ARM64 客户端
- 容器化部署，一键启动

## 架构

```
目标机 (GB300)
  │ PXE 网络启动
  ▼
管理节点 (Docker 容器)
  ├── dnsmasq  ── DHCP (67/udp) + TFTP (69/udp)
  ├── nginx    ── HTTP 文件服务 (5001)
  └── iPXE     ── 引导菜单脚本
```

## 目录结构

```
.
├── docker/                    # Docker 构建文件
│   ├── Dockerfile             # 镜像构建定义
│   ├── dnsmasq.conf           # DHCP/TFTP 配置模板
│   ├── nginx-podsys.conf      # HTTP 服务配置
│   └── entrypoint.sh          # 容器入口脚本
├── ipxe/                      # iPXE 引导脚本
│   ├── menu.ipxe              # 主引导菜单
│   ├── install.ipxe           # 自动安装模式
│   └── liveos.ipxe            # LiveOS 网络引导模式
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
├── ainexus-lite               # amd64 Docker 镜像
└── ainexus-lite-arm           # arm64 Docker 镜像
```

## 快速开始

### 前置条件

- 管理节点：Ubuntu 24.04，已安装 Docker
- 目标机：GB300 (aarch64)，支持 PXE 网络启动
- 管理节点与目标机在同一二层网络

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

# DHCP 地址池
dhcp_s: 192.168.0.10
dhcp_e: 192.168.0.20

# 管理网卡
manager_nic: enp97s0f1

# 安装用 ISO
iso: ubuntu-24.04.4-live-server-arm64.iso

# LiveOS 模式
liveos_enable: yes
liveos_ramdisk_size: 33554432  # 32GB
```

### 3. 修改 iPXE 脚本中的 IP

将 `ipxe/menu.ipxe`、`ipxe/install.ipxe`、`ipxe/liveos.ipxe` 中的 `192.168.0.183` 替换为你的管理节点 IP。

### 4. 启动

```bash
bash install_compute.sh
```

### 5. 目标机启动

设置目标机 PXE/网络启动为第一启动项，开机后会看到 iPXE 菜单：

```
[1] Auto Install OS
[2] LiveOS (Network Boot)
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
| 5001 | TCP | HTTP（iPXE 脚本、ISO、LiveOS 文件） |

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

### 网卡 enp97s0f1 不存在

dnsmasq 会警告但不影响 DHCP（host 网络模式下绑定所有接口）。如果确实需要绑定特定网卡，修改 `config.yaml` 中的 `manager_nic`。

### LiveOS 文件缺失

容器启动时会检查并警告缺失文件，不影响 install 模式。将 vmlinuz、initrd、filesystem.squashfs 放入 `workspace/liveos/` 即可。

### iPXE 引导失败

检查 iPXE 脚本中的 server IP 是否为管理节点实际 IP。默认值为 `192.168.0.183`，需要修改。

---

## 技术栈

- Shell (Bash)
- Docker
- dnsmasq (DHCP + TFTP)
- nginx (HTTP)
- iPXE (网络引导)
- Ubuntu 24.04

## License

MIT
