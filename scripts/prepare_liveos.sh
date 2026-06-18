#!/bin/bash
# ============================================================
# Podsys Lite - LiveOS 准备脚本
# 在黄金机（已装好驱动和软件的 GB300）上运行此脚本，
# 将当前系统打包为 LiveOS 所需的三个文件。
#
# 用法:
#   bash prepare_liveos.sh [输出目录]
#
# 输出:
#   vmlinuz              - ARM64 内核
#   initrd               - 包含网卡驱动的 initramfs
#   filesystem.squashfs  - 根文件系统压缩镜像
# ============================================================
set -e

OUTPUT_DIR="${1:-/tmp/podsys-liveos}"
mkdir -p "$OUTPUT_DIR"

echo "============================================"
echo "  Podsys Lite - LiveOS Preparation"
echo "  Output: $OUTPUT_DIR"
echo "============================================"

# ---- 检查运行环境 ----
if [ "$(uname -m)" != "aarch64" ]; then
    echo "[WARNING] This script is designed for GB300 (aarch64)."
    echo "  Current arch: $(uname -m)"
    echo "  Continuing anyway..."
fi

if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] This script must be run as root."
    exit 1
fi

# ---- 检查必要工具 ----
echo ""
echo "[1/5] Checking tools..."
for tool in mksquashfs unsquashfs; do
    if ! command -v $tool &>/dev/null; then
        echo "  Installing squashfs-tools..."
        apt-get update -qq && apt-get install -y -qq squashfs-tools
        break
    fi
done
echo "  [OK] squashfs-tools ready"

# ---- 清理系统 ----
echo ""
echo "[2/5] Cleaning system..."
apt-get clean 2>/dev/null || true
rm -rf /var/cache/apt/archives/* 2>/dev/null || true
journalctl --vacuum-size=50M 2>/dev/null || true
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
echo "  [OK] System cleaned"

# ---- 确认关键驱动 ----
echo ""
echo "[3/5] Checking network drivers..."
# I210 网卡使用 igb 驱动
if lsmod | grep -q igb; then
    echo "  [OK] igb driver loaded (I210)"
else
    echo "  [WARNING] igb driver not loaded, check if I210 is present"
fi

# 确保 igb 在 initramfs 模块列表中
if [ -d /etc/initramfs-tools ]; then
    if ! grep -q "^igb$" /etc/initramfs-tools/modules 2>/dev/null; then
        echo "igb" >> /etc/initramfs-tools/modules
        echo "  Added igb to initramfs modules"
    fi
fi

# 确保 casper 已安装（LiveOS 引导必需）
if ! dpkg -l casper 2>/dev/null | grep -q "^ii"; then
    echo "  Installing casper package..."
    apt-get install -y -qq casper
fi
echo "  [OK] casper installed"

# ---- 重新生成 initrd（确保包含 igb 和 casper） ----
echo ""
echo "[4/5] Regenerating initrd..."
CURRENT_KERNEL=$(uname -r)
update-initramfs -u -k "$CURRENT_KERNEL"
echo "  [OK] initrd regenerated for kernel $CURRENT_KERNEL"

# ---- 制作 squashfs ----
echo ""
echo "[5/5] Creating squashfs (this may take 10-30 minutes)..."
echo "  This compresses the entire root filesystem."

cat > /tmp/podsys-exclude.txt << 'EXCLUDE_EOF'
/proc/*
/sys/*
/dev/*
/tmp/*
/run/*
/mnt/*
/media/*
/lost+found
/swapfile
/etc/fstab
/etc/mtab
/boot/grub/*
/var/cache/apt/archives/*
/home/*/.cache/*
/root/.cache/*
/var/log/journal/*
EXCLUDE_EOF

# 额外排除输出目录自身（避免递归）
echo "$OUTPUT_DIR/*" >> /tmp/podsys-exclude.txt

echo "  Running mksquashfs..."
mksquashfs / "$OUTPUT_DIR/filesystem.squashfs" \
    -ef /tmp/podsys-exclude.txt \
    -comp xz \
    -b 1M \
    -noappend

echo "  [OK] squashfs created: $OUTPUT_DIR/filesystem.squashfs"
echo "  Size: $(du -h "$OUTPUT_DIR/filesystem.squashfs" | cut -f1)"

# ---- 复制内核和 initrd ----
echo ""
echo "Copying kernel and initrd..."
cp /boot/vmlinuz-"$CURRENT_KERNEL" "$OUTPUT_DIR/vmlinuz"
cp /boot/initrd.img-"$CURRENT_KERNEL" "$OUTPUT_DIR/initrd"

echo "  [OK] vmlinuz ($(du -h "$OUTPUT_DIR/vmlinuz" | cut -f1))"
echo "  [OK] initrd  ($(du -h "$OUTPUT_DIR/initrd" | cut -f1))"

# ---- 完成 ----
echo ""
echo "============================================"
echo "  LiveOS preparation complete!"
echo "============================================"
echo ""
echo "Output files:"
echo "  $OUTPUT_DIR/vmlinuz"
echo "  $OUTPUT_DIR/initrd"
echo "  $OUTPUT_DIR/filesystem.squashfs"
echo ""
echo "Next steps:"
echo "  1. Copy these 3 files to the management node:"
echo "     scp $OUTPUT_DIR/{vmlinuz,initrd,filesystem.squashfs} root@<manager>:/root/podsys-lite/workspace/liveos/"
echo ""
echo "  2. On the management node, set liveos_enable: yes in workspace/config.yaml"
echo ""
echo "  3. Start the Podsys Lite container:"
echo "     bash install_compute.sh"
echo ""
echo "  4. Target machines will see the LiveOS option in the iPXE boot menu"
echo ""
echo "Estimated memory requirement on target:"
SQUASHFS_SIZE=$(du -b "$OUTPUT_DIR/filesystem.squashfs" | cut -f1)
UNCOMPRESSED_ESTIMATE=$(( SQUASHFS_SIZE * 3 / 1024 / 1024 / 1024 ))
echo "  squashfs: $(du -h "$OUTPUT_DIR/filesystem.squashfs" | cut -f1)"
echo "  estimated uncompressed: ~${UNCOMPRESSED_ESTIMATE} GB"
echo "  recommended target RAM: ~$(( UNCOMPRESSED_ESTIMATE + 4 )) GB"
echo "  current ramdisk_size: 33554432 KB (32 GB)"
echo ""
