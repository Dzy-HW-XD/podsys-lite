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
mkdir -p "$TFTP_ROOT/casper"

# 生成 autoexec.ipxe（iPXE 加载后的默认入口）
cat > "$TFTP_ROOT/autoexec.ipxe" <<AUTOEOF
#!ipxe
chain http://${manager_ip}:5001/ipxe/menu.ipxe
AUTOEOF

# 生成 GRUB 配置（ARM64 GB300 用 GRUB 引导替代崩溃的 iPXE）
mkdir -p "$TFTP_ROOT/boot/grub"
ISO_NAME=$(grep "iso" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
GRUB_CFG_CONTENT=$(cat <<GRUBEOF
set default=0
set timeout=5

menuentry "LiveOS (Network Boot)" {
    linux /liveos-vmlinuz boot=casper netboot=url url=http://${manager_ip}:5001/liveos/filesystem.squashfs ip=dhcp root=/dev/ram0 ramdisk_size=33554432 console=tty0 net.ifnames=0 biosdevname=0
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

# 复制 LiveOS vmlinuz/initrd 到 TFTP 根目录（GRUB 通过 TFTP 加载）
[ -f "$PWD/workspace/liveos/vmlinuz" ] && cp "$PWD/workspace/liveos/vmlinuz" "$TFTP_ROOT/liveos-vmlinuz"
[ -f "$PWD/workspace/liveos/initrd" ] && cp "$PWD/workspace/liveos/initrd" "$TFTP_ROOT/liveos-initrd"

# ---- LiveOS initrd casper 注入检查 ----
# 黄金机的 initrd 不含 casper 模块，boot=casper 会失败
# 如果尚未注入，自动执行注入
if [ "$liveos_enable" = "yes" ] || [ "$liveos_enable" = "true" ]; then
    LIVEOS_INITRD="$PWD/workspace/liveos/initrd"
    if [ -f "$LIVEOS_INITRD" ]; then
        echo ""
        echo "=== Checking casper module in LiveOS initrd ==="
        HAS_CASPER=false
        if command -v lsinitramfs &>/dev/null; then
            if lsinitramfs "$LIVEOS_INITRD" 2>/dev/null | grep -q 'casper'; then
                HAS_CASPER=true
            fi
        fi
        # 备用检测：直接搜索 casper 关键字
        if [ "$HAS_CASPER" = "false" ]; then
            if file "$LIVEOS_INITRD" | grep -q "cpio\|gzip\|zstd\|XZ"; then
                # 创建临时目录检查
                _CHECK_DIR=$(mktemp -d /tmp/casper-check-XXXXXX)
                cd "$_CHECK_DIR"
                if zstd -d -c "$LIVEOS_INITRD" 2>/dev/null | cpio -t 2>/dev/null | grep -q 'casper'; then
                    HAS_CASPER=true
                elif zcat "$LIVEOS_INITRD" 2>/dev/null | cpio -t 2>/dev/null | grep -q 'casper'; then
                    HAS_CASPER=true
                fi
                cd -
                rm -rf "$_CHECK_DIR"
            fi
        fi

        if [ "$HAS_CASPER" = "true" ]; then
            echo "[OK] casper module already present in initrd"
        else
            echo "[WARNING] casper module NOT found in initrd"
            echo "  Running casper injection..."
            bash "$PWD/scripts/inject_casper.sh" "$LIVEOS_INITRD"
            # 注入后重新复制 initrd 到 TFTP
            cp "$LIVEOS_INITRD" "$TFTP_ROOT/liveos-initrd"
            echo "[OK] casper injected and initrd updated in TFTP"
        fi
    fi
fi

# 复制 iPXE 脚本到 TFTP（备用，GRUB 不需要但 nginx 可通过 /tftp/ 路径提供）
mkdir -p "$TFTP_ROOT/ipxe"
cp "$PWD/ipxe/"*.ipxe "$TFTP_ROOT/ipxe/" 2>/dev/null || true

# ---- grubaa64.efi 处理 ----
# 从 Docker 镜像中提取预构建的 grubaa64.efi（内嵌 TFTP 前缀）
# 镜像构建时已用 grub-mkimage 生成，prefix=(tftp)/boot/grub
# 因为 -v tftp-root:/tftp 会覆盖容器内 /tftp，必须先提取到宿主机
echo ""
echo "=== Extracting grubaa64.efi from Docker image ==="
_TMP_CONTAINER=$(docker create ${IMAGE_NAME}:${IMAGE_TAG} 2>/dev/null)
if [ -n "$_TMP_CONTAINER" ]; then
    docker cp "$_TMP_CONTAINER:/tftp/grubaa64.efi" "$TFTP_ROOT/grubaa64.efi" 2>/dev/null
    docker rm "$_TMP_CONTAINER" >/dev/null 2>&1
fi
if [ -f "$TFTP_ROOT/grubaa64.efi" ] && [ -s "$TFTP_ROOT/grubaa64.efi" ]; then
    echo "[OK] grubaa64.efi extracted from image ($(du -h "$TFTP_ROOT/grubaa64.efi" | cut -f1))"
    echo "     Embedded prefix=(tftp)/boot/grub"
else
    echo "[WARNING] grubaa64.efi not found in image, trying to build on host..."
    if ! command -v grub-mkimage &>/dev/null || [ ! -f /usr/lib/grub/arm64-efi/moddep.lst ]; then
        echo "  Installing grub-efi-arm64-bin..."
        sudo apt-get update -qq
        sudo apt-get install -y grub-efi-arm64-bin
    fi
    if command -v grub-mkimage &>/dev/null; then
        EARLY_CFG=$(mktemp)
        cat > "$EARLY_CFG" <<'EARLYEOF'
set root=(tftp)
set prefix=(tftp)/boot/grub
configfile ${prefix}/grub.cfg
EARLYEOF
        GRUB_MODULES="normal configfile tftp efinet net linux boot echo gzio"
        grub-mkimage -O arm64-efi -o "$TFTP_ROOT/grubaa64.efi" -p "(tftp)/boot/grub" -c "$EARLY_CFG" $GRUB_MODULES
        rm -f "$EARLY_CFG"
        echo "[OK] grubaa64.efi built on host"
    else
        echo "[ERROR] Cannot build grubaa64.efi! PXE boot will not work."
        echo "  Rebuild Docker image with: docker build -t ainexus-lite:v2.0 -f docker/Dockerfile ."
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
