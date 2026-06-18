## 项目概述
Podsys Lite - 基于 GRUB + Docker 的裸金属自动化部署系统。通过 DHCP/TFTP/HTTP 实现网络引导，支持自动安装（autoinstall）和 LiveOS 内存运行两种模式。专为 GB300 (aarch64) 平台设计。

## 技术栈
- Shell (Bash) - 主控脚本
- Docker - 容器化运行环境
- dnsmasq - DHCP + TFTP 服务
- nginx - HTTP 文件服务（端口 5001）
- GRUB (grubaa64.efi) - ARM64 网络引导（从 Ubuntu ISO 提取）
- Ubuntu 24.04 - 容器基础镜像和目标系统

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
├── tftp-root/                 # TFTP 根目录（运行时生成）
│   ├── grubaa64.efi           # ARM64 GRUB 引导器（从 ISO 提取）
│   ├── grub.cfg               # GRUB 菜单配置
│   └── casper/                # 安装模式内核（从 ISO 提取）
├── scripts/                   # 辅助脚本
│   ├── build_docker.sh        # Docker 镜像构建
│   ├── prepare_liveos.sh      # 黄金机 LiveOS 打包（只读模式）
│   └── inject_casper.sh       # initrd casper 模块注入
├── workspace/                 # 运行时数据（挂载进容器）
│   ├── config.yaml            # 主配置文件
│   ├── iplist.txt             # 机器清单
│   ├── iso/                   # ISO 文件目录
│   ├── user-data/             # cloud-init 配置
│   └── liveos/                # LiveOS 文件（vmlinuz, initrd, squashfs）
├── install_compute.sh         # 一键启动脚本
├── install_progress.sh        # SSH 连通性检测
└── ainexus-lite.tar           # Docker 镜像（LFS）
```

## 关键入口 / 核心模块
- **启动入口**: `install_compute.sh` - 初始化 tftp-root → 校验配置 → 导入镜像 → 启动容器
- **容器入口**: `docker/entrypoint.sh` - 读取 config.yaml → 启动 nginx + dnsmasq
- **GRUB 引导**: `tftp-root/grub.cfg` - 提供 LiveOS / Install 两个引导选项
- **LiveOS 打包**: `scripts/prepare_liveos.sh` - 在黄金机上运行（只读模式，不修改系统）
- **镜像构建**: `scripts/build_docker.sh` - 构建并导出 Docker 镜像

## 运行与预览
- 非 Web 项目，无预览能力
- 运行方式：`bash install_compute.sh`（需要 root 权限和 Docker）
- 服务端口：67/udp (DHCP), 69/udp (TFTP), 5001 (HTTP)
- 容器以 `--privileged --network=host` 模式运行

## 引导流程（ARM64/GB300）
```
目标机 UEFI PXE → DHCP(grubaa64.efi) → TFTP 下载 grubaa64.efi →
TFTP 下载 grub.cfg → GRUB 菜单 →
  [LiveOS]: TFTP 下载 vmlinuz + initrd → 内核启动 → HTTP 下载 squashfs → 进入系统
  [Install]: TFTP 下载 vmlinuz + initrd → 内核启动 → HTTP 下载 ISO → 自动安装
```

## 用户偏好与长期约束
- 目标平台：GB300 (aarch64, I210 网卡, igb 驱动)
- 网卡驱动为 igb，标准 Ubuntu initrd 已包含，无需额外注入
- LiveOS 模式通过网络加载 squashfs 到内存运行，目标机内存需 >= 32GB
- 黄金机制作 LiveOS 使用 `scripts/prepare_liveos.sh`（只读模式，不修改黄金机系统）
- 管理节点使用 `scripts/build_docker.sh` 构建镜像
- GRUB 引导器从 Ubuntu ARM64 ISO 提取，不使用交叉编译的 iPXE（GB300 上 iPXE 有 Synchronous Exception 兼容性问题）

## 常见问题和预防
- Docker Hub 国内访问慢：配置 `/etc/docker/daemon.json` 镜像加速
- DHCP 范围必须与管理网卡在同一子网（如网卡 IP 是 192.168.0.x，DHCP 范围也必须是 192.168.0.x）
- LiveOS 文件缺失：容器启动时检查并警告，不影响 install 模式
- GRUB 脚本中 server IP 写死为 `192.168.0.183`：需根据实际管理节点 IP 修改
- docker load 后 tag 可能不一致：install_compute.sh 会自动 re-tag 为统一名称
- iPXE 在 GB300 上有 Synchronous Exception：已改用 GRUB 引导
