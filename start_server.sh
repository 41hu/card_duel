#!/bin/bash
# Card Duel 服务端启动脚本（用于 Ubuntu 26.04 服务器）
# 使用方式: ./start_server.sh

GODOT_BIN="${GODOT_BIN:-godot}"
PORT="${PORT:-8080}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Card Duel 服务端 ==="
echo "项目目录: $PROJECT_DIR"
echo "监听端口: $PORT"
echo ""

# 以 headless 模式运行服务端场景
"$GODOT_BIN" --headless --path "$PROJECT_DIR" scenes/server.tscn

echo "服务端已停止"
