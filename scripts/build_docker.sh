#!/bin/bash
# ============================================================
# Podsys Lite - Docker 镜像构建脚本
# 在管理节点上运行，构建 ainexus-lite Docker 镜像
#
# 用法:
#   bash scripts/build_docker.sh [--arch amd64|arm64]
#
# 输出:
#   ainexus-lite      (amd64 镜像 tar)
#   ainexus-lite-arm  (arm64 镜像 tar)
# ============================================================
set -e

cd "$(dirname "$0")/.."

ARCH="${1:-amd64}"
if [ "$1" = "--arch" ]; then
    ARCH="$2"
fi

IMAGE_NAME="ainexus-lite"
IMAGE_TAG="v2.0"

echo "============================================"
echo "  Podsys Lite - Docker Image Builder"
echo "  Architecture: $ARCH"
echo "  Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "============================================"

# 检查 Docker
if ! command -v docker &>/dev/null; then
    echo "[ERROR] Docker is not installed."
    echo "  Install: curl -fsSL https://get.docker.com | bash"
    exit 1
fi

# 确认必要文件存在
REQUIRED_FILES=(
    "docker/Dockerfile"
    "docker/dnsmasq.conf"
    "docker/nginx-podsys.conf"
    "docker/entrypoint.sh"
    "ipxe/menu.ipxe"
    "ipxe/install.ipxe"
    "ipxe/liveos.ipxe"
)
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "[ERROR] Missing required file: $f"
        exit 1
    fi
done
echo "[OK] All required files present"

# 构建镜像
echo ""
echo "Building Docker image..."
docker build \
    --platform "linux/${ARCH}" \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -f docker/Dockerfile \
    .

echo ""
echo "Build complete: ${IMAGE_NAME}:${IMAGE_TAG}"

# 导出镜像
case "$ARCH" in
    amd64|x86_64)
        OUTPUT_FILE="ainexus-lite"
        ;;
    arm64|aarch64)
        OUTPUT_FILE="ainexus-lite-arm"
        ;;
    *)
        echo "[ERROR] Unknown architecture: $ARCH"
        exit 1
        ;;
esac

echo ""
echo "Exporting image to $OUTPUT_FILE ..."
docker save "${IMAGE_NAME}:${IMAGE_TAG}" -o "${OUTPUT_FILE}.tar"
echo "  [OK] ${OUTPUT_FILE}.tar ($(du -h ${OUTPUT_FILE}.tar | cut -f1))"

# 可选：也导出为 docker import 兼容格式
echo ""
echo "Creating flattened image for docker import..."
CONTAINER_ID=$(docker create "${IMAGE_NAME}:${IMAGE_TAG}")
docker export "$CONTAINER_ID" -o "$OUTPUT_FILE"
docker rm "$CONTAINER_ID" >/dev/null
echo "  [OK] $OUTPUT_FILE ($(du -h $OUTPUT_FILE | cut -f1))"

echo ""
echo "============================================"
echo "  Build complete!"
echo "============================================"
echo ""
echo "Files produced:"
echo "  ${OUTPUT_FILE}.tar  - docker save (full layers)"
echo "  ${OUTPUT_FILE}      - docker export (flattened, for docker import)"
echo ""
echo "To test the image locally:"
echo "  docker run --privileged --network=host \\"
echo "    -v \$PWD/workspace:/workspace \\"
echo "    -v \$PWD/ipxe:/tftp/ipxe \\"
echo "    ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
