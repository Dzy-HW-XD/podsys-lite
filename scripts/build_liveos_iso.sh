#!/bin/bash
# ============================================================
# Podsys Lite - LiveOS ISO 构建脚本
# 将黄金机的 filesystem.squashfs 打包成 casper 可识别的 ISO
#
# 用法:
#   bash build_liveos_iso.sh [squashfs路径] [输出ISO路径]
#
# 说明:
#   casper 的 url= 参数只支持下载 ISO 文件（不是目录），
#   下载后挂载 ISO 并搜索 casper/filesystem.squashfs。
#   因此需要将黄金机的 squashfs 包装成 ISO 格式。
#
# 依赖: xorriso 或 genisoimage 或 mkisofs
# ============================================================
set -e

SQUASHFS="${1:-workspace/liveos/filesystem.squashfs}"
OUTPUT_ISO="${2:-workspace/iso/liveos.iso}"

echo "============================================"
echo "  Podsys Lite - LiveOS ISO Builder"
echo "============================================"
echo "  Input:  $SQUASHFS"
echo "  Output: $OUTPUT_ISO"
echo ""

# ---- 检查输入文件 ----
if [ ! -f "$SQUASHFS" ]; then
    echo "[ERROR] squashfs not found: $SQUASHFS"
    echo "  Run scripts/prepare_liveos.sh on the golden machine first"
    exit 1
fi

echo "[1/4] squashfs size: $(du -h "$SQUASHFS" | cut -f1)"

# ---- 检查 ISO 构建工具 ----
ISO_TOOL=""
if command -v xorriso &>/dev/null; then
    ISO_TOOL="xorriso"
elif command -v genisoimage &>/dev/null; then
    ISO_TOOL="genisoimage"
elif command -v mkisofs &>/dev/null; then
    ISO_TOOL="mkisofs"
fi

if [ -z "$ISO_TOOL" ]; then
    echo "[INFO] No ISO tool found, installing xorriso..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq xorriso
        ISO_TOOL="xorriso"
    else
        echo "[ERROR] Cannot install xorriso. Please install manually:"
        echo "  sudo apt-get install -y xorriso"
        exit 1
    fi
fi

echo "[2/4] Using ISO tool: $ISO_TOOL"

# ---- 创建 ISO 临时目录结构 ----
ISO_DIR=$(mktemp -d /tmp/podsys-liveos-iso.XXXXXX)
trap "rm -rf '$ISO_DIR'" EXIT

mkdir -p "$ISO_DIR/casper" "$ISO_DIR/.disk"

# 复制 squashfs
echo "[3/4] Building ISO structure..."
cp "$SQUASHFS" "$ISO_DIR/casper/filesystem.squashfs"

# 创建 filesystem.size（casper 可能需要此文件确认 squashfs 大小）
du -s --block-size=1 "$ISO_DIR/casper/filesystem.squashfs" | cut -f1 > "$ISO_DIR/casper/filesystem.size"

# 创建 .disk/info（casper 用于识别光盘）
echo "Podsys LiveOS - Custom Image" > "$ISO_DIR/.disk/info"

# 创建 .disk/cd_type
echo "complete" > "$ISO_DIR/.disk/cd_type"

# ---- 创建输出目录 ----
mkdir -p "$(dirname "$OUTPUT_ISO")"

# ---- 生成 ISO ----
echo "[4/4] Generating ISO..."
case "$ISO_TOOL" in
    xorriso)
        xorriso -as mkisofs \
            -iso-level 3 \
            -r \
            -V "PODSYS_LIVEOS" \
            -o "$OUTPUT_ISO" \
            "$ISO_DIR"
        ;;
    genisoimage|mkisofs)
        # -iso-level 3 支持 >4G 文件
        $ISO_TOOL \
            -iso-level 3 \
            -r \
            -V "PODSYS_LIVEOS" \
            -o "$OUTPUT_ISO" \
            "$ISO_DIR"
        ;;
esac

echo ""
echo "============================================"
echo "  LiveOS ISO built successfully!"
echo "  Size: $(du -h "$OUTPUT_ISO" | cut -f1)"
echo "  Path: $OUTPUT_ISO"
echo ""
echo "  This ISO can be served via HTTP at:"
echo "    http://MANAGER_IP:5001/iso/liveos.iso"
echo "============================================"
