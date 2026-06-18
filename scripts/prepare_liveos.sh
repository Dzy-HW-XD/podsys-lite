#!/bin/bash
# ============================================================
# Podsys Lite - LiveOS 准备脚本（安全版）
# 完全只读操作，不修改黄金机任何系统文件。
# 在已装好驱动和软件的 GB300 黄金机上运行。
#
# 用法:
#   bash prepare_liveos.sh [输出目录]
#
# 说明:
#   本脚本只打包 filesystem.squashfs。
#   vmlinuz 和 initrd 从 Ubuntu ISO 获取（自带 casper 网络模块），
#   黄金机的 initrd 不支持网络拉取 squashfs，不能用于 LiveOS。
#
# 默认输出:
#   /home/nexus/podsys-liveos/
#     filesystem.squashfs  - 根文件系统压缩镜像（黄金机完整环境）
# ============================================================
set -e

OUTPUT_DIR="${1:-/home/nexus/podsys-liveos}"
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
echo "[1/2] Checking tools..."
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
echo ""
echo "[2/2] Checking drivers..."
if lsmod | grep -q igb; then
    echo "  [OK] igb driver loaded (I210)"
else
    echo "  [WARNING] igb driver not loaded"
fi

# ---- 制作 squashfs（只读） ----
echo ""
echo "Creating squashfs (this may take 10-30 minutes)..."
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

# ---- 完成 ----
echo ""
echo "============================================"
echo "  LiveOS preparation complete!"
echo "============================================"
echo ""
echo "Output file:"
echo "  $OUTPUT_DIR/filesystem.squashfs"
echo ""
echo "Next steps:"
echo "  1. Copy squashfs to management node:"
echo "     scp $OUTPUT_DIR/filesystem.squashfs root@<manager>:/root/podsys-lite/workspace/liveos/"
echo ""
echo "  2. vmlinuz and initrd come from Ubuntu ISO (not golden machine):"
echo "     install_compute.sh will extract them from the ISO automatically"
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
