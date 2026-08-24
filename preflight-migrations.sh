#!/usr/bin/env bash
# 数据库迁移预检：对比待部署镜像内 drizzle/ 迁移文件夹与线上迁移表，发现孤儿/缺失记录
# 背景：drizzle-orm v1 migrator 的匹配语义分两种——
#   - v0 迁移表（无 name 列，升级前）：按 created_at（folderMillis）+ hash 匹配，
#     孤儿记录会导致 upgradeIfNeeded 直接 throw → 应用启动即崩（fail-fast）
#   - v1 迁移表（含 name 列）：按完整 name（文件夹名）匹配，孤儿被静默忽略；
#     但 name 对不上（文件夹改名）会被判定未执行 → 迁移重跑 → DDL 冲突崩溃
# 用法：
#   ./preflight-migrations.sh                    # 交互确认后对比 latest 镜像
#   ./preflight-migrations.sh -y                 # 跳过交互确认
#   TAG=v1.1.0 ./preflight-migrations.sh
#   DEPLOY_DIR=/opt/fsdx-web ./preflight-migrations.sh
set -euo pipefail

# 交互确认：仅做只读诊断，不修改任何数据；-y 用于非交互场景
SKIP_CONFIRM=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) SKIP_CONFIRM=1 ;;
    *) echo "未知参数：$arg（仅支持 -y/--yes）" >&2; exit 1 ;;
  esac
done

confirm() {
  [ "$SKIP_CONFIRM" -eq 1 ] && return 0
  local ans
  read -r -p "$1 [y/N] " ans || return 1
  [[ "$ans" =~ ^[yY](es)?$ ]] || return 1
}

DEPLOY_DIR="${DEPLOY_DIR:-/opt/fsdx-web}"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
TAG="${TAG:-latest}"
IMAGE="ghcr.io/easyx-dev/fsdx:${TAG}"

if [ ! -f "$DEPLOY_DIR/.env" ]; then
  echo "未找到 $DEPLOY_DIR/.env，请先创建并填写配置"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$DEPLOY_DIR/.env"
set +a

COMPOSE=(docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR")

confirm "将拉取镜像 ${IMAGE} 并读取线上迁移表（只读诊断，不修改数据），确认继续？" || {
  echo "已取消预检"
  exit 1
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== 1/4 提取待部署镜像内迁移文件夹（${IMAGE}） ==="
docker run --rm --entrypoint ls "$IMAGE" /app/drizzle > "$TMP_DIR/image-names.txt"
echo "镜像内迁移文件夹数: $(wc -l < "$TMP_DIR/image-names.txt" | tr -d ' ')"
# 完整文件夹名（v1 表按 name 匹配用）与时间戳前缀（v0 表按 created_at 匹配用）
sort -u "$TMP_DIR/image-names.txt" > "$TMP_DIR/image-names-sorted.txt"
sed -E 's/^([0-9]{14})_.*/\1/' "$TMP_DIR/image-names.txt" | sort -u > "$TMP_DIR/image-ts.txt"

echo "=== 2/4 读取线上迁移表（db 容器需运行中） ==="
# 检测迁移表版本：v1 表含 name 列，v0 表（旧 drizzle-orm 写入）没有
HAS_NAME=$("${COMPOSE[@]}" exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
  "SELECT count(*) FROM information_schema.columns WHERE table_schema='drizzle' AND table_name='__drizzle_migrations' AND column_name='name'" 2>/dev/null | tr -d ' ' || true)
HAS_NAME="${HAS_NAME:-0}"
if [ "$HAS_NAME" = "1" ]; then
  echo "迁移表为 v1 格式（含 name 列），按完整文件夹名比对"
  "${COMPOSE[@]}" exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
    "SELECT id || ' ' || name FROM drizzle.__drizzle_migrations WHERE name IS NOT NULL ORDER BY created_at" \
    > "$TMP_DIR/db-migrations.txt"
  IMAGE_KEYS="$TMP_DIR/image-names-sorted.txt"
else
  echo "迁移表为 v0 格式（升级前，无 name 列），按 created_at 时间戳比对"
  "${COMPOSE[@]}" exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
    "SELECT id || ' ' || to_char(to_timestamp(created_at/1000.0) AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS') FROM drizzle.__drizzle_migrations ORDER BY created_at" \
    > "$TMP_DIR/db-migrations.txt"
  IMAGE_KEYS="$TMP_DIR/image-ts.txt"
fi
if [ ! -s "$TMP_DIR/db-migrations.txt" ]; then
  echo "警告：未读到迁移记录（迁移表可能为空或查询失败），请检查 db 容器与迁移表"
fi
echo "线上迁移记录数: $(wc -l < "$TMP_DIR/db-migrations.txt" | tr -d ' ')"
awk '{print $2}' "$TMP_DIR/db-migrations.txt" | sort -u > "$TMP_DIR/db-keys.txt"

echo "=== 3/4 孤儿记录（DB 有而镜像无） ==="
echo ""
if comm -23 "$TMP_DIR/db-keys.txt" "$IMAGE_KEYS" | grep -q .; then
  comm -23 "$TMP_DIR/db-keys.txt" "$IMAGE_KEYS" | while read -r key; do
    id=$(awk -v k="$key" '$2 == k {print $1}' "$TMP_DIR/db-migrations.txt" | head -1)
    echo "  id=$id  key=$key  (镜像内无对应迁移文件夹)"
    echo "  => 修复 SQL（人工确认后执行）：DELETE FROM drizzle.__drizzle_migrations WHERE id = $id;"
  done
  echo ""
  if [ "$HAS_NAME" = "1" ]; then
    echo "⚠️  迁移表为 v1：孤儿记录会被 migrator 静默忽略，通常无需处理；"
    echo "    若属迁移文件夹改名遗留（同时间戳不同后缀），会导致该迁移被判定未执行而重跑、DDL 冲突崩溃，建议同步删除。"
  else
    echo "⚠️  迁移表为 v0：升级到 v1 时这些孤儿记录会导致 migrator 直接报错、应用启动即崩，必须处理后再部署。"
    echo "    删除前请先确认该记录确为废弃/合并迁移的残留，并保留备份。"
  fi
else
  echo "  无"
fi

echo ""
echo "=== 4/4 缺失记录（镜像有而 DB 无，即本次待执行的新迁移） ==="
echo ""
if comm -13 "$TMP_DIR/db-keys.txt" "$IMAGE_KEYS" | grep -q .; then
  comm -13 "$TMP_DIR/db-keys.txt" "$IMAGE_KEYS" | while read -r key; do
    folder=$(grep "^$key" "$TMP_DIR/image-names.txt" | head -1)
    echo "  $folder  (部署后由 bootstrap 自动执行)"
  done
else
  echo "  无"
fi

echo ""
echo "预检完成。v0 表存在孤儿记录必须处理；v1 表孤儿记录按提示判断；缺失记录为本次待执行迁移。"
