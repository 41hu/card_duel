#!/bin/bash
# Card Duel 服务器部署脚本 (Ubuntu 26.04)
# 用法: bash deploy.sh

set -e

echo "=== Card Duel 服务器部署 ==="

# 1. 安装 Godot 4.7.1 (headless)
GODOT_URL="https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_linux.x86_64.zip"
GODOT_DIR="$HOME/godot"
GODOT_BIN="$GODOT_DIR/Godot_v4.7.1-stable_linux.x86_64"

if [ ! -f "$GODOT_BIN" ]; then
    echo "下载 Godot 4.7.1..."
    mkdir -p "$GODOT_DIR"
    wget -q "$GODOT_URL" -O /tmp/godot.zip
    unzip -o /tmp/godot.zip -d "$GODOT_DIR"
    chmod +x "$GODOT_BIN"
    echo "Godot 安装完成"
else
    echo "Godot 已安装"
fi

# 2. 克隆/更新项目
PROJECT_DIR="$HOME/card_duel"
if [ -d "$PROJECT_DIR/.git" ]; then
    echo "更新项目..."
    cd "$PROJECT_DIR" && git pull
else
    echo "克隆项目..."
    git clone https://github.com/41hu/card_duel.git "$PROJECT_DIR"
fi

# 3. 启动服务端
echo "启动服务端 (端口 17890)..."
cd "$PROJECT_DIR"
nohup "$GODOT_BIN" --headless --path "$PROJECT_DIR" scenes/server.tscn > server.log 2>&1 &
echo "PID: $!"
echo "日志: $PROJECT_DIR/server.log"
echo "=== 部署完成 ==="
