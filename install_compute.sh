#!/bin/bash
# ============================================================
# Podsys Lite - 一键启动脚本
# 导入 Docker 镜像并以特权模式启动容器
# 支持 LiveOS 网络引导模式
# ============================================================
set -e

cd "$(dirname "$0")"
clear

echo "============================================"
echo "  Podsys Lite - Network Boot System"
echo "============================================"

# ---- 日志清理 ----
delete_logs() {
    if [ ! -d "workspace/log" ]; then
        mkdir -p "workspace/log"
    fi
    logs=("workspace/log/dnsmasq.log")
    for log in "${logs[@]}"; do
        if [ -f "$log" ]; then
            rm "$log"
        fi
    done
}

# ---- iplist.txt 格式校验 ----
check_iplist_format() {
    local file_path="$1"
    if [ ! -f "$file_path" ]; then
        echo "Warning: File $file_path does not exist."
        return 1
    fi
    while IFS= read -r line; do
        fields=($line)
        if [ ${#fields[@]} -ne 5 ]; then
            echo "Incorrect format on line iplist.txt: $line"
            continue
        fi
        if ! echo "${fields[2]}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$'; then
            echo "Invalid IP address with subnet mask in the 3rd column on line of iplist.txt: $line"
            continue
        fi
        if [ "${fields[4]}" != "none" ] && ! echo "${fields[4]}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$'; then
            echo "Invalid DNS in the 4th column on line of iplist.txt: $line"
            continue
        fi
    done <"$file_path"
}

delete_logs
check_iplist_format "workspace/iplist.txt"

# ---- 读取配置 ----
CONFIG_FILE="workspace/config.yaml"
if [ -f "$CONFIG_FILE" ]; then
    manager_ip=$(grep "manager_ip" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    manager_nic=$(grep "manager_nic" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')

    if [ -n "$manager_nic" ] && [ ! -d "/sys/class/net/$manager_nic" ]; then
        echo "Error: manager_nic '$manager_nic' does not exist on this node."
        exit 1
    fi

    if [ -n "$manager_ip" ]; then
        if ! ip addr show "$manager_nic" 2>/dev/null | grep -q "$manager_ip"; then
            echo "Error: manager_ip '$manager_ip' is not configured on '$manager_nic'."
            exit 1
        fi
    fi

    # ---- LiveOS 检查 ----
    liveos_enable=$(grep "liveos_enable" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    if [ "$liveos_enable" = "yes" ] || [ "$liveos_enable" = "true" ]; then
        echo ""
        echo "=== LiveOS Mode Enabled ==="
        LIVEOS_DIR="workspace/liveos"
        MISSING=""
        [ -f "$LIVEOS_DIR/vmlinuz" ] || MISSING="$MISSING  vmlinuz"
        [ -f "$LIVEOS_DIR/initrd" ] || MISSING="$MISSING  initrd"
        [ -f "$LIVEOS_DIR/filesystem.squashfs" ] || MISSING="$MISSING  filesystem.squashfs"
        if [ -n "$MISSING" ]; then
            echo "[WARNING] LiveOS files missing:"
            echo "$MISSING"
            echo "  Place them in ${LIVEOS_DIR}/"
            echo "  See scripts/prepare_liveos.sh for instructions"
        else
            echo "[OK] vmlinuz"
            echo "[OK] initrd"
            echo "[OK] filesystem.squashfs ($(du -h ${LIVEOS_DIR}/filesystem.squashfs | cut -f1))"
            echo "LiveOS ready."
        fi
        echo "==========================="
    else
        # 非 LiveOS 模式才检查 ISO
        iso=$(grep "iso" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
        if [ -n "$iso" ] && [ ! -f "workspace/${iso}" ]; then
            echo "Error: ISO not exist: workspace/${iso}"
            echo "Please download the ISO file and place it in the workspace directory."
            exit 1
        fi
    fi
fi

# ---- Docker 镜像管理 ----
IMAGE_NAME="ainexus-lite"
IMAGE_TAG="v2.0"

if docker ps -a --format '{{.Image}}' | grep -q "${IMAGE_NAME}:${IMAGE_TAG}"; then
    docker stop $(docker ps -a -q --filter ancestor=${IMAGE_NAME}:${IMAGE_TAG}) >/dev/null 2>&1 || true
    docker rm $(docker ps -a -q --filter ancestor=${IMAGE_NAME}:${IMAGE_TAG}) >/dev/null 2>&1 || true
    docker rmi ${IMAGE_NAME}:${IMAGE_TAG} >/dev/null 2>&1 || true
fi

# 检测架构并导入镜像
if type uname >/dev/null 2>&1; then
    arch=$(uname -m)
    case "$arch" in
    aarch64)
        IMAGE_FILE="ainexus-lite-arm"
        ;;
    amd64 | x86_64)
        IMAGE_FILE="ainexus-lite"
        ;;
    *)
        echo "[Error]: Processor $arch is not supported"
        exit 1
        ;;
    esac

    IMAGE_TAR="${IMAGE_FILE}.tar"
    if [ -f "$IMAGE_TAR" ]; then
        echo "Loading Docker image: ${IMAGE_TAR} ..."
        LOADED_IMAGE=$(docker load -i "$IMAGE_TAR" 2>&1 | grep "Loaded image" | sed 's/Loaded image: //')
        echo "Image loaded: ${LOADED_IMAGE}"
        # 确保 tag 一致（无论 load 出来的名字是什么，都 re-tag 为统一名字）
        docker tag "${LOADED_IMAGE}" ${IMAGE_NAME}:${IMAGE_TAG} 2>/dev/null || true
        echo "Image tagged: ${IMAGE_NAME}:${IMAGE_TAG}"
    elif [ -f "$IMAGE_FILE" ]; then
        # 兼容旧版扁平格式
        echo "Importing Docker image (legacy): ${IMAGE_FILE} ..."
        docker import "$IMAGE_FILE" ${IMAGE_NAME}:${IMAGE_TAG} >/dev/null
        echo "Image imported: ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        echo "[ERROR] Docker image file not found: $IMAGE_TAR"
        echo "Run scripts/build_docker.sh to build the image first."
        exit 1
    fi
fi

# ---- TFTP 根目录初始化 ----
TFTP_ROOT="$PWD/tftp-root"
mkdir -p "$TFTP_ROOT/casper"

# 生成 autoexec.ipxe（iPXE 加载后的默认入口）
cat > "$TFTP_ROOT/autoexec.ipxe" <<AUTOEOF
#!ipxe
chain http://${manager_ip}:5001/ipxe/menu.ipxe
AUTOEOF

# 生成 GRUB 配置（ARM64 GB300 用 GRUB 引导替代崩溃的 iPXE）
# GRUB 默认搜索路径: (tftp)/boot/grub/grub.cfg
mkdir -p "$TFTP_ROOT/boot/grub"
ISO_NAME=$(grep "iso" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
cat > "$TFTP_ROOT/boot/grub/grub.cfg" <<GRUBEOF
set default=0
set timeout=5

menuentry "LiveOS (Network Boot)" {
    linux /ipxe/liveos-vmlinuz boot=casper netboot=url url=http://${manager_ip}:5001/liveos/filesystem.squashfs ip=dhcp root=/dev/ram0 ramdisk_size=33554432 console=tty0 net.ifnames=0 biosdevname=0
    initrd /ipxe/liveos-initrd
}

menuentry "Auto Install OS" {
    linux /casper/vmlinuz ip=dhcp url=http://${manager_ip}:5001/workspace/${ISO_NAME} autoinstall ds=nocloud-net;s=http://${manager_ip}:5001/user-data/ root=/dev/ram0 cloud-config-url=/dev/null
    initrd /casper/initrd
}

menuentry "Reboot" {
    reboot
}
GRUBEOF

# 复制 LiveOS vmlinuz/initrd 到 TFTP（GRUB 通过 TFTP 加载）
[ -f "$PWD/workspace/liveos/vmlinuz" ] && cp "$PWD/workspace/liveos/vmlinuz" "$TFTP_ROOT/ipxe/liveos-vmlinuz"
[ -f "$PWD/workspace/liveos/initrd" ] && cp "$PWD/workspace/liveos/initrd" "$TFTP_ROOT/ipxe/liveos-initrd"

# 从 ISO 提取 casper 内核/initrd 到 TFTP（安装模式用）
if [ -n "$ISO_NAME" ] && [ -f "$PWD/workspace/$ISO_NAME" ]; then
    ISO_MOUNT="/tmp/podsys-iso-mount"
    mkdir -p "$ISO_MOUNT"
    sudo mount -o loop,ro "$PWD/workspace/$ISO_NAME" "$ISO_MOUNT" 2>/dev/null || true
    if mountpoint -q "$ISO_MOUNT"; then
        cp "$ISO_MOUNT/casper/vmlinuz" "$TFTP_ROOT/casper/" 2>/dev/null || true
        cp "$ISO_MOUNT/casper/initrd" "$TFTP_ROOT/casper/" 2>/dev/null || true
        # 提取 grubaa64.efi
        [ -f "$ISO_MOUNT/efi/boot/grubaa64.efi" ] && cp "$ISO_MOUNT/efi/boot/grubaa64.efi" "$TFTP_ROOT/"
        sudo umount "$ISO_MOUNT" 2>/dev/null || true
    fi
fi

# ---- 启动容器 ----
echo ""
echo "Starting Podsys Lite container..."
echo "  Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Network: host"
echo "  Workspace: $PWD/workspace -> /workspace"
echo "  TFTP root: $TFTP_ROOT -> /tftp"
echo ""

docker run \
    --name podsys-lite \
    --privileged=true \
    -d \
    --network=host \
    -v "$PWD/workspace:/workspace" \
    -v "$PWD/ipxe:/tftp/ipxe" \
    -v "$TFTP_ROOT:/tftp" \
    ${IMAGE_NAME}:${IMAGE_TAG}

# ---- 验证 ----
sleep 2
if docker ps --format '{{.Names}}' | grep -q 'podsys-lite'; then
    echo "Container podsys-lite is running."
    echo "Use 'docker logs -f podsys-lite' to monitor."
else
    echo "[ERROR] Container failed to start. Check 'docker logs podsys-lite'."
    exit 1
fi
