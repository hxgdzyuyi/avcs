---
git_commit_message: 'project: add project sqlite info dialog'
plan_state: rendered
---

# Project SQLite 信息面板与整理

## current_status

当前 `ProjectPane` 已有项目行菜单（`项目列表 -> 更多项目操作`），但仅提供归档项目、归档对话、删除引用三类操作，未覆盖项目数据库健康状态入口。

现状关键点：

1. `.avcs/project.sqlite3` 在项目打开时会被初始化并迁移。
2. 项目元信息已经存在于 `project` 会话对象中（`project_db_path`、`folder_path`、`status`）并会通过 `project:current` / `project:updated` 下发。
3. 目前没有“项目数据库信息查询”和“数据库维护执行”的 HTTP API。
4. `ProjectPane` 项目菜单为 DOM 菜单，可直接挂载“数据库信息”入口并打开弹窗。

## overview

目标是在 `.project-row-menu` 增加【数据文件情况】入口，打开后展示当前项目 `.avcs/project.sqlite3` 的基础状态，并提供两类数据库整理动作：

1. 快速优化（fast_optimize）：执行 `PRAGMA wal_checkpoint(TRUNCATE)` + `PRAGMA optimize`。
2. 深度整理（deep_vacuum）：执行 `VACUUM`。

边界说明：

1. 范围仅限当前项目的 `project_db_path`，不涉及 `~/.avcs/avcs.sqlite3`。
2. 仅读取数据库状态，不读取本地文件系统原始路径内容。
3. 数据库维护操作只用于本地项目优化，不影响项目业务逻辑。
4. 深度整理不自动执行，由用户显式点击触发。
5. 深度整理可能耗时较长时，采用后台执行并返回进度事件；快速优化采用即时同步执行。

## data_model

新增“数据库信息”不引入新表；前端可渲染的单次返回结构为：

```json
{
  "project_id": "uuid",
  "db_path": "/abs/path/.avcs/project.sqlite3",
  "exists": true,
  "size_bytes": 12345678,
  "file_mtime": "2026-06-02T12:34:56.000Z",
  "status": "available|missing|unavailable",
  "sqlite_info": {
    "page_size": 4096,
    "page_count": 1024,
    "freelist_count": 2,
    "wal_mode": "wal",
    "schema_version": "2",
    "journal_mode": "wal",
    "foreign_keys": 1
  },
  "table_rows": [
    {"name": "threads", "rows": 15},
    {"name": "turns", "rows": 140}
  ],
  "optimized_at": "2026-06-01T10:00:00.000Z"
}
```

维护任务的执行态放在进程内存（`Avcs.Projects` 内部 Registry/Task 级状态），字段建议：

1. `job_id`：任务标识。
2. `action`：`fast_optimize` 或 `deep_vacuum`。
3. `project_id`：所属项目。
4. `status`：`running | success | failed`。
5. `duration_ms`、`error_code`、`error_message`。

## api

新增前端统一响应信封 API（沿用现有 `snake_case`）：

1. `GET /api/project/sqlite_info`
   - 输入：无（默认当前项目）
   - 成功响应：`{ "success": true, "data": { ...db_info... } }`
   - 失败响应：`{ "success": false, "data": null, "error": { ... } }`
2. `POST /api/project/sqlite_maintenance`
   - 输入：`{ "action": "fast_optimize" | "deep_vacuum" }`
   - 快速优化返回：`{ "success": true, "data": { "status": "running|completed", "job_id": "..." } }`
   - 深度整理返回：`{ "success": true, "data": { "status": "queued|running", "job_id": "..." } }`

与前端状态同步：

1. 新增 `project:sqlite:maintenance_started`：推送 `{ project_id, job_id, action }`。
2. 新增 `project:sqlite:maintenance_completed`：推送 `{ project_id, job_id, action, success, elapsed_ms, details }`。
3. 失败时可复用 `error` 推送。

## ui

1. 在 `web/src/features/projects/ProjectPane.jsx` 的 `project-row-menu` 增加一项：
   - `数据库情况`
2. 点击后打开 `web/src/features/projects/ProjectDbInfoDialog.jsx`（或复用现有 Dialog 组件）：
   - 标题显示项目名与 `.avcs/project.sqlite3` 名称。
   - 主体显示关键指标：路径、文件大小、文件修改时间、页面大小、空闲页、journal mode、schema 版本。
   - 显示 `table_rows` 摘要（至少 `threads/turns/items/assets/board_items`）。
3. 操作按钮：
   - `快速优化（fast_optimize）`：调用 API 后显示执行中状态，完成即刷新信息。
   - `深度整理（deep_vacuum）`：调用 API 后显示排队/运行状态；支持中止按钮（如无中止能力则说明不可取消）。
4. 安全与体验：
   - 数据库不存在/不可读显示禁用态及明确错误。
   - 维护中禁用同类按钮。
   - 维护完成后自动关闭或保留弹窗并更新数据。
5. 样式按 Sass 组织到 `web/src/styles/_components.scss`。

## commands

建议增加并同步的本地命令：

1. 后端同步命令（用于手工触发）：
   - `mix project.sqlite_info <project_folder>`
   - `mix project.sqlite_maintain <project_folder> --action fast_optimize|deep_vacuum`
2. 后端回归测试（待实现后补充）：
   - `mix test test/avcs_web/controllers/project_controller_test.exs`
   - `mix test test/avcs/projects_test.exs`

日常开发仍以 `cd web && npm run dev` 与 Phoenix dev server 联调，不要求运行生产 build。

## jobs

异步任务：

1. 维持 `Avcs.Agent.TaskSupervisor` / 新增 `Task.Supervisor` 风格的异步 runner 只用于 `deep_vacuum`，避免 HTTP 请求超时。
2. 触发：前端调用 `POST /api/project/sqlite_maintenance` 且 `action=deep_vacuum`。
3. 执行策略：
   - 先在 `project` 内置会话中标记 `project_sqlite_maintenance_running=true`，避免并发重复运行。
   - 异步任务执行 `VACUUM`，记录 `duration_ms` 与异常。
   - 成功/失败后广播 `project:sqlite:maintenance_completed` 并回写 `project:sqlite_info`。
4. 深度整理失败时不回滚项目业务数据；仅返回错误码与文本。

## others

1. 所有数据库操作仍通过 Phoenix API，由 Phoenix 限定当前项目上下文；React 不直接访问 `.avcs/project.sqlite3`。
2. 优先执行快速优化，提示其适用于日常维护；深度整理仅作为重整理入口并说明代价。
3. 计划不变更 Asset、Board 或 Thread 的现有持久化规则。
4. 不引入 TypeScript、Tailwind、CSS-in-JS、Less 或组件库主题系统。

## prds

完成后同步更新：

1. `docs/prds/features/projects/001-项目打开与初始化.md`
2. `docs/prds/features/web/001-Phoenix本地文件API.md`
3. `docs/prds/features/ui/002-Codex左侧栏对齐.md`
