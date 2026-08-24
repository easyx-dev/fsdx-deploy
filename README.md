# fsdx-web 生产部署运维手册

生产环境部署配置与运维脚本，服务器部署目录 `/opt/fsdx-web/`（可用 `DEPLOY_DIR` 环境变量覆盖）。

## 文件说明

| 文件 | 用途 |
|------|------|
| `docker-compose.yml` | 生产环境 docker compose 配置（db + app，内置 PostgreSQL） |
| `deploy.sh` | 一键部署/更新脚本 |
| `backup.sh` | 全量备份脚本（数据库逻辑备份 + 应用数据打包，在线热备） |
| `preflight-migrations.sh` | 迁移预检（部署前校验迁移表与镜像迁移文件夹一致性） |
| `restore.sh` | 恢复脚本（数据库 + 应用数据） |
| `.env.example` | 环境变量模板（复制为 `.env` 填写） |
| `VERSION` | 部署配置版本号 |

## 使用

```bash
# 首次部署（服务器上）
cp .env.example .env   # 填写 POSTGRES_* 与 JWT_SECRET
TAG=latest ./deploy.sh

# 后续更新
TAG=latest ./deploy.sh
```

## 服务拓扑

```
宿主机 nginx (80/443, SSL)
    └── proxy_pass http://127.0.0.1:3000
            │
    docker compose
    ├── app (fsdx-app :3000)    # 镜像 ghcr.io/easyx-dev/fsdx:${TAG}，nodejs 用户运行
    │     └── volumes/app       # 日志、上传文件（宿主属主 1001:1001）
    └── db  (fsdx-db :14010)    # postgres:18-alpine
          └── volumes/db        # PostgreSQL 数据卷
```

## 数据库迁移机制（重要）

- **迁移唯一生效入口**：app 容器启动时 `bootstrap → runMigrations()`（drizzle-orm migrator）自动执行镜像内 `/app/drizzle` 的迁移文件；**迁移失败即应用启动崩溃（fail-fast）**
- `deploy.sh` 不显式执行迁移；`up -d` 后等待 app 健康检查通过即为迁移成功（fail-fast 语义下健康检查即迁移结果）
- 迁移记录表：`drizzle.__drizzle_migrations`。匹配语义分两种：**v1 表（含 `name` 列）按完整文件夹名匹配**；**v0 表（旧版写入）按 `created_at`（UTC 毫秒）时间戳匹配**
- **孤儿记录风险**：`preflight-migrations.sh` 自动检测迁移表版本并按其匹配语义比对。v0 表存在孤儿记录会导致升级时 migrator 直接报错、应用启动即崩；v1 表孤儿会被静默忽略，仅当属文件夹改名遗留时才需同步删除。升级前务必先跑预检

## 版本升级流程

### 1. 升级前备份（必做）

```bash
cd /opt/fsdx-web
./backup.sh            # 交互确认后生成 backup/db-<ts>.dump + backup/app-data-<ts>.tar.gz
```

输出为全量逻辑备份（pg_dump 自定义格式，可在任意库上 `pg_restore` 恢复）+ 应用数据压缩包，自动校验并保留最近 3 天（`RETENTION_DAYS` 可调）。**交互确认**：开始备份与清理过期备份前均需输入 `y` 确认，`./backup.sh -y` 跳过（cron 等非交互场景必须用 `-y`）。

如需物理快照双保险（可选，需停库）：

```bash
docker compose stop db
tar czf backup/volumes-db-$(date +%Y%m%d%H%M%S).tar.gz volumes/db
docker compose start db
```

### 2. 迁移预检（必做）

```bash
cd /opt/fsdx-web
TAG=<新版本号> ./preflight-migrations.sh     # 交互确认后执行，-y 跳过
```

- 输出「孤儿记录（DB 有而镜像无）」与「缺失记录（本次待执行的新迁移）」两类结论
- 发现孤儿记录：按脚本提示的 DELETE SQL，**人工确认后**删除对应迁移表记录（保留备份后再删）

### 3. 执行升级

```bash
cd /opt/fsdx-web
TAG=<新版本号> ./deploy.sh
```

> `up -d` 为异步返回。`deploy.sh` 启动后会等待 app 通过容器健康检查（**数据库迁移在此过程中执行**）：超时或容器反复退出（迁移失败 crash loop）会打印最近日志并以非零退出，**deploy.sh 不报错即代表部署成功**。

### 4. 升级后验证

```bash
# 服务健康
docker compose ps
docker compose logs -f app | grep -i migrat    # 确认迁移执行日志
curl -s http://127.0.0.1:3000/health

# 迁移表应含 hash 列、created_at 为毫秒且新迁移已应用
docker compose exec -T db psql -U <user> -d <db> -c \
  "SELECT id, created_at, left(hash,8) FROM drizzle.__drizzle_migrations ORDER BY created_at DESC LIMIT 5"

# 业务核心页面冒烟（管理后台登录、首页、关键模块）
```

## 恢复

> 恢复期间写入会丢失，建议先 `docker compose stop app` 再恢复，完成后 `docker compose start app`。
> 破坏性操作默认要求交互确认（输入 `y`），非交互/脚本执行必须显式加 `-f`。
> 应用数据恢复为 tar 解包覆盖同名文件，**备份后新增/残留的文件不会被清除**；如需完全一致请先清空 `volumes/app`。

```bash
cd /opt/fsdx-web
# 全部恢复（按时间戳前缀匹配 backup/db-<ts>.dump 与 app-data-<ts>.tar.gz）
./restore.sh all 20260822090000

# 仅数据库
./restore.sh db /opt/fsdx-web/backup/db-20260822090000.dump
# 仅应用数据
./restore.sh app /opt/fsdx-web/backup/app-data-20260822090000.tar.gz

# 非交互执行（跳过确认）
./restore.sh -f all 20260822090000
```

数据库恢复为覆盖式（`pg_restore --clean --if-exists`），`pg_dump` 逻辑备份跨 PostgreSQL 版本可恢复；恢复后应用启动会自动重新核对迁移。

## 回滚

```bash
# 应用回滚到旧版本（旧镜像 tag 保留在仓库）
cd /opt/fsdx-web
TAG=<旧版本号> ./deploy.sh
```

- 仅代码/配置回滚：上述命令即可
- 数据库结构已变更且业务异常：用升级前备份执行 `restore.sh` 恢复数据库后，再回滚应用

## 定期备份（cron）

```bash
# 每日 02:00 执行备份，日志写入 backup/cron.log（cron 非交互，必须加 -y）
0 2 * * * /opt/fsdx-web/backup.sh -y >> /opt/fsdx-web/backup/cron.log 2>&1
```

定期备份保留策略由 `RETENTION_DAYS`（默认 3 天）控制。
