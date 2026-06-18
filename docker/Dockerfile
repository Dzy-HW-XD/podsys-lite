FROM ubuntu:24.04

LABEL maintainer="podsys-lite"
LABEL description="Podsys Lite - Network boot system with LiveOS support for GB300"

ENV DEBIAN_FRONTEND=noninteractive

# 安装核心服务
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
    && rm -rf /var/lib/apt/lists/*

# 目录结构
RUN mkdir -p /tftp/ipxe /tftp/casper /workspace /var/log/podsys

# --- x86 iPXE 引导文件（从 ipxe 包复制） ---
RUN cp /usr/lib/ipxe/undionly.kpxe      /tftp/undionly.kpxe 2>/dev/null || true && \
    cp /usr/lib/ipxe/ipxe.efi            /tftp/ipxe.efi 2>/dev/null || true && \
    cp /usr/lib/ipxe/snponly.efi         /tftp/snponly.efi 2>/dev/null || true

# --- iPXE 引导菜单脚本 ---
COPY ipxe/ /tftp/ipxe/

# --- ARM64 GRUB 引导器（从 ISO 提取 grubaa64.efi 放入 tftp-grub/） ---
# 注意：grubaa64.efi 和 grub.cfg 不打进镜像，通过 tftp-root 挂载提供
# 这样可以在不重建镜像的情况下更新配置

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
