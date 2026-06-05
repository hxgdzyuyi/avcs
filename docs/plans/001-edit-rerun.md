---
git_commit_message: 'turns: plan edit rerun flow'
plan_state: finished
---
# 001 历史消息编辑与从该点重跑

## current_status

1. `Avcs.Turns` 已用 `turns` 和 `items` 保存聊天历史，`items.type = user_message` 表示用户消息，`turns.user_text` 保存该 turn 的起始用户文本。
2. `ChatPane` 已有用户消息编辑入口，前端 `handleUpdateItem` 通过 `item:update` 只更新消息文本，不会让后续内容失效，也不会重启 Agent。
3. Agent 运行由 `Avcs.Agent.Runner.submit/5` 和 `start/6` 负责；运行中追加输入走 `turn/steer`，未运行时创建新 turn 后走 `turn/start`。
4. `CodexClient` 当前实现了 `thread/start`、`thread/resume`、`thread/read`、`turn/start`、`turn/steer` 和 `turn/interrupt`，尚未封装 schema 中已有的 `thread/fork` 与 `thread/rollback`。
5. `thread/rollback` 只回滚 Codex thread 历史，不会撤销本地文件变更；Avcs 需要自己处理本地 turn、item、asset link 和 board item 的失效。
6. `assets` 和 `board_items` 会记录生成结果与 `thread_id`、`turn_id`、`item_id` 的关联；当前列表查询不会按聊天分支失效过滤。

## overview

新增“编辑历史用户消息并从该点重跑”能力。用户编辑某条已完成的起始用户消息后，系统更新该消息文本，把该消息之后的本地对话路径标记为失效，并从编辑后的消息重新启动 Agent，形成新的后续路径。

边界：

1. MVP 只支持编辑非 `steered` 的 `user_message`，也就是一个 turn 的起始用户消息；运行中 turn 和 `payload.steered = true` 的追加输入先禁用编辑重跑。
2. 不删除项目文件夹中的 `work/` 或 `output/` 文件，不删除 `assets` 行；旧路径只退出当前 thread 的聊天和 Output 画板视图。
3. 不实现多分支切换、旧分支恢复、diff 视图或历史版本浏览。
4. 不允许编辑时修改图片引用、mask edit 或 data provider；重跑沿用原 user item payload 中的引用和 turn 设置。
5. 当前 thread 有 active run 时不允许编辑重跑，用户需要先 Stop 或等待完成。

## data_model

项目 SQLite schema 升级：

1. `turns` 新增：
   - `invalidated_at TEXT`
   - `invalidated_by_item_id TEXT`
2. `items` 新增：
   - `invalidated_at TEXT`
   - `invalidated_by_item_id TEXT`
3. `asset_links` 新增：
   - `invalidated_at TEXT`
   - `invalidated_by_item_id TEXT`
4. `board_items` 新增：
   - `invalidated_at TEXT`
   - `invalidated_by_item_id TEXT`
5. `assets` 不新增失效字段，继续作为项目级文件索引和 hash 去重表。
6. 更新 `@schema_version`，并用 `ensure_column/4` 兼容旧项目库。

失效规则：

1. 目标 item 必须属于当前 thread，类型为 `user_message`，未失效，且不是 `payload.steered = true`。
2. 以目标 item 的 turn 为重跑锚点，更新目标 item `content`、`payload.edited_at`、`payload.previous_content`，并同步更新 `turns.user_text`。
3. 同一锚点 turn 中，目标 user item 之后的 assistant、tool、image、error item 标记失效。
4. 锚点 turn 之后的所有 turn 和 item 标记失效。
5. 与失效 turn/item 关联的 `asset_links` 和 `board_items` 标记失效；资产文件和 `assets` 行保留。
6. 重置锚点 turn：清空旧 `codex_turn_id`、`completed_at`、`error`，状态改为 `queued` 或 `in_progress`，由 runner 继续写入新结果。
7. `list_items/2`、`list_item_page/3` 默认只返回 `invalidated_at IS NULL` 的 turn/item。
8. `Board.list_items/1` 默认隐藏 `board_items.invalidated_at IS NOT NULL` 的 Output 对象。

Codex thread 处理：

1. 如果当前 thread 有 `codex_thread_id`，优先调用 `thread/fork` 创建新 Codex thread，再对 fork 后的 thread 调用 `thread/rollback`。
2. `numTurns` 等于本地有效 turn 中从锚点 turn 到结尾的数量，确保编辑后的消息作为新的 `turn/start` 输入重新执行。
3. rollback 成功后把 Avcs `threads.codex_thread_id` 更新为 fork 后的 Codex thread id。
4. fork 或 rollback 不可用时，允许降级为清空当前 `codex_thread_id` 并新开 Codex thread；降级路径需要在 trace 中记录，且 Agent 只获得编辑后的当前 turn 上下文。

## api

不新增 HTTP API。

新增 WebSocket 事件：

1. `message:edit_rerun`
   - 请求：`{ "item_id": "...", "content": "new text" }`
   - 成功响应：`{ "thread_id": "...", "turn_id": "...", "item": {...}, "invalidated_turn_ids": [...], "invalidated_item_ids": [...] }`
   - 失败响应：
     - `item_not_found`
     - `message_edit_unsupported`
     - `message_edit_conflict`
     - `empty_message`
     - `codex_rollback_failed`
     - `message_edit_rerun_failed`
2. `item:update` 保留给审批状态或普通 item payload 更新；前端用户消息编辑改用 `message:edit_rerun`。
3. 成功后广播：
   - `item:updated`：目标 user item 更新。
   - `thread:items`：刷新当前有效消息列表，避免分页窗口保留失效内容。
   - `turn:started`、`agent:run_started`、`item:created`：沿用现有 runner 事件。
   - `threads:updated`、`agent:run_completed`：沿用现有生命周期事件。

后端实现建议：

1. 新增 `Avcs.Turns.edit_and_invalidate_after(project, item_id, content)`，在单个 SQLite transaction 中完成校验、文本更新和失效标记。
2. 新增 `Avcs.Agent.Runner.rerun_from_item(project, item_id, content, settings)`，封装本地失效、Codex fork/rollback 和 `start/6`。
3. 新增 `Avcs.Agent.CodexClient.fork_thread/2`、`rollback_thread/2`，并补齐 schema 校验映射。
4. Channel handler 只做 payload 校验、错误映射和广播，不直接操作 Codex client。

## ui

1. 复用用户消息气泡现有 Pencil 编辑入口。
2. 保存按钮文案改为 `Save and rerun` / `保存并重跑`；tooltip 明确这是会截断后续路径的操作。
3. 若目标消息之后存在有效内容，保存前用现有 `ConfirmDialog` 确认；只有文本未变化时直接退出编辑。
4. Agent 运行中、目标消息已失效、目标消息为 steered 追加输入或当前没有项目连接时禁用编辑按钮。
5. 保存成功后退出编辑态，消息列表立即刷新为有效路径：保留编辑后的 user bubble，旧 assistant/tool/后续消息消失，新 run 状态出现在该消息下方。
6. 保存失败时保持编辑态和草稿文本，并在现有 notice/error 区展示后端错误。
7. 图片引用预览继续显示原 user item payload 中的 asset；MVP 不在编辑 dialog 中增删引用。
8. 分页场景下，`thread:items` 全量刷新后重置 message window 到 latest，避免旧页 cursor 指向失效 turn。

## others

测试建议：

1. `test/avcs/local_first_test.exs` 或新增 turns 测试覆盖：
   - 编辑起始 user message 会更新 item content 和 `turns.user_text`。
   - 锚点之后的 turn/item 被标记失效，默认列表不再返回。
   - 锚点 turn 内旧 assistant/tool/image/error item 被标记失效。
   - 失效 board item 不再出现在 `Board.list_items/1`。
   - steered user item、运行中 turn、空文本和已失效 item 被拒绝。
2. `test/avcs/agent/codex_client_test.exs` 覆盖 `thread/fork` 和 `thread/rollback` 请求、响应解析与 schema 校验。
3. `test/avcs/agent_runner_test.exs` 覆盖编辑重跑成功、fork/rollback 失败降级、runner 重新写入 assistant item。
4. `test/avcs_web/channels/avcs_channel_test.exs` 覆盖 `message:edit_rerun` 成功响应、错误响应和必要广播。
5. 前端如仍无测试框架，通过 Vite dev server 手动验证，不运行 `npm run build` 或 `vite build`。

手动验证：

1. 连续发送三轮消息，编辑第一轮后只保留第一轮编辑后的 user message，并从该点重新生成后续输出。
2. 编辑最后一轮消息时只替换该轮后续 Agent 输出，不影响之前 turn。
3. 旧路径生成的 Output board item 不再显示，但对应图片文件仍留在 `output/`。
4. Agent 运行中编辑按钮禁用；Stop 后可编辑重跑。
5. WebSocket 断线或后端失败时，编辑草稿不丢失。

## prds

完成后同步更新：

1. `docs/prds/features/turns/001-聊天输入与消息展示.md`：补充历史用户消息编辑、失效和重跑流程。
2. `docs/prds/features/web/002-WebSocket状态同步.md`：补充 `message:edit_rerun`、相关广播和错误码。
3. `docs/prds/features/agent/001-Codex-Agent调用.md`：补充 `thread/fork`、`thread/rollback` 以及本地文件不随 rollback 回滚的边界。
4. `docs/prds/features/ui/003-Codex聊天区对齐.md`：补充消息编辑保存并重跑交互、确认和禁用状态。
5. `docs/prds/features/board/001-画板自由布局.md`：补充旧路径 Output board item 失效后不在当前画板展示。
