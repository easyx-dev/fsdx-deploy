#!/usr/bin/env bash
set -euo pipefail

# ── 颜色与样式（非 TTY 环境自动关闭，避免 CI/日志出现 ANSI 码）──
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_GREEN=""; C_CYAN=""; C_YELLOW=""; C_RED=""
fi

# ── 输出辅助 ──
info() { echo "${C_CYAN}▶${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()   { echo "  ${C_GREEN}✓${C_RESET} $*"; }
warn() { echo "  ${C_YELLOW}⚠${C_RESET} $*"; }
fail() { echo "  ${C_RED}✗${C_RESET} $*"; }

# 颜色状态值：up/ok/healthy 绿色，down/error/unhealthy 红色
color_status() {
  case "$1" in
    up|ok|healthy) echo "${C_GREEN}${1}${C_RESET}" ;;
    down|error|unhealthy) echo "${C_RED}${1}${C_RESET}" ;;
    *) echo "$1" ;;
  esac
}

DEPLOY_DIR="${DEPLOY_DIR:-/opt/fsdx-web}"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
TAG="${TAG:-latest}"
APP_CONTAINER="fsdx-app"

if [ ! -f "$DEPLOY_DIR/.env" ]; then
  fail "未找到 $DEPLOY_DIR/.env，请先创建并填写配置"
  exit 1
fi

# 与 compose 的 ${APP_PORT:-3000} 保持一致（从 .env 提取，避免 health 展示打到错误端口）
APP_PORT="$(grep -E '^APP_PORT=' "$DEPLOY_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
APP_PORT="${APP_PORT:-3000}"

mkdir -p "$DEPLOY_DIR/volumes/app" "$DEPLOY_DIR/volumes/db"

echo ""
echo "${C_BOLD}${C_GREEN}═══ FSDX 部署 ═══${C_RESET}"
echo "${C_DIM}部署目录: ${DEPLOY_DIR} · 镜像 TAG: ${TAG} · 应用端口: ${APP_PORT}${C_RESET}"
echo ""

# 部署前记录当前 app 镜像 ID：拉取新镜像后旧镜像失去 tag 引用，部署完成后按此 ID 精确清理
# （不采用 docker image prune -f——它会误清同宿主机上其他项目的悬空镜像）
OLD_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$APP_CONTAINER" 2>/dev/null || true)"

# 先拉新镜像，期间旧版本继续对外服务；镜像拉取不计入停机时间
info "拉取新镜像（TAG=${TAG}），旧版本继续提供服务..."
TAG="$TAG" docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" pull app
ok "新镜像拉取完成"

echo ""
# up -d 只重建镜像/配置发生变化的容器（通常仅 app），数据库容器保持运行不中断
info "重建服务（仅变更的容器被替换，数据库容器保持运行）..."
if ! TAG="$TAG" docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" up -d --remove-orphans; then
  warn "up -d 失败，回退为 down + up -d 完整重建"
  TAG="$TAG" docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" down --remove-orphans 2>/dev/null || true
  TAG="$TAG" docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" up -d --remove-orphans
fi
ok "容器已重建"

echo ""
# 精确清理旧版本镜像：同一 tag 每次拉取新镜像后，旧镜像失去 tag 引用即变为 <none> 悬空镜像，
# 每次部署累积一个、长期占用磁盘。不采用 docker image prune -f（会误清同宿主机上其他项目的
# 悬空镜像），改为按部署前记录的镜像 ID 只删本项目旧镜像。
# 仅当新容器实际更换了镜像时才删除；删除失败（如仍被其他容器引用）仅告警不阻塞部署。
info "清理旧版本镜像（仅本项目部署前的镜像）..."
if [ -n "$OLD_IMAGE_ID" ]; then
  NEW_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$APP_CONTAINER" 2>/dev/null || true)"
  if [ -n "$NEW_IMAGE_ID" ] && [ "$NEW_IMAGE_ID" != "$OLD_IMAGE_ID" ]; then
    if docker image rm "$OLD_IMAGE_ID" >/dev/null 2>&1; then
      ok "旧版本镜像已清理（${OLD_IMAGE_ID:0:19}...）"
    else
      warn "旧版本镜像清理失败（可能仍被其他容器引用，不影响部署结果）"
    fi
  else
    ok "镜像未变化，无需清理"
  fi
else
  ok "无旧版本镜像可清理（首次部署）"
fi

echo ""
# 数据库迁移由应用启动时 bootstrap → runMigrations()（drizzle-orm migrator）自动执行，
# 无需在此显式调用；迁移失败会使应用启动即崩（fail-fast）。
# up -d 为异步返回，容器可能正处崩溃重启中，必须等待 healthcheck 通过才视为部署成功。
info "等待应用健康检查（数据库迁移在此过程中执行）..."
STATUS=""; HEALTH=""; WAIT=0
for i in $(seq 1 90); do
  STATUS=$(docker inspect -f '{{.State.Status}}' "$APP_CONTAINER" 2>/dev/null || echo missing)
  HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$APP_CONTAINER" 2>/dev/null || echo missing)
  [ "$STATUS" = "running" ] && [ "$HEALTH" = "healthy" ] && break
  # 容器反复退出（迁移失败 crash loop）则提前失败
  [ "$STATUS" = "exited" ] && [ "$i" -gt 3 ] && break
  sleep 2
  WAIT=$i
done

echo ""
if [ "$STATUS" = "running" ] && [ "$HEALTH" = "healthy" ]; then
  ok "应用已就绪（${WAIT} 秒内通过健康检查）"

  # ── 展示 /health 就绪探活结果 ──
  if command -v curl >/dev/null 2>&1; then
    HEALTH_JSON="$(curl -sS --max-time 5 "http://127.0.0.1:${APP_PORT}/health" 2>/dev/null || true)"
    if [ -z "$HEALTH_JSON" ]; then
      warn "无法获取 /health 响应（http://127.0.0.1:${APP_PORT}/health），请手动确认"
    else
      H_STATUS="$(printf '%s' "$HEALTH_JSON" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' | head -1)"
      H_VERSION="$(printf '%s' "$HEALTH_JSON" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
      H_UPTIME="$(printf '%s' "$HEALTH_JSON" | sed -n 's/.*"uptime":\([0-9.]*\).*/\1/p')"
      H_DB="$(printf '%s' "$HEALTH_JSON" | sed -n 's/.*"database":{"status":"\([^"]*\)".*/\1/p')"
      H_DB_MS="$(printf '%s' "$HEALTH_JSON" | sed -n 's/.*"latencyMs":\([0-9]*\).*/\1/p')"
      H_STORAGE="$(printf '%s' "$HEALTH_JSON" | sed -n 's/.*"storage":{"status":"\([^"]*\)".*/\1/p')"

      # uptime 秒数格式化为可读时长（纯 bash 计算，不依赖 bc/awk，精简镜像同样可用）
      if [ -n "$H_UPTIME" ]; then
        H_UPTIME_SECS="${H_UPTIME%%.*}"
        case "$H_UPTIME_SECS" in
          ''|*[!0-9]*) H_UPTIME_FMT="${H_UPTIME} 秒" ;;
          *)
            if [ "$H_UPTIME_SECS" -ge 60 ]; then
              H_UPTIME_FMT="$((H_UPTIME_SECS / 60)) 分 $((H_UPTIME_SECS % 60)) 秒"
            else
              H_UPTIME_FMT="${H_UPTIME} 秒"
            fi
            ;;
        esac
      else
        H_UPTIME_FMT="?"
      fi

      echo ""
      echo "  ${C_BOLD}┌─ 应用健康检查（/health）${C_DIM}http://127.0.0.1:${APP_PORT}/health${C_RESET}"
      echo "  ${C_BOLD}├${C_RESET} ${C_BOLD}状态${C_RESET}      $(color_status "${H_STATUS:-?}")"
      echo "  ${C_BOLD}├${C_RESET} ${C_BOLD}版本${C_RESET}      v${H_VERSION:-?}"
      echo "  ${C_BOLD}├${C_RESET} ${C_BOLD}数据库${C_RESET}    $(color_status "${H_DB:-?}")${H_DB_MS:+（耗时 ${H_DB_MS}ms）}"
      echo "  ${C_BOLD}├${C_RESET} ${C_BOLD}存储${C_RESET}      $(color_status "${H_STORAGE:-?}")"
      echo "  ${C_BOLD}├${C_RESET} ${C_BOLD}运行时长${C_RESET}  ${H_UPTIME_FMT}"
      echo "  ${C_BOLD}└────────────────────────────────────${C_RESET}"
      echo ""
    fi
  else
    warn "未检测到 curl，跳过 /health 结果展示"
  fi

  echo "  ${C_GREEN}${C_BOLD}✔ 部署完成，应用已就绪 ✔${C_RESET}"
  echo ""
else
  fail "应用未就绪（status=$(color_status "${STATUS}") health=$(color_status "${HEALTH}")），疑似数据库迁移失败或启动异常"
  echo "  ${C_DIM}最近 30 条应用日志：${C_RESET}"
  docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" logs --tail 30 app 2>/dev/null | sed "s/^/    /" || true
  exit 1
fi
