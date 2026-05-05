#!/bin/bash

# ============================================================
# Caddy PM2 自动化部署脚本 (v1.5 - 端口修正版)
# ============================================================

set -e
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 1. 下载与安装逻辑 (保持 v1.4 的稳定下载源)
install_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        echo -e "${GREEN}>>> Caddy 已安装，跳过。${NC}"
    else
        echo -e "${GREEN}>>> 正在下载 Caddy 二进制文件...${NC}"
        URL="https://mirror.ghproxy.com/https://github.com/caddyserver/caddy/releases/download/v2.7.6/caddy_2.7.6_linux_amd64.tar.gz"
        if curl -L "$URL" -o caddy.tar.gz; then
            tar -zxvf caddy.tar.gz caddy
            mv caddy /usr/bin/ && chmod +x /usr/bin/caddy
            rm caddy.tar.gz
        else
            echo -e "${RED}下载失败，请参考脚本内帮助信息手动安装。${NC}"
            exit 1
        fi
    fi
}

# 2. 生成 Caddyfile (核心修正：端口前缀冒号)
configure_caddy() {
    echo -e "${GREEN}>>> 正在配置负载均衡规则...${NC}"
    
    CADDYFILE_PATH="$(pwd)/Caddyfile"
    
    read -p "监听端口 (默认 80): " SITE_PORT
    SITE_PORT=${SITE_PORT:-80}
    # 确保监听地址以冒号开头
    [[ $SITE_PORT != :* ]] && LISTEN_ADDR=":$SITE_PORT" || LISTEN_ADDR="$SITE_PORT"
    
    read -p "后端 ComfyUI 端口 (空格分隔): " PORTS
    if [ -z "$PORTS" ]; then exit 1; fi

    BACKENDS=""
    for p in $PORTS; do
        # 确保后端地址格式为 127.0.0.1:端口
        [[ $p == :* ]] && clean_p=${p#:} || clean_p=$p
        BACKENDS="$BACKENDS 127.0.0.1:$clean_p"
    done

    cat <<EOF > "$CADDYFILE_PATH"
$LISTEN_ADDR {
    encode gzip
    reverse_proxy {
        to $BACKENDS
        lb_policy least_conn
        health_uri /
        health_interval 10s
        transport http {
            read_timeout 600s
            write_timeout 600s
        }
    }
    request_body {
        max_size 1GB
    }
}
EOF
    echo -e "${GREEN}>>> Caddyfile 已修正生成。${NC}"
}

# 3. PM2 启动
start_pm2() {
    CADDY_BIN=$(which caddy)
    pm2 delete caddy 2>/dev/null || true
    pm2 start "$CADDY_BIN" --name "caddy" -- run --config "$(pwd)/Caddyfile" --adapter caddyfile
    pm2 save
    echo -e "${GREEN}>>> Caddy 已通过 PM2 启动。${NC}"
}

install_caddy
configure_caddy
start_pm2