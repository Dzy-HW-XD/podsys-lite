## 项目概述
Podsys Lite - 基于 GRUB + Docker 的裸金属自动化部署系统。通过 DHCP/TFTP/HTTP 实现网络引导，支持自动安装（autoinstall）和 LiveOS 内存运行两种模式。专为 GB300 (aarch64) 平台设计。

## 技术栈
- Shell (Bash) - 主控脚本
- Docker - 容器化运行环境
- dnsmasq - DHCP + TFTP 服务
- nginx - HTTP 文件服务（端口 5001）
- GRUB (grubaa64.efi) - ARM64 网络引导（从 Ubuntu ISO 提取，grub-mkimage 重建）
- Ubuntu 24.04 - 容器基础镜像和目标系统

## 目录结构
```
.
├── docker/                    # Docker 构建文件
│   ├── Dockerfile             # 镜像构建定义
│   ├── dnsmasq.conf           # DHCP/TFTP 配置模板
│   ├── nginx-podsys.conf      # HTTP 服务配置
│   └── entrypoint.sh          # 容器入口脚本
├── ipxe/                      # 引导脚本（备用，GB300 上 iPXE 有兼容性问题）
│   ├── autoexec.ipxe          # iPXE 自动执行脚本
│   ├── menu.ipxe              # iPXE 主引导菜单
│   ├── install.ipxe           # 自动安装模式
│   └── liveos.ipxe            # LiveOS 网络引导模式
├── tftp-grub/                 # GRUB 引导配置模板
│   └── grub.cfg.template      # grub.cfg 模板
├── tftp-root/                 # TFTP 根目录（运行时生成）
│   ├── grubaa64.efi           # ARM64 GRUB 引导器（grub-mkimage 重建）
│   ├── grub.cfg               # GRUB 菜单配置（运行时生成）
│   ├── liveos-vmlinuz         # LiveOS 内核（从 Ubuntu ISO 提取）
│   ├── liveos-initrd          # LiveOS initrd（从 Ubuntu ISO 提取）
│   └── casper/                # 安装模式内核（从 ISO 提取）
├── scripts/                   # 辅助脚本
│   ├── build_docker.sh        # Docker 镜像构建
│   ├── build_liveos_iso.sh    # 将 squashfs 打包成 casper 可识别的 ISO
│   ├── prepare_liveos.sh      # 黄金机 squashfs 打包（只读模式）
│   └── inject_casper.sh       # initrd casper 模块注入（备用）
├── workspace/                 # 运行时数据（挂载进容器）
│   ├── config.yaml            # 主配置文件
│   ├── iplist.txt             # 机器清单
│   ├── iso/                   # ISO 文件目录（含 LiveOS ISO）
│   ├── user-data/             # cloud-init 配置
│   └── liveos/                # 黄金机 squashfs（构建 LiveOS ISO 的源文件）
├── install_compute.sh         # 一键启动脚本
├── install_progress.sh        # SSH 连通性检测
└── ainexus-lite.tar           # Docker 镜像（LFS）
```

## 关键入口 / 核心模块
- **启动入口**: `install_compute.sh` - 初始化 tftp-root → 校验配置 → 导入镜像 → 启动容器
- **容器入口**: `docker/entrypoint.sh` - 读取 config.yaml → 启动 nginx + dnsmasq
- **GRUB 引导**: `tftp-root/grub.cfg` - 提供 LiveOS / Install 两个引导选项
- **LiveOS 制作流程**:
  1. `scripts/prepare_liveos.sh` - 在黄金机上运行，生成 filesystem.squashfs
  2. 将 squashfs 传到管理节点 `workspace/liveos/`
  3. `scripts/build_liveos_iso.sh` - 在管理节点上运行，将 squashfs 打包成 ISO
  4. ISO 放在 `workspace/iso/liveos.iso`，nginx 通过 HTTP 提供
- **镜像构建**: `scripts/build_docker.sh` - 构建并导出 Docker 镜像

## LiveOS 引导机制（关键）
casper 的 `url=` 参数只接受 **ISO 文件**，不是目录或 squashfs 文件。casper 下载 ISO 后挂载，在里面搜索 `casper/filesystem.squashfs`。因此：
- 黄金机的 squashfs 必须打包成 ISO（含 `casper/` 和 `.disk/` 目录结构）
- LiveOS 内核参数：`boot=casper url=http://IP:5001/iso/liveos.iso root=/dev/ram0 ramdisk_size=33554432 ip=dhcp ignore_uuid layerfs-path=filesystem.squashfs console=tty0 net.ifnames=0 biosdevname=0 cloud-config-url=/dev/null ---`
- **不要使用 `netboot=url` 或 `live-media-url=`**，这些参数会导致 casper 走错误的代码路径，URL 变量为空
- **必须添加 `ignore_uuid`**：initrd 的 `/conf/uuid.conf` 保存了原 Ubuntu ISO 的 UUID，casper 的 `matches_uuid()` 会检查 ISO 里的 `.disk/casper-uuid` 是否匹配，自定义 LiveOS ISO 的 UUID 不匹配会导致 casper 拒绝挂载，报 "Unable to find a live file system on the network"
- **必须添加 `layerfs-path=filesystem.squashfs`**：Ubuntu Server ISO 的 initrd 默认 `LAYERFS_PATH=ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs`，会按点号分层查找（installer.generic → installer → ubuntu-server → minimal），自定义 LiveOS ISO 只有 `filesystem.squashfs`，不加此参数会报 "File system layers missing"。注意不要加 `casper/` 前缀，因为 casper 会自动在相对路径前拼接 `image_directory`（已含 `LIVE_MEDIA_PATH=casper`），加了会变成 `/cdrom/casper/casper/filesystem.squashfs` 导致路径重复
- LiveOS 的 vmlinuz/initrd 必须从 Ubuntu ISO 提取（自带 casper 网络模块），不能用黄金机的
- 需要安装 `xorriso` 来构建 ISO（支持 >4G 文件需 `-iso-level 3`）
- LiveOS ISO 必须包含 `.disk/casper-uuid`（配合 `ignore_uuid` 可省略，但建议保留以备后用）

## 运行与预览
- 非 Web 项目，无预览能力
- 运行方式：`bash install_compute.sh`（需要 root 权限和 Docker）
- 服务端口：67/udp (DHCP), 69/udp (TFTP), 5001 (HTTP)
- 容器以 `--privileged --network=host` 模式运行

## 引导流程（ARM64/GB300）
```
目标机 UEFI PXE → DHCP(grubaa64.efi) → TFTP 下载 grubaa64.efi →
TFTP 下载 grub.cfg → GRUB 菜单 →
  [LiveOS]: TFTP 下载 vmlinuz + initrd → 内核启动 → HTTP 下载 liveos.iso → 挂载 ISO → 加载 squashfs → 进入系统
  [Install]: TFTP 下载 vmlinuz + initrd → 内核启动 → HTTP 下载 ISO → 自动安装
```

## 用户偏好与长期约束
- 目标平台：GB300 (aarch64, I210 网卡, igb 驱动)
- 网卡驱动为 igb，标准 Ubuntu initrd 已包含，无需额外注入
- LiveOS 模式通过网络加载 squashfs 到内存运行，目标机内存需 >= 32GB
- 黄金机制作 LiveOS 使用 `scripts/prepare_liveos.sh`（只读模式，不修改黄金机系统）
- 管理节点使用 `scripts/build_docker.sh` 构建镜像
- GRUB 引导器从 Ubuntu ARM64 ISO 提取，不使用交叉编译的 iPXE（GB300 上 iPXE 有 Synchronous Exception 兼容性问题）
- grubaa64.efi 需用 grub-mkimage 重建，内嵌 early.cfg 设置 root=(tftp) prefix=(tftp)/boot/grub

## 常见问题和预防
- Docker Hub 国内访问慢：配置 `/etc/docker/daemon.json` 镜像加速
- DHCP 范围必须与管理网卡在同一子网（如网卡 IP 是 192.168.0.x，DHCP 范围也必须是 192.168.0.x）
- LiveOS 文件缺失：容器启动时检查并警告，不影响 install 模式
- docker load 后 tag 可能不一致：install_compute.sh 会自动 re-tag 为统一名称
- iPXE 在 GB300 上有 Synchronous Exception：已改用 GRUB 引导
- casper URL 为空：不要使用 `netboot=url` 或 `live-media-url=`，正确参数是 `url=ISO地址`
- casper 报 "Unable to find a live file system on the network" 但 ISO 下载成功：检查是否缺少 `ignore_uuid` 参数（UUID 不匹配导致 matches_uuid 失败）
- casper 报 "File system layers missing"：检查是否缺少 `layerfs-path=filesystem.squashfs` 参数（Server ISO 的 initrd 默认查找分层 squashfs，与自定义 ISO 不匹配）。注意值是 `filesystem.squashfs`，不要写 `casper/filesystem.squashfs`，否则路径会变成 `/cdrom/casper/casper/filesystem.squashfs`
- GRUB 实际读取的 grub.cfg 路径是 `/boot/grub/grub.cfg`（prefix=(tftp)/boot/grub），不是根目录的 `/grub.cfg`，两个位置都要写入
- squashfs >4G 打包 ISO 需 `-iso-level 3` 参数
- DHCP 冲突：如果网络上有其他 DHCP 服务器，目标机可能获取错误网关，在 dnsmasq 中用 `dhcp-option=3,MANAGER_IP` 强制指定网关
