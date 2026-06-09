---
git_commit_message: 'settings: add Vercel AI Gateway provider key'
plan_state: finished
---
# Vercel AI Gateway Provider Settings

## current_status

当前计划只有“用户可以在配置项中配置 Vercel AI Gateway 的 API key”这一条需求。

项目已有全局设置链路：`Avcs.SiteSettings` 把软件级配置保存到全局 SQLite 的 `app_settings`，Phoenix Channel 通过 `site_settings:get/update/reset` 读写，React `/web/settings` 使用 `SettingsPage.jsx` 展示 Agent、Images、Projects、Assets、UI 分组。

Agent 运行参数已经支持全局默认值回退到 thread，再进入 `turn/start`。但 `CodexClient` 启动 `codex app-server` 时当前只注入 PATH，尚无 provider credential 设置，也没有 secret 不回显、worker 重启和 PRD 描述。

## overview

新增全局 Provider 设置，让用户在 Settings 中保存 Vercel AI Gateway API key。这里的 Provider 指外部模型网关凭据，不是 Composer 的 Data Provider。

API key 属于软件级密钥，只写入 `~/.avcs/avcs.sqlite3` 的全局设置，不进入项目 SQLite、turn/item payload、trace raw、日志或前端长期状态。

Codex 仍是 MVP 唯一 Agent runtime。Avcs 不新增独立模型服务，只在 Codex runtime 启动 app-server 时读取全局 provider 设置并注入必要运行环境。Vercel AI Gateway 的 OpenAI-compatible base URL 固定为 `https://ai-gateway.vercel.sh/v1`，认证使用 AI Gateway API key。

## data_model

在 `Avcs.SiteSettings` 注册新 key：

1. `providers.vercel_ai_gateway.api_key`：secret string，默认 `nil`。

Secret setting 存储仍复用 `app_settings.key/value/updated_at`，value 使用 JSON 编码字符串。本地 SQLite 可以保存明文，但所有面向前端的响应必须改为 public view：

1. `value: nil`
2. `is_secret: true`
3. `has_value: true/false`
4. `masked_value`: 只展示后 4 位，例如 `••••1234`

新增内部读取函数只供后端 runtime 使用，例如 `Avcs.SiteSettings.secret_value/1` 或 `Avcs.SiteSettings.provider_runtime_settings/0`。现有 `list_settings/0`、Channel response 和广播不得返回明文 key。

## api

继续使用现有 WebSocket 事件，不新增 HTTP API。

1. `site_settings:get` 返回包含 secret metadata 的 settings item；`data.settings["providers.vercel_ai_gateway.api_key"]` 不包含明文。
2. `site_settings:update` 接受非空 `providers.vercel_ai_gateway.api_key` 并保存；空字符串不作为有效 key。
3. `site_settings:reset` 清除 `providers.vercel_ai_gateway.api_key`。
4. 更新或重置该 key 后广播 `site_settings:updated`，但广播中仍只包含 public view。

如果 payload key 未注册、key 为空或类型错误，沿用 `unknown_site_setting` / `invalid_site_setting` 错误。

## ui

在 `/web/settings` 增加 `Providers` 分组，首个设置为 `Vercel AI Gateway API key`。

交互要求：

1. 使用 password input，不默认展示明文。
2. 已配置时显示 `Configured` 和 masked suffix；输入框保持空，避免把密钥回填到 DOM。
3. 用户输入新 key 后保存即覆盖旧 key；单项 Reset 清除 key。
4. 保存、取消、未保存改动确认沿用现有 `SettingsPage` 行为。
5. 补齐英文和中文 i18n 文案。

## others

Runtime 接入：

1. 在 Codex runtime 边界新增 provider settings helper，统一把全局设置转换为 app-server 子进程配置。
2. `Avcs.Agent.CodexClient` 启动 `codex app-server` 时合并 provider env，至少注入 `AI_GATEWAY_API_KEY`；gateway base URL 保持在 Codex runtime 适配层内，不让 React 拼接。
3. 保存或重置 provider key 后，`CodexAppServerPool` 需要让 idle worker 立即失效；active turn 不被强杀，但完成后不再复用旧 env。
4. `models:list` 和后续 turn 使用新 worker 后应读取最新 key。

测试覆盖：

1. `Avcs.SiteSettings`：注册、保存、reset、public view 不泄漏明文、内部读取能拿到明文。
2. `AvcsWeb.AvcsChannelTest`：`site_settings:get/update/reset` 对 secret 的响应和广播都不包含明文。
3. `Avcs.Agent.CodexClientTest`：fake codex 记录子进程 env，确认保存 key 后 app-server 启动能收到 provider env。
4. Pool 测试覆盖 provider key 更新后的 idle worker 失效策略。

## prds

完成实现后同步更新：

1. `docs/prds/overview.md`：补充全局软件设置中的 provider secret、密钥不进入项目数据和不返回前端明文。
2. `docs/prds/features/web/002-WebSocket状态同步.md`：补充 `site_settings:*` 对 secret setting 的 public response 约定。
3. `docs/prds/features/ui/001-三栏工作台UI.md`：补充 Settings 的 Providers 分组与密钥输入行为。
4. `docs/prds/features/agent/001-Codex-Agent调用.md`：补充 Codex app-server 启动时读取全局 provider settings 并注入 runtime env。
