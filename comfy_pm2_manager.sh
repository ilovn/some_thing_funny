#!/bin/bash

# ============================================================
# ComfyUI PM2 Cluster Manager (v2.6 - 生产环境稳健版)
# ============================================================
# 核心特性:
# 1. 安全性：使用正则精确匹配，绝不影响机器上 easytier, frpc 等非相关任务。
# 2. 兼容性：直接调用 Python main.py，规避 comfy-cli 版本解析 Bug。
# 3. 性能：针对 RTX 3090 注入 bf16 加速、高显存预留和跨注意力优化。
# 4. 健壮性：内置 PM2 自动重启 + HTTP 假死监测双重守护。
# ============================================================

set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

show_help() {
    echo "ComfyUI PM2 管理脚本"
    echo "用法: $0 {install|uninstall|status}"
    exit 0
}

# 1. 安装与配置
do_install() {
    echo -e "${GREEN}>>> 开始配置 ComfyUI 集群服务...${NC}"

    # 路径获取
    read -p "1. ComfyUI 目录路径 (当前: /ai/mnt/comfyui): " WORKSPACE
    WORKSPACE=${WORKSPACE:-/ai/mnt/comfyui}
    
    read -p "2. pyenv 虚拟环境名称 (默认: comfyui): " PYENV_NAME
    PYENV_NAME=${PYENV_NAME:-comfyui}
    
    USER_HOME=$(eval echo "~$USER")
    PYTHON_EXE="$USER_HOME/.pyenv/versions/$PYENV_NAME/bin/python"
    MAIN_PY="$WORKSPACE/main.py"
    
    if [ ! -f "$PYTHON_EXE" ]; then
        echo -e "${RED}错误: 未找到 Python 路径: $PYTHON_EXE${NC}"
        exit 1
    fi
    if [ ! -f "$MAIN_PY" ]; then
        echo -e "${RED}错误: $WORKSPACE 目录下未找到 main.py${NC}"
        exit 1
    fi

    read -p "3. 实例总数 (例如: 2): " INSTANCE_COUNT

    # 准备 PM2 配置文件
    CONFIG_FILE="$WORKSPACE/ecosystem.config.js"
    echo "module.exports = { apps: [" > $CONFIG_FILE

    declare -a PORTS
    for ((i=1; i<=INSTANCE_COUNT; i++)); do
        echo -e "\n--- 配置实例 #$i ---"
        read -p "监听端口 (如 8188): " PORT
        read -p "显卡 ID (3090 编号，如 5): " GPU_ID
        PORTS+=($PORT)

        # 构建配置对象
        # 注意：不再传递不受支持的 --device-id，通过环境变量锁定显卡
        cat <<EOF >> $CONFIG_FILE
    {
      name: "comfy-$PORT",
      cwd: "$WORKSPACE",
      script: "$MAIN_PY",
      interpreter: "$PYTHON_EXE",
      args: "--port $PORT --highvram --bf16-unet --use-pytorch-cross-attention --listen 0.0.0.0",
      env: {
        CUDA_VISIBLE_DEVICES: "$GPU_ID",
        PYTHONUNBUFFERED: "1"
      },
      autorestart: true,
      max_memory_restart: '22G'
    },
EOF
    done
    echo "  ] };" >> $CONFIG_FILE

    # 2. 生成监控脚本 (解决 ComfyUI 假死不退出的问题)
    WATCHDOG_PATH="$WORKSPACE/comfy_watchdog.sh"
    cat <<EOF > $WATCHDOG_PATH
#!/bin/bash
# ComfyUI HTTP 存活监测
PORTS=(${PORTS[@]})
while true; do
  for PORT in "\${PORTS[@]}"; do
    # 3090 推理有时较慢，设置 15s 超时阈值
    HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 http://127.0.0.1:\$PORT/)
    if [ "\$HTTP_CODE" -ne 200 ]; then
        echo "\$(date): 端口 \$PORT 响应异常 (\$HTTP_CODE)，正在通过 PM2 重启..." >> "$WORKSPACE/watchdog.log"
        pm2 restart "comfy-\$PORT"
    fi
  done
  sleep 60
done
EOF
    chmod +x $WATCHDOG_PATH

    # 3. 启动流程 (安全模式)
    echo -e "${GREEN}>>> 正在同步 PM2 状态...${NC}"
    cd "$WORKSPACE"
    # 【安全修复】仅删除 comfy 相关任务，不影响 easytier/frpc/ollama 等
    pm2 delete /comfy-.*/ 2>/dev/null || true
    
    pm2 start ecosystem.config.js
    pm2 start comfy_watchdog.sh --name "comfy-monitor"
    pm2 save

    echo -e "\n${GREEN}================================================${NC}"
    echo -e "部署完成！当前 3090 集群状态："
    pm2 list | grep "comfy"
    echo -e "------------------------------------------------"
    echo -e "负载均衡 (Caddyfile) 建议配置:"
    echo ":80 {"
    echo "    reverse_proxy {"
    echo "        to $(for p in "${PORTS[@]}"; do echo -n "127.0.0.1:$p "; done)"
    echo "        lb_policy least_conn"
    echo "    }"
    echo "}"
    echo -e "================================================${NC}"
}

# 4. 卸载/清理
do_uninstall() {
    echo -e "${RED}>>> 正在清理 ComfyUI 实例...${NC}"
    pm2 delete /comfy-.*/ 2>/dev/null || true
    pm2 save --force
    echo -e "${GREEN}清理完毕。${NC}"
}

case "$1" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    pm2 list | grep "comfy" ;;
    *)         show_help ;;
esac