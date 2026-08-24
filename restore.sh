#!/usr/bin/env bash
# 从 backup.sh 产物恢复：数据库（pg_restore）+ 应用数据（tar 解包）
# 破坏性操作：默认要求交互确认，非交互/脚本调用必须显式加 -f 才执行。
# 用法：
#   ./restore.sh db <backup/db-20260822090000.dump>          # 仅恢复数据库
#   ./restore.sh app <backup/app-data-20260822090000.tar.gz> # 仅恢复应用数据
#   ./restore.sh all <20260822090000>                         # 同时恢复两者（按时间戳前缀匹配）
#   ./restore.sh -f {db|app|all} <备份文件|时间戳前缀>          # 跳过交互确认
# 注意：
#   - 数据库恢复使用 --clean --if-exists 覆盖现有对象，执行前请确认目标库正确且已备份
#   - 恢复期间应用写入会丢失，建议先 docker compose stop app
set -euo pipefail

# 破坏性操作强制确认：默认必须人工输入 y；-f 仅用于明确意图的非交互执行
FORCE=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    -f|--force) FORCE=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

confirm() {
  [ "$FORCE" -eq 1 ] && return 0
  local ans
  read -r -p "$1 [y/N] " ans || return 1
  [[ "$ans" =~ ^[yY](es)?$ ]] || return 1
}

DEPLOY_DIR="${DEPLOY_DIR:-/opt/fsdx-web}"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
BACKUP_DIR="${DEPLOY_DIR}/backup"

if [ ! -f "$DEPLOY_DIR/.env" ]; then
  echo "未找到 $DEPLOY_DIR/.env，请先创建并填写配置"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$DEPLOY_DIR/.env"
set +a

COMPOSE=(docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR")

usage() {
  echo "用法：$0 [-f] {db|app|all} <备份文件|时间戳前缀>"
  echo "  例：$0 all 20260822090000"
  echo "  例：$0 db /opt/fsdx-web/backup/db-20260822090000.dump"
  echo "  破坏性恢复默认需交互确认，非交互场景加 -f 跳过"
  exit 1
}

[ "${#POSITIONAL[@]}" -ge 2 ] || usage
MODE="${POSITIONAL[0]}"
ARG="${POSITIONAL[1]}"

restore_db() {
  local dump="$1"
  [ -f "$dump" ] || { echo "备份文件不存在：$dump"; exit 1; }
  echo "恢复数据库：$dump"
  confirm "将用备份覆盖数据库 ${POSTGRES_DB} 现有数据（pg_restore --clean），此操作不可逆！确认？" || {
    echo "已取消恢复"
    exit 1
  }
  # --single-transaction：全量恢复在一个事务内，中途失败自动回滚，避免半恢复状态
  # （否则迁移表被 --clean 删除后失败，应用启动会被当成新库重跑全部迁移而崩溃）
  "${COMPOSE[@]}" exec -T db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges --single-transaction < "$dump"
  echo "数据库恢复完成。请重启应用：docker compose restart app"
}

restore_app() {
  local tar="$1"
  [ -f "$tar" ] || { echo "备份文件不存在：$tar"; exit 1; }
  echo "恢复应用数据：$tar"
  confirm "将覆盖 ${DEPLOY_DIR}/volumes/app 下同名文件，确认？" || {
    echo "已取消恢复"
    exit 1
  }
  tar xzf "$tar" -C "$DEPLOY_DIR/volumes"
  echo "应用数据恢复完成。"
}

case "$MODE" in
  db)
    restore_db "$ARG"
    ;;
  app)
    restore_app "$ARG"
    ;;
  all)
    restore_db "${BACKUP_DIR}/db-${ARG}.dump"
    restore_app "${BACKUP_DIR}/app-data-${ARG}.tar.gz"
    ;;
  *)
    usage
    ;;
esac
