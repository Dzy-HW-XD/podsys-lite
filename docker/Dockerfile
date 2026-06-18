FROM ubuntu:24.04

LABEL maintainer="podsys-lite"
LABEL description="Podsys Lite - Network boot system with LiveOS support for GB300"

ENV DEBIAN_FRONTEND=noninteractive

# 安装核心服务 + GRUB ARM64 构建工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    nginx \
    ipxe \
    syslinux-common \
    curl \
    wget \
    ca-certificates \
    vim \
    net-tools \
    iproute2 \
    tcpdump \
    procps \
    grub-efi-arm64-bin \
    && rm -rf /var/lib/apt/lists/*

# 目录结构
RUN mkdir -p /tftp/ipxe /tftp/casper /tftp/boot/grub /workspace /var/log/podsys

# --- x86 iPXE 引导文件（从 ipxe 包复制） ---
RUN cp /usr/lib/ipxe/undionly.kpxe      /tftp/undionly.kpxe 2>/dev/null || true && \
    cp /usr/lib/ipxe/ipxe.efi            /tftp/ipxe.efi 2>/dev/null || true && \
    cp /usr/lib/ipxe/snponly.efi         /tftp/snponly.efi 2>/dev/null || true

# --- 构建内嵌 TFTP 前缀的 grubaa64.efi ---
# ISO 原始 grubaa64.efi 的 prefix 指向本地磁盘，PXE 启动找不到 grub.cfg
# 用 grub-mkimage 重建，内嵌早期配置设置 root=(tftp) prefix=(tftp)/boot/grub
RUN cat > /tmp/grub-early.cfg <<'EARLYEOF' \
    && grub-mkimage \
        -O arm64-efi \
        -o /tftp/grubaa64.efi \
        -p "(tftp)/boot/grub" \
        -c /tmp/grub-early.cfg \
        normal configfile tftp efinet net linux search echo boot gzio xzio gettext ls test true false part_gpt fat ext2 \
    && rm -f /tmp/grub-early.cfg
set root=(tftp)
set prefix=(tftp)/boot/grub
configfile ${prefix}/grub.cfg
EARLYEOF

# --- iPXE 引导菜单脚本 ---
COPY ipxe/ /tftp/ipxe/

# --- dnsmasq 配置 ---
COPY docker/dnsmasq.conf /etc/dnsmasq.conf

# --- nginx 配置 ---
COPY docker/nginx-podsys.conf /etc/nginx/sites-available/podsys
RUN rm -f /etc/nginx/sites-enabled/default && \
    ln -s /etc/nginx/sites-available/podsys /etc/nginx/sites-enabled/podsys

# --- 入口脚本 ---
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# --- 辅助脚本 ---
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

EXPOSE 67/udp 69/udp 5001

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
