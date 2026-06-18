#!/bin/bash
# ============================================================
# Podsys Lite - LiveOS 准备脚本（安全版）
# 完全只读操作，不修改黄金机任何系统文件。
# 在已装好驱动和软件的 GB300 黄金机上运行。
#
# 用法:
#   bash prepare_liveos.sh [输出目录]
#
# 输出:
#   vmlinuz              - ARM64 内核
#   initrd               - 原始 initramfs（可能缺少 casper）
#   filesystem.squashfs  - 根文件系统压缩镜像
# ============================================================
set -e

OUTPUT_DIR="${1:-/tmp/podsys-liveos}"
mkdir -p "$OUTPUT_DIR"

echo "============================================"
echo "  Podsys Lite - LiveOS Preparation (Safe)"
echo "  Output: $OUTPUT_DIR"
echo "  Mode: READ-ONLY - no system modification"
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

# ---- 检查必要工具（不安装，只检查） ----
echo ""
echo "[1/3] Checking tools..."
MISSING_TOOLS=""
for tool in mksquashfs; do
    if ! command -v $tool &>/dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done
if [ -n "$MISSING_TOOLS" ]; then
    echo "[ERROR] Missing tools:${MISSING_TOOLS}"
    echo "  Install manually: apt-get install -y squashfs-tools"
    exit 1
fi
echo "  [OK] All tools available"

# ---- 检查关键驱动（只读） ----
echo ""
echo "[2/3] Checking drivers..."
if lsmod | grep -q igb; then
    echo "  [OK] igb driver loaded (I210)"
else
    echo "  [WARNING] igb driver not loaded"
fi

# 检查 initrd 中是否已有 casper
CURRENT_KERNEL=$(uname -r)
INITRD_PATH="/boot/initrd.img-${CURRENT_KERNEL}"
if command -v lsinitramfs &>/dev/null; then
    if lsinitramfs "$INITRD_PATH" 2>/dev/null | grep -q 'casper'; then
        echo "  [OK] casper found in initrd"
    else
        echo "  [WARNING] casper NOT found in initrd"
        echo "  -> After copying to management node, run:"
        echo "     bash scripts/inject_casper.sh workspace/liveos/initrd"
    fi
else
    echo "  [INFO] Cannot check initrd contents (lsinitramfs not available)"
    echo "  -> If LiveOS boot fails, initrd may need casper injection"
fi

# ---- 制作 squashfs（只读） ----
echo ""
echo "[3/3] Creating squashfs (this may take 10-30 minutes)..."
echo "  Compressing root filesystem (read-only, no system changes)..."

cat > /tmp/podsys-exclude.txt << 'EXCLUDE_EOF'
proc
sys
dev
tmp
run
mnt
media
lost+found
swapfile
etc/fstab
etc/mtab
boot/grub
var/cache/apt/archives
home/*/.cache
root/.cache
var/log/journal
EXCLUDE_EOF

# 排除输出目录自身，避免递归打包
echo "${OUTPUT_DIR#/}" >> /tmp/podsys-exclude.txt

mksquashfs / "$OUTPUT_DIR/filesystem.squashfs" \
    -ef /tmp/podsys-exclude.txt \
    -comp xz \
    -b 1M \
    -noappend

echo "  [OK] squashfs: $(du -h "$OUTPUT_DIR/filesystem.squashfs" | cut -f1)"

# ---- 复制内核和 initrd（只读） ----
echo ""
echo "Copying kernel and initrd..."
cp /boot/vmlinuz-"$CURRENT_KERNEL" "$OUTPUT_DIR/vmlinuz"
cp "$INITRD_PATH" "$OUTPUT_DIR/initrd"

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
echo "  1. Copy to management node:"
echo "     scp $OUTPUT_DIR/{vmlinuz,initrd,filesystem.squashfs} root@<manager>:/root/podsys-lite/workspace/liveos/"
echo ""
echo "  2. If initrd lacks casper, inject it on management node:"
echo "     bash scripts/inject_casper.sh workspace/liveos/initrd"
echo ""
echo "  3. Start Podsys Lite:"
echo "     bash install_compute.sh"
echo ""
SQUASHFS_SIZE=$(du -b "$OUTPUT_DIR/filesystem.squashfs" | cut -f1)
UNCOMPRESSED_ESTIMATE=$(( SQUASHFS_SIZE * 3 / 1024 / 1024 / 1024 ))
echo "Memory estimate:"
echo "  squashfs: $(du -h "$OUTPUT_DIR/filesystem.squashfs" | cut -f1)"
echo "  estimated uncompressed: ~${UNCOMPRESSED_ESTIMATE} GB"
echo "  recommended target RAM: ~$(( UNCOMPRESSED_ESTIMATE + 4 )) GB"
echo ""
