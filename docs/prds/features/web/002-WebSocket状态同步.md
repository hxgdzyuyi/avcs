# 011 WebSocket 状态同步

状态：Draft  
领域：`lib/avcs_web/channels`

## 1. 目标

React 与 Elixir 的应用状态同步主要通过 WebSocket / Channel 完成。文件系统操作使用 Phoenix HTTP API，API 完成后通过 WebSocket 推送项目、thread、asset 和 board 状态变化。

## 2. 通信边界

运行时通信：

```text
React 前端  <--WebSocket/HTTP API-->  Elixir/Phoenix  <--Agent Harness-->  Codex app-server / Vercel AI Gateway
```

职责：

1. React 不直接调用 Codex app-server、Vercel AI Gateway 或 OpenAI-compatible API。
2. React 不直接读写全局 SQLite 或项目 SQLite。
3. React 不直接读写本地文件系统。
4. Elixir 负责校验事件、写库、管理项目文件夹、保存图片资产，并把状态变更推送给 React。
5. Elixir 后端通过内部 Agent Harness 适配运行时。基础版 runtime 由全局设置 `agent.harness = codex | auto | avcs_agent` 决定，默认 `codex`，不在 `message:send` 等业务事件里暴露 per-turn harness 选择。
6. 当前 harness 的输出由 Elixir 解析为 turn/item/asset 事件，再通过 WebSocket 推送给 React。
7. AvcsAgent 的 pi-agent 风格工具名（`read`、`write`、`edit`、`bash`、`grep`、`find`、`ls`）只在 Phoenix 后端执行；React 不直接调用模型、SQLite、本地文件、Codex app-server、Vercel AI Gateway、OpenAI-compatible API 或 provider 脚本。

## 3. 客户端发送事件

事件命名保持直观、面向业务：

1. `project:current`：读取当前项目。
2. `project:rename`：重命名全局项目索引中的显示名；请求体为 `{ "id": "...", "name": "New Name" }`，不移动项目文件夹，不修改项目 SQLite。
3. `threads:list`：读取 thread 列表。
4. `thread:create`：新会话准备态发送第一条消息时创建 thread；点击铅笔入口不发送该事件。
5. `thread:select`：切换当前 thread。
6. `thread:items:list`：读取当前 thread 的聊天内容。
7. `message:send`：发送用户消息和当前聊天输入区引用的 asset 列表，并触发 Elixir 经 Agent Harness 调用当前 runtime；支持可选 `mask_edit` 元信息。
8. `message:edit_rerun`：编辑历史起始用户消息并从该点重跑；请求体为 `{ "item_id": "...", "content": "new text" }`。
9. `assets:list`：读取资产列表。
10. `assets:reference`：更新当前聊天输入区引用的图片资产。
11. `assets:select`：更新画板当前选中的图片资产。
12. `board:items:list`：读取画板对象列表。
13. `board:item:move`：更新画板对象位置。
14. `board:item:resize`：更新画板对象显示尺寸。
15. `board:items:update`：批量更新多个 output board item 的位置、显示尺寸和层级，用于多选移动、对齐、统一尺寸、间距整理、右键层级调整以及前端 Undo / Redo 快照提交。
16. `turn:stop`：停止当前 thread 的 active turn；queued turn 取消排队，已运行 turn 经 Agent Harness 调用当前 runtime 的 interrupt 能力中断。
17. `site_settings:get`：读取全局软件设置，payload 返回 `items` 和 `settings`。
18. `site_settings:update`：更新全局软件设置，例如 `{ "ui.locale": "zh-hans" }`。
19. `site_settings:reset`：重置全局软件设置 key，例如 `["ui.locale"]`。
20. `avcs_agent:test`：使用已保存的 Vercel AI Gateway secret 和 AvcsAgent base URL 测试后端连接；响应不得包含明文 API key。

## 4. Phoenix HTTP API 对应动作

文件系统相关动作不走 WebSocket：

1. `project:create_blank` 对应输入项目名，并在全局软件设置 `projects.default_root` 下创建不重名的空白项目文件夹，初始默认值为 `~/Documents/Avcs`。
2. `project:open_folder` 对应输入本地绝对路径，并打开或初始化现有项目文件夹。
3. `assets:import` 对应导入图片。
4. `assets:upload` 对应聊天区上传图片。
5. `assets:mask` 对应 Board 预览 dialog 上传本轮 mask PNG。
6. `assets:scan` 对应扫描项目目录图片。
7. 图片预览、打开所在文件夹、复制本地路径等文件系统相关动作。

## 5. 服务端推送事件

1. `project:updated`：当前项目状态更新。
2. `projects:updated`：全局项目索引列表更新。
3. `threads:updated`：thread 列表更新。
4. `thread:items`：返回或刷新聊天内容。
5. `agent:run_started`：Agent 开始运行。
6. `agent:thinking_tick`：active turn 期间收到任意可识别 harness 事件或响应时推送，用于推进前端 thinking 点阵；payload 只包含 `thread_id`、`turn_id`、`event_name` 和 `status` 等轻量字段。
7. `assistant:delta`：Agent 文本流式输出片段。
8. `item:created`：新增 turn/item。
9. `item:updated`：已有 item 内容、payload 或状态更新，例如历史编辑后的用户消息。
10. `tool:updated`：工具调用状态更新。AvcsAgent 工具名可能是 `image_gen`、`read`、`ls`、`find`、`grep`、`bash`、显式开启的 `write` / `edit`，但 payload 仍是 Avcs 业务 item，不暴露任意 shell / FS 能力。
11. `asset:created`：新增图片资产。
12. `assets:updated`：资产列表更新。
13. `board:item:created`：新增画板对象。
14. `board:item:updated`：画板对象位置、尺寸或层级更新。
15. `board:items`：批量变更量较大时刷新当前画板对象列表。
16. `asset:referenced`：图片资产被加入当前聊天输入引用。
17. `agent:state_snapshot`：AvcsAgent runtime 状态快照，payload 包含 `phase`、`is_streaming`、current assistant item、pending tool calls、error、active tool、pending steer 和 queued turn input。
18. `agent:run_completed`：Agent 运行完成，`status` 可以是 `completed`、`failed` 或 `interrupted`。
19. `site_settings:updated`：全局软件设置更新或重置后的全量广播。
20. `error`：可恢复错误或失败状态。

`project:rename` 成功后必须广播 `projects:updated`；如果重命名的是当前项目，还必须广播 `project:updated`。前端收到后更新左栏项目列表和当前项目显示名，不重新打开项目文件夹。

`site_settings:get`、`site_settings:update`、`site_settings:reset` 的成功响应使用现有统一信封，`data.settings` 至少包含 `ui.locale`。`ui.locale` 默认 `en`，允许 `en` 和 `zh-hans`；前端收到 `site_settings:updated` 后应立即用最新语言设置重渲染高频静态文案，不刷新页面。

Secret setting 不在 `data.settings` 或 `data.items[].value` 中返回明文。`providers.vercel_ai_gateway.api_key` 只返回 `is_secret: true`、`has_value`、`masked_value` 和更新时间等 public metadata；保存或重置后仍广播全量 `site_settings:updated`，但广播内容也不得包含明文 key。`avcs_agent:test` 只能返回连接状态、base URL 和模型摘要，不返回 key。

`board:items:update` 成功后，服务端对每个更新对象广播 `board:item:updated`，前端按 id 合并；一次批量操作超过 50 个对象时可额外广播 `board:items` 全量列表。

画板 Undo / Redo 是前端当前会话内的 history 栈，不新增 WebSocket 事件；执行撤销或重做时仍通过 `board:items:update` 提交目标 `x`、`y`、`display_width`、`display_height`、`z_index` 快照。前端收到全量 `board:items` 或切换项目后清空该 history 栈，避免旧快照覆盖新状态。

`message:send.mask_edit` 校验成功后，服务端应把 `asset_ids` 规范为 `[base_asset_id, mask_asset_id]`，并把 `mask_edit` 写入 user message payload；校验失败返回 `invalid_mask_edit`。

`message:edit_rerun` 成功后返回更新后的 `item`、锚点 `turn`、`invalidated_turn_ids` 和 `invalidated_item_ids`，并广播 `item:updated`、`thread:items` 和 `turn:started`。失败错误码包括 `item_not_found`、`message_edit_unsupported`、`message_edit_conflict`、`empty_message` 和 `message_edit_rerun_failed`。旧路径只是退出当前有效列表，文件系统和 `assets` 行不因该事件删除。

WebSocket 事件和 payload 不随 Agent Harness 改变。Harness-specific id、item、approval 和 trace 解析由后端 runtime 适配层处理；前端仍只消费 Avcs 的 thread/turn/item/asset/board 业务事件。

AvcsAgent 的受控工具失败会作为普通 tool result / `tool:updated` 同步。未启用工具返回 `status=failed`、`error.code=tool_not_allowed`；路径越界、`.avcs/`、SQLite、secret-like 文件、二进制/过大文件或 symlink escape 等权限失败由后端转换为用户可见错误，不把敏感内容、远端 raw body、大段二进制或 API key 写入 WebSocket payload。

## 6. 状态与错误

UI 必须覆盖：

1. WebSocket 连接中。
2. 已连接。
3. 断开。
4. 重连中。
5. 重连失败。
6. 当前请求失败。
7. 后端返回业务错误。
8. Mask edit payload 无效或 mask asset 文件丢失。
9. 历史消息不能编辑、当前 thread 正在运行或编辑文本为空。

聊天区和画板区都应展示可恢复的错误信息，避免用户不知道当前失败发生在 Agent、文件系统还是前端加载。

## 7. 验收标准

1. React 与 Elixir 的应用状态通信通过 WebSocket 完成。
2. 项目、thread、turn、item、asset、board item 的状态变化能通过事件同步到前端。
3. 文件操作仍通过 HTTP API，不混入 WebSocket。
4. WebSocket 断开、重连中或重连失败都有可见反馈。
5. 具体事件 payload 可以随实现调整，但不能破坏通信边界。
6. 历史消息编辑重跑通过 `message:edit_rerun` 完成，成功后当前消息列表和运行状态能通过广播同步到前端。
