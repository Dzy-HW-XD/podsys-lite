#!/bin/bash
# patch_initrd.sh - Patch Ubuntu Server initrd for LiveOS boot
#
# Ubuntu Server ISO's initrd contains /scripts/init-bottom/live-server
# which hardcodes mount of ubuntu-server-minimal.squashfs layers.
# For custom LiveOS ISOs, these files don't exist and the script causes
# mount failures leading to kernel panic.
#
# This script removes the server-specific squashfs mount commands from
# the initrd, keeping only the kernel-meta-package write.
#
# Usage: sudo bash scripts/patch_initrd.sh <input-initrd> <output-initrd>
#
# Example:
#   sudo bash scripts/patch_initrd.sh tftp-root/liveos-initrd tftp-root/liveos-initrd.patched
#   mv tftp-root/liveos-initrd.patched tftp-root/liveos-initrd

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <input-initrd> [output-initrd]"
    echo "  If output-initrd is not specified, patches in-place (creates backup first)"
    exit 1
fi

INPUT_INITRD="$(readlink -f "$1")"
if [ ! -f "$INPUT_INITRD" ]; then
    echo "Error: Input initrd not found: $INPUT_INITRD"
    exit 1
fi

if [ -n "${2:-}" ]; then
    OUTPUT_INITRD="$(readlink -f "$2")"
else
    OUTPUT_INITRD="$INPUT_INITRD"
    cp "$INPUT_INITRD" "${INPUT_INITRD}.bak"
    echo "Backup created: ${INPUT_INITRD}.bak"
fi

WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo "Extracting initrd..."
cd "$WORKDIR"
mkdir -p early main

# Ubuntu initrd format: early uncompressed cpio + main gzip-compressed cpio
# Split at the gzip magic bytes (1f 8b)
python3 -c "
import sys
data = open('$INPUT_INITRD', 'rb').read()
# Find gzip magic bytes
idx = data.find(b'\x1f\x8b')
if idx < 0:
    print('ERROR: No gzip magic found in initrd', file=sys.stderr)
    sys.exit(1)
open('early.cpio', 'wb').write(data[:idx])
open('main.gz', 'wb').write(data[idx:])
print(f'Split at offset {idx}: early={idx} bytes, main={len(data)-idx} bytes')
"

echo "Unpacking early cpio..."
cd "$WORKDIR/early"
cpio -id < "$WORKDIR/early.cpio" 2>/dev/null

echo "Unpacking main cpio+gzip..."
cd "$WORKDIR/main"
zcat "$WORKDIR/main.gz" | cpio -id 2>/dev/null

# Check if live-server script exists
LIVE_SERVER="$WORKDIR/main/scripts/init-bottom/live-server"
if [ -f "$LIVE_SERVER" ]; then
    echo "Found live-server script, current content:"
    echo "---"
    cat "$LIVE_SERVER"
    echo "---"
    
    # Replace with minimal version (no squashfs mounts)
    cat > "$LIVE_SERVER" << 'PATCHED'
#!/bin/sh
case $1 in
prereqs) exit 0;;
esac

echo linux-generic > /run/kernel-meta-package
PATCHED
    chmod +x "$LIVE_SERVER"
    echo "Patched live-server script (removed squashfs mount commands)"
else
    echo "WARNING: live-server script not found in initrd, skipping patch"
fi

echo "Repacking initrd..."
cd "$WORKDIR/early"
find . | cpio --quiet -o -H newc > "$WORKDIR/early-new.cpio" 2>/dev/null

cd "$WORKDIR/main"
find . | cpio --quiet -o -H newc 2>/dev/null | gzip -9 > "$WORKDIR/main-new.gz"

cat "$WORKDIR/early-new.cpio" "$WORKDIR/main-new.gz" > "$OUTPUT_INITRD"

echo "Done! Patched initrd: $OUTPUT_INITRD"
ls -la "$OUTPUT_INITRD"
