#!/usr/bin/env bash
# 一键全量备份：数据库逻辑备份（pg_dump 流式）+ 应用数据打包，在线热备无需停库
# 用法：
#   ./backup.sh                              # 交互确认后备份到 ${DEPLOY_DIR}/backup/
#   ./backup.sh -y                           # 跳过交互确认（cron 定时备份必须加 -y）
#   DEPLOY_DIR=/opt/fsdx-web RETENTION_DAYS=14 ./backup.sh
set -euo pipefail

# 交互确认：cron/脚本等非交互场景必须用 -y 跳过
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
BACKUP_DIR="${DEPLOY_DIR}/backup"
RETENTION_DAYS="${RETENTION_DAYS:-3}"

if [ ! -f "$DEPLOY_DIR/.env" ]; then
  echo "未找到 $DEPLOY_DIR/.env，请先创建并填写配置"
  exit 1
fi

# 读取 .env 中的数据库凭据（POSTGRES_USER / POSTGRES_DB）
set -a
# shellcheck disable=SC1091
source "$DEPLOY_DIR/.env"
set +a

COMPOSE=(docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR")
TS=$(date +%Y%m%d%H%M%S)

confirm "即将执行全量备份到 ${BACKUP_DIR}（数据库 + 应用数据），确认继续？" || {
  echo "已取消备份"
  exit 1
}

mkdir -p "$BACKUP_DIR"

echo "=== 1/4 数据库逻辑备份（pg_dump） ==="
DB_DUMP="${BACKUP_DIR}/db-${TS}.dump"
# 流式输出到宿主机文件；pg_dump 在线热备安全，无需停库
if ! "${COMPOSE[@]}" exec -T db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z 9 > "$DB_DUMP"; then
  echo "数据库备份失败，清理不完整产物"
  rm -f "$DB_DUMP"
  exit 1
fi

echo "=== 2/4 校验数据库备份 ==="
# pg_restore --list 验证 dump 可读且结构完整（-Fc 自定义格式支持从 stdin 读取）
if ! "${COMPOSE[@]}" exec -T db pg_restore --list < "$DB_DUMP" > /dev/null 2>&1; then
  echo "数据库备份校验失败，删除产物"
  rm -f "$DB_DUMP"
  exit 1
fi

echo "=== 3/4 应用数据打包 ==="
APP_TAR="${BACKUP_DIR}/app-data-${TS}.tar.gz"
# 上传文件、日志等全部应用数据（volumes/app）
if ! tar czf "$APP_TAR" -C "$DEPLOY_DIR/volumes" app; then
  echo "应用数据打包失败，清理不完整产物"
  rm -f "$APP_TAR"
  exit 1
fi

if ! tar tzf "$APP_TAR" > /dev/null 2>&1; then
  echo "应用数据打包校验失败，删除产物"
  rm -f "$APP_TAR"
  exit 1
fi

echo "=== 4/4 清理过期备份（保留最近 ${RETENTION_DAYS} 天） ==="
EXPIRED_DB=$(find "$BACKUP_DIR" -name "db-*.dump" -mtime +"$RETENTION_DAYS" 2>/dev/null | wc -l | tr -d ' ')
EXPIRED_APP=$(find "$BACKUP_DIR" -name "app-data-*.tar.gz" -mtime +"$RETENTION_DAYS" 2>/dev/null | wc -l | tr -d ' ')
if [ "$EXPIRED_DB" -eq 0 ] && [ "$EXPIRED_APP" -eq 0 ]; then
  echo "无过期备份，跳过清理"
elif confirm "将删除 ${RETENTION_DAYS} 天前的备份（${EXPIRED_DB} 个 db + ${EXPIRED_APP} 个 app-data），确认？"; then
  find "$BACKUP_DIR" -name "db-*.dump" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
  find "$BACKUP_DIR" -name "app-data-*.tar.gz" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
  echo "过期备份已清理"
else
  echo "跳过过期备份清理"
fi

echo ""
echo "备份完成："
ls -lh "$DB_DUMP" "$APP_TAR"
echo ""
echo "本次备份文件："
echo "  $DB_DUMP"
echo "  $APP_TAR"
