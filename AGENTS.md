## 项目概述
Podsys Lite - 基于 iPXE + Docker 的裸金属自动化部署系统。通过 DHCP/TFTP/HTTP 实现网络引导，支持自动安装（autoinstall）和 LiveOS 内存运行两种模式。专为 GB300 (aarch64) 平台设计。

## 技术栈
- Shell (Bash) - 主控脚本
- Docker - 容器化运行环境
- dnsmasq - DHCP + TFTP 服务
- nginx - HTTP 文件服务（端口 5001）
- iPXE - 网络引导固件
- Ubuntu 24.04 - 容器基础镜像和目标系统

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
│   └── prepare_liveos.sh      # 黄金机 LiveOS 打包
├── workspace/                 # 运行时数据（挂载进容器）
│   ├── config.yaml            # 主配置文件
│   ├── iplist.txt             # 机器清单
│   ├── iso/                   # ISO 文件目录
│   ├── user-data/             # cloud-init 配置
│   └── liveos/                # LiveOS 文件（vmlinuz, initrd, squashfs）
├── install_compute.sh         # 一键启动脚本
├── install_progress.sh        # SSH 连通性检测
├── ainexus-lite               # amd64 Docker 镜像（LFS）
└── ainexus-lite-arm           # arm64 Docker 镜像（LFS）
```

## 关键入口 / 核心模块
- **启动入口**: `install_compute.sh` - 校验配置 → 导入镜像 → 启动容器
- **容器入口**: `docker/entrypoint.sh` - 读取 config.yaml → 启动 nginx + dnsmasq
- **iPXE 菜单**: `ipxe/menu.ipxe` - 提供 install / liveos 两个引导选项
- **LiveOS 打包**: `scripts/prepare_liveos.sh` - 在黄金机上运行，产出 squashfs
- **镜像构建**: `scripts/build_docker.sh` - 构建并导出 Docker 镜像

## 运行与预览
- 非 Web 项目，无预览能力
- 运行方式：`bash install_compute.sh`（需要 root 权限和 Docker）
- 服务端口：67/udp (DHCP), 69/udp (TFTP), 5001 (HTTP)
- 容器以 `--privileged --network=host` 模式运行

## 用户偏好与长期约束
- 目标平台：GB300 (aarch64, I210 网卡, igb 驱动)
- 网卡驱动为 igb，标准 Ubuntu initrd 已包含，无需额外注入
- LiveOS 模式通过网络加载 squashfs 到内存运行，目标机内存需 >= 32GB
- 黄金机制作 LiveOS 使用 `scripts/prepare_liveos.sh`
- 管理节点使用 `scripts/build_docker.sh` 构建镜像

## 常见问题和预防
- Docker Hub 国内访问慢：配置 `/etc/docker/daemon.json` 镜像加速
- 网卡 `enp97s0f1` 不存在：dnsmasq 会警告但不影响 DHCP（host 网络模式下绑定所有接口）
- LiveOS 文件缺失：容器启动时检查并警告，不影响 install 模式
- iPXE 脚本中 server IP 写死为 `192.168.0.183`：需根据实际管理节点 IP 修改 `ipxe/*.ipxe` 中的地址
