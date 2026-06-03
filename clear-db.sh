#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

echo "=== 清空 Jarvis SQLite 数据库 ==="

# 检查 data 目录是否存在
if [[ ! -d "$DATA_DIR" ]]; then
    echo "data/ 目录不存在，无需清空。"
    exit 0
fi

# 提示确认
echo "这将删除以下内容："
echo "  - $DATA_DIR/index.db       (数据库)"
echo "  - $DATA_DIR/index.db-wal   (WAL 日志)"
echo "  - $DATA_DIR/index.db-shm   (共享内存)"
echo "  - $DATA_DIR/memos/         (备忘录文件)"
echo "  - $DATA_DIR/reminders/      (提醒文件)"
echo "  - $DATA_DIR/uploads/       (上传文件)"
echo "  - $DATA_DIR/vault/         (保险库文件)"
echo ""
echo "保留: config.yaml, credentials.yaml"
echo ""

read -rp "确认清空？输入 yes 继续: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "已取消。"
    exit 0
fi

# 删除 SQLite 数据库文件
echo -n "删除数据库文件... "
rm -f "$DATA_DIR/index.db" "$DATA_DIR/index.db-wal" "$DATA_DIR/index.db-shm"
echo "完成"

# 清空子目录
echo -n "清空数据子目录... "
rm -rf "$DATA_DIR/memos"/* "$DATA_DIR/reminders"/* "$DATA_DIR/uploads"/* "$DATA_DIR/vault"/* 2>/dev/null || true
echo "完成"

echo ""
echo "数据库已清空。下次启动服务器时将自动重建。"
