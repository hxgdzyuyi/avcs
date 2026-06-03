---
git_commit_message: 'settings: plan global software settings'
plan_state: finished
---
# Global software settings

## current_status

本文档描述 Avcs 的全局软件配置。它作用于当前 Avcs 安装和本机用户配置，默认跨项目生效，不是某个项目的单独配置表。

当前代码和文档里的相关基础：

1. 全局数据目录是 `~/.avcs/`。
2. 全局 SQLite 当前位于 `~/.avcs/avcs.sqlite3`，现有职责主要是保存项目索引。
3. 项目业务数据保存在 `<project>/.avcs/project.sqlite3`。
4. 项目 SQLite 中已有 `settings` 表，但该表不承载本计划的全局软件配置。
5. `threads` 表已经保存每个 thread 的默认 `model`、`effort`、`approval_policy` 和 `sandbox_mode`。
6. 前端聊天区已有 Composer settings 与 Image settings UI，但缺少跨项目默认值来源。

主要缺口：

1. 还没有全局软件配置的 Context、表结构和读写事件。
2. 新建项目、新建 thread 和 composer 初始化还不能继承全局默认值。
3. 当前 PRD 中“全局 SQLite 只保存项目关联信息”的表述需要修订为“保存软件级元数据和项目索引，但不保存项目业务数据”。
4. 项目级 `settings` 表和全局软件配置的职责边界需要明确，避免后续实现混用。

## overview

目标是实现 Avcs 的全局软件配置，用于保存跨项目生效的默认偏好和本地运行参数。它是软件级设置，不跟随单个项目文件夹迁移，也不写入项目 SQLite。

边界：

1. 全局软件配置归属 `~/.avcs/`，默认作用于所有项目。
2. 不写入 `<project>/.avcs/project.sqlite3` 的 `settings` 表。
3. 不保存 thread、turn、item、asset、board item 等项目业务数据。
4. 不做多用户、团队权限、云同步或远端配置中心。
5. 不引入 Avcs MVP 范围之外的第三方集成、网络风控或公开 Web 资源配置。
6. React 通过 Phoenix Channel 读写配置，不直接访问 SQLite 或本地文件系统。
7. 设置只提供默认值和偏好；具体 turn 运行参数仍以发送时显式参数为准。

第一阶段覆盖：

1. Agent 默认值：新 thread 默认 `model`、`effort`、`approval_policy`、`sandbox_mode`。
2. 图片生成默认值：默认比例、默认张数、是否默认透明背景。
3. 项目默认路径：新建空白项目的默认根目录，默认 `~/Documents/Avcs`。
4. 资产偏好：打开项目后是否自动扫描 `work/` 和 `output/`。
5. UI 偏好：是否恢复上次打开的项目和 thread。

## data_model

新增全局表 `app_settings`，位于 `~/.avcs/avcs.sqlite3`。

```sql
CREATE TABLE IF NOT EXISTS app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

字段语义：

1. `key`：设置标识，格式为 `{domain}.{name}`，例如 `agent.default_model`。
2. `value`：JSON 编码后的值，允许字符串、数字、布尔值、对象和数组。
3. `updated_at`：ISO 时间字符串。

默认值不需要全部落库。`Avcs.SiteSettings` 在代码中注册默认值和校验规则；全局库只保存用户覆盖过的值。恢复默认值时删除对应 `app_settings.key` 记录。

第一阶段默认值：

```elixir
%{
  "agent.default_model" => "gpt-5.5",
  "agent.default_effort" => "medium",
  "agent.default_approval_policy" => "never",
  "agent.default_sandbox_mode" => "workspace-write",
  "image.default_ratio" => "auto",
  "image.default_count" => 1,
  "image.transparent_background" => false,
  "projects.default_root" => "~/Documents/Avcs",
  "projects.restore_last_opened" => true,
  "assets.scan_on_open" => false
}
```

校验规则：

1. `agent.default_model` 允许 `nil` 或非空字符串；可选值可以由 `models:list` 返回结果辅助前端选择，但后端不依赖模型列表硬编码。
2. `agent.default_effort` 允许 `nil`、`none`、`minimal`、`low`、`medium`、`high`、`xhigh`。
3. `agent.default_approval_policy` 允许 `never`、`untrusted`、`on-failure`、`on-request`。
4. `agent.default_sandbox_mode` 允许 `read-only`、`workspace-write`、`danger-full-access`。
5. `image.default_ratio` 允许 `auto`、`1:1`、`4:3`、`3:4`、`16:9`、`9:16`。
6. `image.default_count` 是 1 到 4 的整数。
7. `image.transparent_background`、`projects.restore_last_opened`、`assets.scan_on_open` 是布尔值。
8. `projects.default_root` 必须是非空路径字符串；保存前展开 `~` 并规范化路径。
9. 未注册 key 拒绝写入，避免把 `app_settings` 变成任意 KV 存储。

继承关系：

1. Agent turn 显式传入的设置优先级最高。
2. 当前 thread 的默认设置次之。
3. 全局软件配置 `agent.*` 默认值再次之。
4. 最后回退到 Avcs 内置默认值。

图片设置只作为 composer 的默认 UI 状态。发送消息时仍按现有规则拼接为短文本，例如 `Image settings: aspect ratio 16:9; image count 2; transparent background.`，不新增结构化 turn 字段。

项目级 `settings` 表保留给未来项目内偏好或项目级覆盖使用。本计划不读写该表。

## api

新增 Context：`Avcs.SiteSettings`。

建议函数：

```elixir
Avcs.SiteSettings.list_settings()
Avcs.SiteSettings.get_setting(key)
Avcs.SiteSettings.effective_settings()
Avcs.SiteSettings.update_settings(attrs)
Avcs.SiteSettings.reset_setting(key)
Avcs.SiteSettings.reset_settings(keys)
```

返回语义：

1. `list_settings/0` 返回所有已注册设置，包含 `key`、`value`、`default_value`、`is_default`、`updated_at`。
2. `get_setting/1` 返回单项有效值；用户未覆盖时返回默认值。
3. `effective_settings/0` 返回前端初始化所需的扁平设置对象。
4. `update_settings/1` 在同一个 SQLite transaction 内校验并 upsert 多个 key。
5. `reset_setting/1` 删除覆盖值，让读取回到默认值。

新增 Channel 事件：

1. `site_settings:get`：读取全局软件配置。
2. `site_settings:update`：批量更新全局软件配置。
3. `site_settings:reset`：恢复一个或多个 key 为默认值。
4. `site_settings:updated`：服务端推送配置变化。

`site_settings:get` 响应：

```json
{
  "items": [
    {
      "key": "agent.default_approval_policy",
      "value": "never",
      "default_value": "never",
      "is_default": true,
      "updated_at": null
    }
  ],
  "settings": {
    "agent.default_approval_policy": "never"
  }
}
```

`site_settings:update` 请求：

```json
{
  "settings": {
    "agent.default_model": "gpt-5",
    "image.default_ratio": "16:9",
    "image.default_count": 2
  }
}
```

`site_settings:reset` 请求：

```json
{
  "keys": ["image.default_ratio", "image.default_count"]
}
```

错误规则：

1. 未注册 key 返回 `unknown_site_setting`。
2. 值类型或枚举不合法时返回 `invalid_site_setting`，并在 details 中包含 key。
3. SQLite 写入失败返回 `site_settings_update_failed`。

不新增公开 HTTP JSON API。全局软件配置属于 Avcs 工作台状态同步，使用 Channel 即可。

## ui

在 `/web/` 界面中增加全局设置管理页面，用户可以直接查看、修改和恢复默认配置。

页面入口：

1. 路由：`/web/settings`。
2. 左侧项目栏底部或顶部工具区增加 Settings 图标按钮，点击进入 `/web/settings`。
3. 设置页提供返回工作台按钮；如果进入设置页前有当前项目和 thread，返回到对应 `/web/projects/:project_id/threads/:thread_id`。
4. 直接访问或刷新 `/web/settings` 时，Phoenix 仍返回前端入口，由 React 根据 pathname 渲染设置页。

前端结构：

1. 页面组件：`web/src/features/settings/SettingsPage.jsx`。
2. 状态仍由 `web/src/App.jsx` 统一持有和通过 Channel 同步。
3. 样式使用 Sass，优先放在 `web/src/styles/_components.scss`；如果配置页样式增长明显，再拆到 `web/src/styles/_settings.scss` 并由 `main.scss` 汇总。
4. 不引入 TypeScript、Tailwind、CSS-in-JS、Less 或组件库主题系统。
5. 所有表单控件使用稳定 `className`，按钮和图标继续复用现有 `IconButton` 与 lucide icons。

设置面板分组：

1. Agent：Model、Reasoning effort、Approval policy、Sandbox mode。
2. Images：Default ratio、Default count、Transparent background。
3. Projects：Default project folder、Restore last opened project。
4. Assets：Scan project images on open。

页面布局：

1. 页面保持 Avcs 工作台的安静工具型风格，不做营销页或独立启动页。
2. 左侧窄栏展示配置分组导航，右侧展示当前分组表单。
3. 每个配置项显示名称、当前值、是否使用默认值和 Reset 操作。
4. 页面底部或分组头部提供 Save、Cancel、Reset changed 操作。
5. 有未保存更改时，离开页面前提示确认；保存成功后清除 dirty 状态。
6. 保存失败时保留用户输入，展示错误 notice，并不覆盖已确认的远端状态。

交互规则：

1. 应用启动或 Channel join 后，前端调用 `site_settings:get` 并缓存到 app state。
2. 新建空白项目时，`projects.default_root` 作为默认根目录；为空或不可用时回退 `~/Documents/Avcs`。
3. 新建 thread 时，后端使用全局 `agent.*` 作为 thread 默认值。
4. 当前 thread 没有默认 Agent 设置时，Composer settings summary 使用全局默认值作为 fallback。
5. Image settings panel 初始值来自全局 `image.*` 默认值；用户本轮调整后只影响本次 composer，发送成功后恢复到全局默认值。
6. `assets.scan_on_open=true` 时，打开项目后由后端触发已有扫描流程，并通过现有 `assets:updated`、`board:item:created` 等事件同步 UI。
7. 保存成功后合并返回的 settings；保存失败时显示现有 notice，不更新本地已确认状态。
8. Reset 使用删除覆盖值的方式恢复默认，不写入默认值副本。
9. `/web/settings` 页面只调用 `site_settings:*` Channel 事件，不直接调用 SQLite 或新增公开 HTTP API。

## commands

不新增配置初始化 Mix 命令。默认值注册在 `Avcs.SiteSettings` 代码中完成，全局库只保存用户覆盖值。

实现后建议运行：

```bash
mix test test/avcs/projects_test.exs test/avcs/local_first_test.exs test/avcs_web/channels/avcs_channel_test.exs
```

前端调试仍使用 Vite dev server，不主动运行生产 build：

```bash
cd web && npm run dev
```

## others

验收重点：

1. 全局软件配置写入 `~/.avcs/avcs.sqlite3` 的 `app_settings` 表，不写入项目 SQLite。
2. `app_settings` 只保存软件级偏好和默认值，不保存项目业务数据。
3. 项目 SQLite 的 `settings` 表不参与本计划。
4. 未注册 key 无法写入。
5. 新建 thread 会继承全局 Agent 默认值。
6. 当前 thread 设置可以覆盖全局 Agent 默认值。
7. 图片默认参数只影响 composer 默认状态和发送 prompt，不改变 turn 数据模型。
8. React 不直接访问 SQLite 或本地文件系统。
9. `/web/settings` 可以直接访问、刷新和返回工作台，并能完成配置查看、保存和恢复默认。

## prds

完成实现后同步更新：

1. `docs/prds/overview.md`：修订全局 SQLite 职责，补充全局软件配置不属于项目业务数据。
2. `docs/prds/features/projects/001-项目打开与初始化.md`：补充新建空白项目默认根目录来自全局软件配置。
3. `docs/prds/features/turns/001-聊天输入与消息展示.md`：补充全局 Agent 默认值和 Image settings 默认值。
4. `docs/prds/features/ui/001-三栏工作台UI.md`：补充全局设置入口、`/web/settings` 设置页和返回工作台交互。
