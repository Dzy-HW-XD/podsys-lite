#!/bin/bash
set -e

echo "=== Podsys Lite Container Starting ==="

# 读取配置
CONFIG_FILE="/workspace/config.yaml"
if [ -f "$CONFIG_FILE" ]; then
    MANAGER_IP=$(grep "manager_ip" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    DHCP_S=$(grep "dhcp_s" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    DHCP_E=$(grep "dhcp_e" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    MANAGER_NIC=$(grep "manager_nic" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
    LIVEOS_ENABLE=$(grep "liveos_enable" "$CONFIG_FILE" | cut -d ":" -f 2 | tr -d '[:space:]')
else
    echo "[WARNING] config.yaml not found, using defaults"
    MANAGER_IP="192.168.100.1"
    DHCP_S="192.168.100.10"
    DHCP_E="192.168.100.20"
    MANAGER_NIC=""
    LIVEOS_ENABLE="no"
fi

echo "  manager_ip: ${MANAGER_IP:-auto}"
echo "  dhcp_range: ${DHCP_S:-auto} - ${DHCP_E:-auto}"
echo "  liveos_enable: ${LIVEOS_ENABLE:-no}"

# 生成 dnsmasq 运行时配置
DNSMASQ_RUN="/etc/dnsmasq.run.conf"
cp /etc/dnsmasq.conf "$DNSMASQ_RUN"

# 替换 DHCP 范围
if [ -n "$DHCP_S" ] && [ -n "$DHCP_E" ]; then
    sed -i "s|dhcp-range=.*|dhcp-range=${DHCP_S},${DHCP_E},12h|" "$DNSMASQ_RUN"
fi

# 替换网关（DHCP option 3）
if [ -n "$MANAGER_IP" ]; then
    sed -i "s|dhcp-option=3,.*|dhcp-option=3,${MANAGER_IP}|" "$DNSMASQ_RUN"
    # 同时替换 HTTP Boot URL 中的 IP
    sed -i "s|http://0.0.0.0:5001|http://${MANAGER_IP}:5001|g" "$DNSMASQ_RUN"
fi

# 绑定网卡
if [ -n "$MANAGER_NIC" ]; then
    echo "interface=${MANAGER_NIC}" >> "$DNSMASQ_RUN"
fi

# 检查 LiveOS 文件
LIVEOS_DIR="/workspace/liveos"
if [ "$LIVEOS_ENABLE" = "yes" ] || [ "$LIVEOS_ENABLE" = "true" ]; then
    echo "[LiveOS] Checking LiveOS files..."
    MISSING=""
    [ -f "$LIVEOS_DIR/vmlinuz" ] || MISSING="$MISSING vmlinuz"
    [ -f "$LIVEOS_DIR/initrd" ] || MISSING="$MISSING initrd"
    [ -f "$LIVEOS_DIR/filesystem.squashfs" ] || MISSING="$MISSING filesystem.squashfs"
    if [ -n "$MISSING" ]; then
        echo "[LiveOS] WARNING: Missing files:${MISSING}"
        echo "[LiveOS] Place them in workspace/liveos/ on the host"
    else
        echo "[LiveOS] All files present, LiveOS mode ready"
    fi
fi

# 启动 nginx
echo "=== Starting nginx ==="
nginx -t
nginx

# 启动 dnsmasq
echo "=== Starting dnsmasq ==="
exec dnsmasq -d -C "$DNSMASQ_RUN" --log-facility=/var/log/podsys/dnsmasq.log
