---
git_commit_message: 'projects: add project rename'
plan_state: finished
---
# 002 项目重命名

## current_status

1. 全局项目索引保存在 `~/.avcs/avcs.sqlite3` 的 `projects` 表，已有 `name`、`folder_path`、`project_db_path`、`sidebar_order`、`archived_at`、`created_at`、`updated_at`、`last_opened_at` 字段。
2. 项目名称目前由 `Avcs.Projects.upsert_global_project/1` 在打开项目时从 `folder_path` 的 basename 派生。
3. 重新打开已存在项目时，当前实现会把 `projects.name` 重置为文件夹 basename；这会覆盖用户手动重命名，需要修正。
4. 左栏 `ProjectPane` 已有 `.project-row-menu`，包含数据库情况、归档项目、归档对话和删除引用。
5. `App.jsx` 已有通用 `PromptDialog` 和 `promptAction`，thread 重命名已用同一套交互。
6. `AvcsWeb.AvcsChannel` 已有 `project:select`、`project:archive`、`project:delete`、`project:reorder`，并通过 `project:updated` 和 `projects:updated` 同步状态。

## overview

新增项目显示名重命名能力，只修改全局项目索引中的 `projects.name`。

边界：

1. 不移动、不重命名项目文件夹。
2. 不修改 `<project>/.avcs/project.sqlite3`。
3. 不修改 `folder_path`、`project_db_path`、`sidebar_order`、`last_opened_at` 或 thread 当前选择。
4. 不要求项目名称全局唯一；项目身份继续由 `id` 和 `folder_path` 决定。
5. 项目文件夹 missing/unavailable 时仍允许重命名，因为该操作只依赖全局 SQLite。

## data_model

1. 不新增表和字段，继续使用 `projects.name` 保存显示名。
2. 新增或调整后端校验函数：
   - trim 前后空白。
   - 空字符串报错。
   - `"."`、`".."`
   - 包含 `/` 或 `\` 的值报错，避免显示名看起来像路径。
3. `Avcs.Projects.rename_project(id, name)`：
   - 只查找未归档项目。
   - 更新 `projects.name` 和 `updated_at`。
   - 返回 `enrich_project_index/1` 后的项目。
   - 如果重命名的是当前项目，同步更新 `Avcs.Session.current_project()`，保留当前 `current_thread_id`。
4. 调整 `upsert_global_project/1`：
   - 新项目仍用 `Path.basename(folder_path)` 作为初始名称。
   - 已存在项目重新打开时保留现有 `projects.name`，不再重置为 basename。

## api

不新增 HTTP API。

新增 WebSocket 事件：

1. `project:rename`
   - 请求：`{ "id": "...", "name": "New Name" }`
   - 成功响应：直接返回重命名后的 project 对象。
   - 失败响应：
     - `project_not_found`
     - `invalid_project_name`
     - `project_rename_failed`
2. 重命名成功后广播：
   - `projects:updated`：刷新左栏项目列表。
   - `project:updated`：仅当重命名的是当前项目时推送当前项目。
3. Channel handler 放在现有项目管理事件附近，错误响应继续使用统一 `{ success, data, error }` 信封。

## ui

1. 在 `.project-row-menu` 中新增 `Rename project` / `重命名项目` 菜单项。
2. 菜单项使用 lucide `Pencil` 或 `PencilLine` 图标，位置放在数据库情况之前。
3. 点击后关闭 row menu，打开现有 `PromptDialog`：
   - title：重命名项目。
   - label：项目名称。
   - initialValue：当前 `entry.name`。
   - confirmLabel：保存。
4. 用户取消、输入为空或名称未变化时不发送请求。
5. 请求成功后更新 `projects` 列表；如果当前项目被重命名，同时更新 `project.name`。
6. 重命名菜单对 missing/unavailable 项目保持可用；数据库情况、归档对话等仍按现有规则禁用。
7. 新增 i18n key：
   - `app.rename_project`
   - `app.project_renamed`
   - `project.rename`
8. 保持现有左栏布局和拖拽行为；项目行上的菜单按钮继续 `stopPropagation()`，避免触发选择或拖拽。

## others

实现建议：

1. 在 `Avcs.Projects` 中新增 `rename_project/2`，复用或抽出项目名称校验。
2. 在 `AvcsWeb.AvcsChannel` 中新增 `handle_in("project:rename", ...)`。
3. 在 `App.jsx` 中新增 `handleRenameProject(projectEntry)`，复用 `promptAction`。
4. 在 `ProjectPane.jsx` 新增 `onRenameProject` prop，并在 row menu 中接入。
5. 更新 `web/src/i18n.js` 的英文和简体中文文案。

测试建议：

1. `test/avcs/projects_test.exs` 覆盖：
   - 重命名成功更新 `projects.name`。
   - 重命名不改变 `folder_path`、`project_db_path`、`sidebar_order`、`last_opened_at`。
   - 重新打开同一项目后名称不回退到 folder basename。
   - 空名称和路径分隔符名称被拒绝。
2. `test/avcs_web/channels/avcs_channel_test.exs` 覆盖：
   - `project:rename` 成功响应。
   - 推送 `projects:updated`。
   - 当前项目被重命名时推送 `project:updated`。
   - 非法 payload 返回 `invalid_project_name`。
3. 前端如无测试框架，则通过 Vite dev server 手动验证，不运行 `npm run build` 或 `vite build`。

手动验证：

1. 从项目行菜单重命名当前项目，左栏和工作台状态立即更新。
2. 从项目行菜单重命名非当前项目，只更新左栏列表，不切换当前项目。
3. 重命名 missing/unavailable 项目可成功。
4. 重新打开同一路径后仍保留自定义名称。
5. 删除引用、归档项目、项目排序和 thread 操作不受影响。

## prds

完成后同步更新：

1. `docs/prds/overview.md`：说明项目名称是全局索引显示名，重命名不移动项目文件夹。
2. `docs/prds/features/projects/001-项目打开与初始化.md`：补充 `project:rename` 事件、重命名交互和 reopen 后保留自定义名称的规则。
3. `docs/prds/features/ui/001-三栏工作台UI.md`：补充项目行菜单中的重命名入口。
4. `docs/prds/features/web/002-WebSocket状态同步.md`：补充 `project:rename`、`projects:updated` 和当前项目 `project:updated` 的同步行为。
