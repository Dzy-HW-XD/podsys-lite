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
    liveos_iso=$(grep "liveos_iso" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    if [ "$liveos_enable" = "yes" ] || [ "$liveos_enable" = "true" ]; then
        echo ""
        echo "=== LiveOS Mode Enabled ==="
        # 检查 LiveOS ISO（包含黄金机 squashfs 的自定义 ISO）
        LIVEOS_ISO_PATH="workspace/iso/${liveos_iso:-liveos.iso}"
        if [ -f "$LIVEOS_ISO_PATH" ]; then
            echo "[OK] LiveOS ISO: ${LIVEOS_ISO_PATH} ($(du -h "$LIVEOS_ISO_PATH" | cut -f1))"
        else
            echo "[WARNING] LiveOS ISO not found: ${LIVEOS_ISO_PATH}"
            echo "  Build it with: bash scripts/build_liveos_iso.sh"
            echo "  Then place it in workspace/iso/"
        fi
        # 同时检查 squashfs 源文件（用于提示构建）
        if [ ! -f "workspace/liveos/filesystem.squashfs" ]; then
            echo "[WARNING] workspace/liveos/filesystem.squashfs not found"
            echo "  Run scripts/prepare_liveos.sh on the golden machine first"
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

if docker ps -a --format '{{.Names}}' | grep -q podsys-lite; then
    docker stop podsys-lite >/dev/null 2>&1 || true
    docker rm podsys-lite >/dev/null 2>&1 || true
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
        LOADED_IMAGE=$(docker load -i "$IMAGE_TAR" 2>&1 | grep "^Loaded image:" | head -1 | sed 's/^Loaded image: //')
        echo "Image loaded: ${LOADED_IMAGE}"
        if [ -z "$LOADED_IMAGE" ]; then
            echo "[Warning] Could not detect loaded image name, trying fallback..."
            LOADED_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | head -1)
        fi
        # 无论 load 出来的名字是什么，都 re-tag 为统一名字
        docker tag "${LOADED_IMAGE}" ${IMAGE_NAME}:${IMAGE_TAG}
        echo "Tagged as: ${IMAGE_NAME}:${IMAGE_TAG}"
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
mkdir -p "$TFTP_ROOT/casper" "$TFTP_ROOT/boot/grub" "$TFTP_ROOT/ipxe"
chmod -R 755 "$TFTP_ROOT"

# 生成 autoexec.ipxe（iPXE 加载后的默认入口）
cat > "$TFTP_ROOT/autoexec.ipxe" <<AUTOEOF
#!ipxe
chain http://${manager_ip}:5001/ipxe/menu.ipxe
AUTOEOF

# 生成 GRUB 配置（ARM64 GB300 用 GRUB 引导替代崩溃的 iPXE）
mkdir -p "$TFTP_ROOT/boot/grub"
ISO_NAME=$(grep "iso" "$CONFIG_FILE" | grep -v "liveos_iso" | cut -d ":" -f 2 | tr -d '[:space:]')
LIVEOS_ISO=$(grep "liveos_iso" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
LIVEOS_ISO=${LIVEOS_ISO:-liveos.iso}
GRUB_CFG_CONTENT=$(cat <<GRUBEOF
set default=0
set timeout=5

menuentry "LiveOS (Network Boot)" {
    linux /liveos-vmlinuz boot=casper url=http://${manager_ip}:5001/iso/${LIVEOS_ISO} root=/dev/ram0 ramdisk_size=33554432 ip=dhcp ignore_uuid layerfs-path=casper/filesystem.squashfs console=tty0 net.ifnames=0 biosdevname=0 cloud-config-url=/dev/null ---
    initrd /liveos-initrd
}

menuentry "Auto Install OS" {
    linux /casper/vmlinuz ip=dhcp url=http://${manager_ip}:5001/workspace/${ISO_NAME} autoinstall ds=nocloud-net;s=http://${manager_ip}:5001/user-data/ root=/dev/ram0 cloud-config-url=/dev/null
    initrd /casper/initrd
}

menuentry "Reboot" {
    reboot
}
GRUBEOF
)

# 写入 grub.cfg 到多个位置确保 GRUB 能找到
echo "$GRUB_CFG_CONTENT" > "$TFTP_ROOT/boot/grub/grub.cfg"
echo "$GRUB_CFG_CONTENT" > "$TFTP_ROOT/grub.cfg"
echo "[OK] grub.cfg written to /boot/grub/ and TFTP root"

# LiveOS vmlinuz/initrd 从 ISO 提取（ISO 的 initrd 自带 casper 网络模块）
# 黄金机的 initrd 不支持网络拉取 squashfs，不能用于 LiveOS
ISO_MOUNT_LIVEOS="/tmp/podsys-iso-liveos"
ISO_FILE_LIVEOS=""
# 查找 ISO 文件
for iso_candidate in "$PWD/workspace/iso/"*.iso "$PWD/workspace/"*.iso; do
    if [ -f "$iso_candidate" ]; then
        ISO_FILE_LIVEOS="$iso_candidate"
        break
    fi
done
if [ -n "$ISO_FILE_LIVEOS" ]; then
    mkdir -p "$ISO_MOUNT_LIVEOS"
    sudo mount -o loop,ro "$ISO_FILE_LIVEOS" "$ISO_MOUNT_LIVEOS" 2>/dev/null || true
    if mountpoint -q "$ISO_MOUNT_LIVEOS"; then
        cp "$ISO_MOUNT_LIVEOS/casper/vmlinuz" "$TFTP_ROOT/liveos-vmlinuz" 2>/dev/null || true
        cp "$ISO_MOUNT_LIVEOS/casper/initrd" "$TFTP_ROOT/liveos-initrd" 2>/dev/null || true
        chmod 755 "$TFTP_ROOT/liveos-vmlinuz" "$TFTP_ROOT/liveos-initrd"
        sudo umount "$ISO_MOUNT_LIVEOS" 2>/dev/null || true
        echo "[OK] LiveOS vmlinuz/initrd extracted from ISO (with casper network support)"
    else
        echo "[WARNING] Could not mount ISO for LiveOS, trying workspace/liveos/ as fallback"
        [ -f "$PWD/workspace/liveos/vmlinuz" ] && { cp "$PWD/workspace/liveos/vmlinuz" "$TFTP_ROOT/liveos-vmlinuz"; chmod 755 "$TFTP_ROOT/liveos-vmlinuz"; }
        [ -f "$PWD/workspace/liveos/initrd" ] && { cp "$PWD/workspace/liveos/initrd" "$TFTP_ROOT/liveos-initrd"; chmod 755 "$TFTP_ROOT/liveos-initrd"; }
    fi
    rmdir "$ISO_MOUNT_LIVEOS" 2>/dev/null || true
else
    echo "[WARNING] No ISO found, using workspace/liveos/ vmlinuz/initrd (may lack casper)"
    [ -f "$PWD/workspace/liveos/vmlinuz" ] && { cp "$PWD/workspace/liveos/vmlinuz" "$TFTP_ROOT/liveos-vmlinuz"; chmod 755 "$TFTP_ROOT/liveos-vmlinuz"; }
    [ -f "$PWD/workspace/liveos/initrd" ] && { cp "$PWD/workspace/liveos/initrd" "$TFTP_ROOT/liveos-initrd"; chmod 755 "$TFTP_ROOT/liveos-initrd"; }
fi

# 复制 iPXE 脚本到 TFTP（备用，GRUB 不需要但 nginx 可通过 /tftp/ 路径提供）
mkdir -p "$TFTP_ROOT/ipxe"
cp "$PWD/ipxe/"*.ipxe "$TFTP_ROOT/ipxe/" 2>/dev/null || true

# ---- grubaa64.efi 处理 ----
# 优先级：1) tftp-root 已有有效文件 → 跳过
#         2) 仓库 tftp-grub/grubaa64.efi → 复制
#         3) Docker 镜像内预构建 → 提取
#         4) 宿主机 grub-mkimage → 构建（最后降级）
if [ -f "$TFTP_ROOT/grubaa64.efi" ] && [ -s "$TFTP_ROOT/grubaa64.efi" ]; then
    echo "[OK] grubaa64.efi already in tftp-root ($(du -h "$TFTP_ROOT/grubaa64.efi" | cut -f1))"
elif [ -f "$PWD/tftp-grub/grubaa64.efi" ] && [ -s "$PWD/tftp-grub/grubaa64.efi" ]; then
    cp "$PWD/tftp-grub/grubaa64.efi" "$TFTP_ROOT/grubaa64.efi"
    chmod 755 "$TFTP_ROOT/grubaa64.efi"
    echo "[OK] grubaa64.efi copied from tftp-grub/"
else
    echo "=== Trying to extract grubaa64.efi from Docker image ==="
    _TMP_CONTAINER=$(docker create ${IMAGE_NAME}:${IMAGE_TAG} 2>/dev/null)
    if [ -n "$_TMP_CONTAINER" ]; then
        docker cp "$_TMP_CONTAINER:/tftp/grubaa64.efi" "$TFTP_ROOT/grubaa64.efi" 2>/dev/null
        docker rm "$_TMP_CONTAINER" >/dev/null 2>&1
    fi
    if [ -f "$TFTP_ROOT/grubaa64.efi" ] && [ -s "$TFTP_ROOT/grubaa64.efi" ]; then
        echo "[OK] grubaa64.efi extracted from image"
    else
        echo "[WARNING] grubaa64.efi not available from image or repo"
        echo "  Run this to build one:"
        echo "    docker run --rm --platform linux/arm64 -v $PWD/tftp-root:/output ubuntu:24.04 bash -c '"
        echo "      apt-get update -qq && apt-get install -y -qq grub-efi-arm64-bin &&"
        echo "      printf \"set root=(tftp)\\\\nset prefix=(tftp)/boot/grub\\\\nconfigfile \\\${prefix}/grub.cfg\\\\n\" > /tmp/early.cfg &&"
        echo "      grub-mkimage -O arm64-efi -o /output/grubaa64.efi -p \"(tftp)/boot/grub\" -c /tmp/early.cfg normal configfile tftp efinet net linux boot echo gzio'"
    fi
fi

# 从 ISO 提取 casper 内核/initrd 到 TFTP（仅安装模式需要）
if [ -n "$ISO_NAME" ] && [ -f "$PWD/workspace/$ISO_NAME" ]; then
    ISO_MOUNT="/tmp/podsys-iso-mount"
    mkdir -p "$ISO_MOUNT"
    sudo mount -o loop,ro "$PWD/workspace/$ISO_NAME" "$ISO_MOUNT" 2>/dev/null || true
    if mountpoint -q "$ISO_MOUNT"; then
        cp "$ISO_MOUNT/casper/vmlinuz" "$TFTP_ROOT/casper/" 2>/dev/null || true
        cp "$ISO_MOUNT/casper/initrd" "$TFTP_ROOT/casper/" 2>/dev/null || true
        chmod -R 755 "$TFTP_ROOT/casper/"
        sudo umount "$ISO_MOUNT" 2>/dev/null || true
        echo "[OK] Casper kernel/initrd extracted from ISO for Install mode"
    else
        echo "[WARNING] Could not mount ISO, Install mode may not work"
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
