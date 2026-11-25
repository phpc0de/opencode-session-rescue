#!/usr/bin/env bash
set -euo pipefail

# OpenCode v2.x (e.g. v2.3.2) Session Database Auto-Rescue Tool for Linux (ext4)
# Usage:
#   sudo ./opencode-rescue.sh           # Scan & recover to /dev/shm (dry-run, safe)
#   sudo ./opencode-rescue.sh --apply   # Verify, stop OpenCode, backup current DB & restore

APPLY=0
MIN_SIZE=$((64 * 1024)) # 64 KB
CUSTOM_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --min-size) MIN_SIZE="$2"; shift 2 ;;
    --data-dir) CUSTOM_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 [--apply] [--data-dir PATH] [--min-size BYTES]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo "❌ 请使用 sudo 运行此脚本（需要只读访问底层块设备）：sudo $0 $*"
  exit 1
fi

for cmd in debugfs sqlite3 df awk sort dd tune2fs; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ 缺少必要工具: $cmd（请先安装 e2fsprogs / sqlite3）"
    exit 1
  fi
done

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

DATA_DIR="${CUSTOM_DIR:-${XDG_DATA_HOME:-$TARGET_HOME/.local/share}/opencode}"
if [[ ! -d "$DATA_DIR" ]]; then
  echo "❌ 未找到 OpenCode 数据目录: $DATA_DIR"
  exit 1
fi

REAL_DIR="$(readlink -f "$DATA_DIR")"
DEV="$(df --output=source "$REAL_DIR" | tail -n 1)"
FSTYPE="$(df --output=fstype "$REAL_DIR" | tail -n 1)"

if [[ "$FSTYPE" != "ext4" || ! -b "$DEV" ]]; then
  echo "❌ 当前仅支持本地 ext4 文件系统（检测到 $REAL_DIR 位于 $DEV [$FSTYPE]）"
  exit 1
fi

BLKSIZE="$(tune2fs -l "$DEV" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}')"
BLKSIZE="${BLKSIZE:-4096}"

WORKDIR="/dev/shm/opencode-rescue-$$"
mkdir -p "$WORKDIR"

echo "=================================================="
echo " OpenCode v2 数据库自动抢救工具 (ext4)"
echo " 用户: $TARGET_USER (UID=$TARGET_UID)"
echo " 目录: $REAL_DIR"
echo " 设备: $DEV (ext4, block=${BLKSIZE}B)"
echo " 暂存: $WORKDIR (纯内存操作，不污染原硬盘)"
echo "=================================================="

# 1. 查找 UID 匹配且大于阈值的已清理 inode，按文件大小降序排列
mapfile -t CANDIDATES < <(
  debugfs -R "lsdel" "$DEV" 2>/dev/null \
  | awk -v uid="$TARGET_UID" -v min="$MIN_SIZE" '
      $1 ~ /^[0-9]+$/ && $2 == uid && $4 ~ /^[0-9]+$/ && $4 >= min { print $1, $4 }
    ' \
  | sort -k2 -nr \
  | head -n 30
)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "⚠️ 未在 $DEV 的 lsdel 中发现可恢复的被删 inode。"
  echo "   可能原因：已触发 SSD TRIM/discard，或文件块指针已被彻底擦除。"
  exit 1
fi

BEST_CLEAN=""
BEST_CNT=0
BEST_INO=""

for entry in "${CANDIDATES[@]}"; do
  ino="${entry%% *}"
  sz="${entry##* }"

  # 先读第 0 个逻辑块检查是否为 SQLite 文件，避免把大体积非 DB 缓存导出到内存
  stat_out="$(debugfs -R "stat <$ino>" "$DEV" 2>/dev/null || true)"
  first_blk="$(echo "$stat_out" | grep -oE '\(0(-[0-9]+)?\):[0-9]+' | head -n 1 | cut -d: -f2 || true)"
  [[ -z "$first_blk" ]] && continue

  magic="$(dd if="$DEV" bs="$BLKSIZE" skip="$first_blk" count=1 status=none 2>/dev/null | head -c 15 | tr -d '\0' || true)"
  [[ "$magic" != "SQLite format 3" ]] && continue

  # 检查 /dev/shm 剩余空间是否充足
  shm_avail_kb="$(df --output=avail /dev/shm | tail -n 1)"
  need_kb=$(( sz / 1024 + 65536 ))
  if (( shm_avail_kb < need_kb )); then
    echo "⚠️ 跳过 inode $ino (${sz}B)：/dev/shm 可用空间不足"
    continue
  fi

  raw_file="$WORKDIR/inode_${ino}.db"
  clean_file="$WORKDIR/clean_${ino}.db"

  echo "🔍 发现候选 SQLite 文件: inode=$ino, size=$((sz / 1024 / 1024))MB, 正在导出检验..."
  debugfs -R "dump <$ino> $raw_file" "$DEV" >/dev/null 2>&1 || continue

  tables="$(sqlite3 -readonly "$raw_file" ".tables" 2>/dev/null || true)"
  if ! echo "$tables" | grep -qwE "session_v2|session"; then
    echo "   -> 非 OpenCode 会话库，跳过"
    rm -f "$raw_file"
    continue
  fi

  chk="$(sqlite3 -readonly "$raw_file" "PRAGMA integrity_check;" 2>/dev/null | head -n 1 || echo "err")"
  if [[ "$chk" == "ok" ]]; then
    sqlite3 "$raw_file" ".backup '$clean_file'" 2>/dev/null || true
  else
    echo "   -> 检测到受损页 ($chk)，尝试使用 sqlite3 .recover 重组..."
    sqlite3 "$raw_file" ".recover" 2>/dev/null | sqlite3 "$clean_file" 2>/dev/null || true
  fi
  rm -f "$raw_file"

  if [[ ! -s "$clean_file" ]]; then
    echo "   -> 修复失败，跳过"
    continue
  fi

  chk2="$(sqlite3 -readonly "$clean_file" "PRAGMA integrity_check;" 2>/dev/null | head -n 1 || echo "err")"
  cnt_v2="$(sqlite3 -readonly "$clean_file" "SELECT count(*) FROM session_v2;" 2>/dev/null || echo 0)"
  cnt_v1="$(sqlite3 -readonly "$clean_file" "SELECT count(*) FROM session;" 2>/dev/null || echo 0)"
  cnt=$(( cnt_v2 > cnt_v1 ? cnt_v2 : cnt_v1 ))

  echo "   ✅ 校验通过: integrity=$chk2, 发现历史会话数=$cnt (v2=$cnt_v2, v1=$cnt_v1)"

  if [[ "$chk2" == "ok" ]] && (( cnt > BEST_CNT )); then
    BEST_CNT="$cnt"
    BEST_CLEAN="$clean_file"
    BEST_INO="$ino"
  fi
done

if [[ -z "$BEST_CLEAN" || "$BEST_CNT" -eq 0 ]]; then
  echo "❌ 未能从已删除的 SQLite 文件中恢复出有效会话。"
  exit 1
fi

echo ""
echo "🎉 最佳可恢复副本: $BEST_CLEAN (来源 inode=$BEST_INO, 会话数=$BEST_CNT)"

if [[ "$APPLY" -eq 0 ]]; then
  echo "ℹ️ 当前为【预演模式】，未改动你的原文件。"
  echo "   确认无误后，请加上 --apply 参数执行自动替换："
  echo "   sudo $0 --apply"
  exit 0
fi

echo "=== 正在应用恢复到 $DATA_DIR ==="
pkill -u "$TARGET_UID" -f "opencode-desktop" || true
pkill -u "$TARGET_UID" -f "opencode-cli serve" || true
sleep 2

BAK_DIR="$DATA_DIR/rescue_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BAK_DIR"
mv "$DATA_DIR"/opencode.db* "$BAK_DIR"/ 2>/dev/null || true

cp "$BEST_CLEAN" "$DATA_DIR/opencode.db"
chown -R "$TARGET_UID:$TARGET_GID" "$DATA_DIR/opencode.db" "$BAK_DIR"
chmod 600 "$DATA_DIR/opencode.db"

echo "✅ 恢复完成！原空库已备份至: $BAK_DIR"
echo "   已成功恢复 $BEST_CNT 条会话，现在可以重新打开 OpenCode 了。"
