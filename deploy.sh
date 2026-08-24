#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/fsdx-web}"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
TAG="${TAG:-latest}"

if [ ! -f "$DEPLOY_DIR/.env" ]; then
  echo "未找到 $DEPLOY_DIR/.env，请先 cp .env.example .env 并填写配置"
  exit 1
fi

# 应用镜像内以 nodejs 用户运行（uid 1001），宿主机挂载目录须与该 uid 对齐
mkdir -p "$DEPLOY_DIR/volumes/app" "$DEPLOY_DIR/volumes/db"
chown 1001:1001 "$DEPLOY_DIR/volumes/app" 2>/dev/null || true

echo "停止现有服务..."
TAG="$TAG" docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" down --remove-orphans 2>/dev/null || true

echo "拉取镜像（TAG=${TAG}）..."
TAG="$TAG" docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" pull app

echo "启动服务..."
TAG="$TAG" docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" up -d --remove-orphans

# 数据库迁移由应用启动时 bootstrap → runMigrations()（drizzle-orm migrator）自动执行，
# 迁移失败会 fail-fast 使应用启动即崩（crash loop）。
# up -d 为异步返回，容器可能正处崩溃重启中，必须等待 healthcheck 通过才视为部署成功。
echo "等待应用健康检查（数据库迁移在此过程中执行）..."
APP_CONTAINER="fsdx-app"
STATUS=""
HEALTH=""
WAIT=0
for i in $(seq 1 90); do
  STATUS=$(docker inspect -f '{{.State.Status}}' "$APP_CONTAINER" 2>/dev/null || echo missing)
  HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$APP_CONTAINER" 2>/dev/null || echo missing)
  [ "$STATUS" = "running" ] && [ "$HEALTH" = "healthy" ] && break
  # 容器反复退出（迁移失败 crash loop）则提前失败
  [ "$STATUS" = "exited" ] && [ "$i" -gt 3 ] && break
  sleep 2
  WAIT=$i
done

if [ "$STATUS" = "running" ] && [ "$HEALTH" = "healthy" ]; then
  echo "部署完成，应用已就绪（${WAIT} 秒内通过健康检查）"
else
  echo "应用未就绪（status=${STATUS} health=${HEALTH}），疑似数据库迁移失败或启动异常，最近日志："
  docker compose -f "$COMPOSE_FILE" --project-directory "$DEPLOY_DIR" logs --tail 30 app 2>/dev/null || true
  exit 1
fi
