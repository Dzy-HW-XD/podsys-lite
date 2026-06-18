#!/bin/bash
# ============================================================
# Podsys Lite - initrd casper 注入脚本
# 在管理节点上运行，将 casper 模块注入到黄金机产出的 initrd 中。
# 使用 Docker 容器获取 casper 文件，不污染管理节点系统。
#
# 用法:
#   bash scripts/inject_casper.sh workspace/liveos/initrd
# ============================================================
set -e

INITRD_PATH="${1:-workspace/liveos/initrd}"

if [ ! -f "$INITRD_PATH" ]; then
    echo "[ERROR] initrd not found: $INITRD_PATH"
    exit 1
fi

echo "============================================"
echo "  Podsys Lite - Casper Injection"
echo "  Target: $INITRD_PATH"
echo "============================================"

# ---- 检查是否已包含 casper ----
echo ""
echo "[1/3] Checking if casper already exists..."
if command -v lsinitramfs &>/dev/null; then
    if lsinitramfs "$INITRD_PATH" 2>/dev/null | grep -q 'casper'; then
        echo "  [OK] casper already present, no injection needed"
        exit 0
    fi
fi
echo "  Casper not found, proceeding with injection..."

# ---- 创建工作目录 ----
WORK_DIR=$(mktemp -d /tmp/podsys-initrd-XXXXXX)
echo ""
echo "[2/3] Extracting initrd to $WORK_DIR ..."

# 检测压缩格式
MAGIC=$(xxd -l 4 -p "$INITRD_PATH" 2>/dev/null || file "$INITRD_PATH")

cd "$WORK_DIR"

# Ubuntu 24.04 默认用 zstd 压缩的 cpio
if zstd -t "$INITRD_PATH" 2>/dev/null; then
    zstd -d -c "$INITRD_PATH" | cpio -idm 2>/dev/null
elif gzip -t "$INITRD_PATH" 2>/dev/null; then
    zcat "$INITRD_PATH" | cpio -idm 2>/dev/null
elif xz -t "$INITRD_PATH" 2>/dev/null; then
    xzcat "$INITRD_PATH" | cpio -idm 2>/dev/null
elif lz4 -t "$INITRD_PATH" 2>/dev/null; then
    lz4 -d -c "$INITRD_PATH" | cpio -idm 2>/dev/null
else
    # 尝试直接 cpio
    cpio -idm < "$INITRD_PATH" 2>/dev/null || {
        echo "[ERROR] Cannot decompress initrd. Unsupported format."
        rm -rf "$WORK_DIR"
        exit 1
    }
fi

echo "  [OK] Extracted $(find . -type f | wc -l) files"

# ---- 从 Docker 容器获取 casper 文件 ----
echo ""
echo "[3/3] Getting casper files from Docker container..."

# 确保目标目录存在
mkdir -p usr/share/initramfs-tools/scripts
mkdir -p usr/lib/casper
mkdir -p etc/casper
mkdir -p scripts

docker run --rm \
    --platform linux/arm64 \
    -v "$WORK_DIR:/work" \
    ubuntu:24.04 \
    bash -c '
        set -e
        apt-get update -qq
        apt-get install -y -qq casper lupin-casper 2>/dev/null || apt-get install -y -qq casper

        # 复制 casper initramfs 脚本
        if [ -d /usr/share/initramfs-tools/scripts/casper* ]; then
            cp -a /usr/share/initramfs-tools/scripts/casper* /work/usr/share/initramfs-tools/scripts/ 2>/dev/null || true
        fi
        if [ -d /usr/share/initramfs-tools/scripts/casper ]; then
            cp -a /usr/share/initramfs-tools/scripts/casper /work/usr/share/initramfs-tools/scripts/ 2>/dev/null || true
        fi

        # 复制 casper 库文件
        if [ -d /usr/lib/casper ]; then
            cp -a /usr/lib/casper /work/usr/lib/ 2>/dev/null || true
        fi

        # 复制 casper 配置
        if [ -f /etc/casper.conf ]; then
            cp /etc/casper.conf /work/etc/casper/ 2>/dev/null || true
        fi

        # 复制 casper 相关的 udev 规则
        if [ -d /lib/udev/rules.d ]; then
            mkdir -p /work/lib/udev/rules.d
            cp /lib/udev/rules.d/*casper* /work/lib/udev/rules.d/ 2>/dev/null || true
        fi

        # 复制 casper 二进制
        for bin in casper-md5check casper-snapshot casper-getty; do
            if [ -f /usr/bin/$bin ]; then
                mkdir -p /work/usr/bin
                cp /usr/bin/$bin /work/usr/bin/ 2>/dev/null || true
            fi
        done
        if [ -f /usr/lib/casper/casper-bottom ]; then
            cp -a /usr/lib/casper /work/usr/lib/ 2>/dev/null || true
        fi

        echo "Casper files copied"
    ' 2>&1 || {
    echo "[WARNING] Docker casper extraction had issues"
    echo "  Trying alternative: install casper on host..."
    apt-get update -qq && apt-get install -y -qq casper 2>/dev/null || true
    if [ -d /usr/share/initramfs-tools/scripts/casper ]; then
        cp -a /usr/share/initramfs-tools/scripts/casper "$WORK_DIR/usr/share/initramfs-tools/scripts/"
    fi
    if [ -d /usr/lib/casper ]; then
        cp -a /usr/lib/casper "$WORK_DIR/usr/lib/"
    fi
}

# ---- 添加 casper 启动脚本到 init 阶段 ----
# 确保 init 脚本在启动时加载 casper
if [ -f init ] && [ -d usr/share/initramfs-tools/scripts ]; then
    # 在 init 脚本中添加 casper 脚本的 source
    if ! grep -q 'casper' init 2>/dev/null; then
        # 在 init 脚本中找合适的插入点
        if grep -q 'maybe_break init' init 2>/dev/null; then
            sed -i '/maybe_break init/a\
# Casper LiveOS support\
for cs in /usr/share/initramfs-tools/scripts/casper*; do\
    [ -f "$cs" ] && . "$cs"\
done' init
        fi
    fi
fi

# ---- 重新打包 ----
BACKUP="${INITRD_PATH}.backup.$(date +%Y%m%d%H%M%S)"
cp "$INITRD_PATH" "$BACKUP"
echo "  Backup: $BACKUP"

# 使用与原格式一致的压缩方式重新打包
find . | cpio -o -H newc 2>/dev/null | zstd -T0 > "$INITRD_PATH"

echo ""
echo "============================================"
echo "  Casper injection complete!"
echo "============================================"
echo ""
echo "Original initrd backed up to: $BACKUP"
echo "New initrd: $INITRD_PATH ($(du -h "$INITRD_PATH" | cut -f1))"

# 验证
if command -v lsinitramfs &>/dev/null; then
    if lsinitramfs "$INITRD_PATH" 2>/dev/null | grep -q 'casper'; then
        echo "[OK] Verified: casper is now in initrd"
    else
        echo "[WARNING] Casper may not be properly injected"
    fi
fi

# 清理
rm -rf "$WORK_DIR"
echo ""
