---
git_commit_message: 'feat: trace codex rpc messages'
plan_state: finished
---
# 003 Codex RPC Tracing

## current_status

当前 tracing 页面已经能通过 `trace:events:list` 展示项目 SQLite 中的 `trace_events`，但现有事件主要是 Avcs 业务生命周期和 Codex 输出映射结果：

1. `turn_created` 是 Avcs 后端处理前端 `message:send` 后，创建本地 turn / user item 时写入的 trace，不是发给 Codex 的 RPC。
2. `turn_started`、`turn_completed`、`item_started`、`item_completed` 等事件由 Runner 把 Codex 通知映射成 Avcs turn / item 事件后写入。
3. `Avcs.Agent.CodexClient` 实际通过 stdio JSONL 发送 `thread/start`、`thread/resume`、`turn/start`、`turn/steer`、`turn/interrupt` 等 JSON-RPC 消息，但这些出站 RPC 目前没有作为独立 trace 记录。
4. 入站 Codex 原始消息只在部分映射事件的 `raw` 字段中保留；如果只关心真实 Codex RPC，很难和 Avcs 自身事件区分。
5. `asset_id` 是 Avcs 术语；真正发给 Codex 的图片引用应是 `turn/start` / `turn/steer` 的 `input` 中的 `localImage.path`。

## overview

新增一个明确的 tracing 约定：所有 Phoenix 后端与 Codex app-server 之间的 JSON-RPC 收发，都以 `scope = "codex_rpc"` 写入 `trace_events`。

目标：

1. 在 `/web/tracing/:thread_id` 中可以用 `scope=codex_rpc` 过滤出真实 Codex RPC。
2. 出站 RPC 记录 Avcs 发给 Codex 的 JSON-RPC 请求或通知，例如 `thread/start`、`thread/resume`、`turn/start`。
3. 入站 RPC 记录 Codex 返回的 response、notification 和 error response。
4. `Payload` 只放便于过滤和定位的摘要字段；`Raw` 放经过 `Avcs.Trace` 脱敏 / 截断后的原始 JSON-RPC 对象。
5. 保留现有 Avcs 业务 trace，不把 `turn_created` 误命名为 Codex RPC。
6. 不让 React 直接接触 Codex app-server；前端仍只读取后端提供的 trace events。

## terminology

本计划按三层事件区分命名：

1. WebSocket 事件：React 与 Phoenix 之间的事件，例如 `message:send`、`trace:events:list`。
2. Avcs trace 事件：Avcs 本地业务状态变化，例如 `turn_created`、`item_created`、`assets:resolved`。
3. Codex RPC 事件：Phoenix 后端与 `codex app-server` 之间的 JSON-RPC stdio 消息，例如 `turn/start` request、`turn/started` notification。

`codex_rpc` 只表示第 3 层。

## data_model

不新增表，复用现有 `trace_events`。

字段约定：

1. `scope`：固定为 `codex_rpc`。
2. `event_name`：使用 `request_sent`、`response_received`、`notification_received`、`decode_failed`、`request_timeout`、`port_exited`。
3. `thread_id`：Avcs thread id。由于 `trace_events.thread_id` 非空，MVP 只记录能关联到项目 thread 的 RPC。
4. `turn_id`：Avcs turn id；thread-level RPC 可为空。
5. `codex_thread_id`：从 RPC params / result / active context 中提取。
6. `codex_turn_id`：从 RPC params / result / notification 中提取。
7. `codex_item_id`：从 item notification 的 `params.item.id` 中提取。
8. `status`：`sent`、`received`、`ok`、`error`、`timeout`。
9. `payload`：摘要字段，便于搜索和列表扫描。
10. `raw`：原始 JSON-RPC 对象或无法解析行的安全摘要。

`payload` 示例：

```json
{
  "direction": "outbound",
  "transport": "stdio_jsonl",
  "method": "turn/start",
  "rpc_id": 4,
  "phase": "turn_start_response",
  "schema": "turn_start_params"
}
```

如后续 trace event 很多，可补充索引：

```sql
CREATE INDEX IF NOT EXISTS idx_trace_events_scope
  ON trace_events(scope, created_at);
```

## event_contract

### request_sent

Avcs 写入 Codex app-server stdio 前记录。

覆盖：

1. `initialize`
2. `initialized`
3. `model/list`，仅在有 thread trace context 时记录；普通设置页拉模型可以不落项目 trace。
4. `thread/start`
5. `thread/resume`
6. `thread/read`
7. `thread/fork`
8. `thread/rollback`
9. `turn/start`
10. `turn/steer`
11. `turn/interrupt`
12. `thread/approveGuardianDeniedAction`

`raw` 保存即将发送的 JSON 对象。`turn/start` 的 `raw.params.input` 应包含文本和 `localImage.path`，不应包含 Avcs `asset_id`。

### response_received

Codex 返回带 `id` 的 `result` 或 `error` 时记录。

要求：

1. 通过 `rpc_id` 关联到对应出站 request。
2. `payload.method` 优先使用 request id 关联表中的 method。
3. result response 的 `status` 为 `ok`。
4. error response 的 `status` 为 `error`，并在 `payload.error_code` / `payload.error_message` 中保留摘要。
5. `raw` 保存完整 response 对象，继续使用现有大字段截断逻辑。

### notification_received

Codex 返回带 `method` 且不带 `id` 的 notification 时记录。

覆盖：

1. `turn/started`
2. `turn/completed`
3. `item/started`
4. `item/completed`
5. `item/agentMessage/delta`
6. `item/autoApprovalReview/started`
7. `item/autoApprovalReview/completed`
8. `thread/name/updated`
9. `error`
10. 其它未来 Codex notification

通知仍按现有逻辑继续映射为 Avcs turn / item 事件；`codex_rpc` 事件只是额外保留真实协议消息。

### decode_failed

Codex stdout 行无法 JSON decode 时记录。

要求：

1. 只在当前 active request 有 Avcs thread context 时记录。
2. `payload.reason` 保存 decode 错误摘要。
3. `raw` 不保存无限长原始字符串；保存 line preview、byte size、sha256。

### request_timeout / port_exited

CodexClient 超时或 app-server port 退出时记录。

要求：

1. 事件挂到当前 active Avcs thread / turn。
2. `payload` 保存 phase、timer_kind、os_pid、exit_status 或 reason。
3. 不替代现有失败处理；只是补充可观测性。

## backend

### CodexRpcTrace helper

新增 `Avcs.Agent.CodexRpcTrace`，集中处理 trace 规范：

1. `append_outbound(project, context, message, meta)`
2. `append_inbound(project, context, message, meta)`
3. `append_decode_failed(project, context, line, reason)`
4. `append_runtime_error(project, context, event_name, meta)`
5. `context_from_active(active)`
6. `codex_ids_from_message(message, fallback_context)`

helper 负责：

1. 跳过缺少 `project` 或 Avcs `thread_id` 的消息。
2. 统一 `scope`、`event_name`、`status`、`payload`、`raw`。
3. 从 message 中提取 `method`、`id`、`threadId`、`turn.id`、`item.id`。
4. 调用 `Avcs.Trace.append_event/3`，复用现有 payload sanitization。

### CodexClient integration

在 `Avcs.Agent.CodexClient` 中集中替换直接 `send_json(port, message)` 的调用：

1. 新增 `send_rpc(state, message, meta \\ %{})`，负责写 trace 后再写 stdio。
2. 保留底层 `send_json/2` 只做 `Port.command`。
3. 对没有 Avcs thread context 的请求，`send_rpc` 只发送、不落项目 trace。
4. 在 active state 中维护 `rpc_requests_by_id`，记录 `%{id => %{method, phase, schema, sent_at}}`。
5. 收到 response 时用 `rpc_requests_by_id` 补齐 `payload.method`、`phase`、`schema`。
6. 收到 notification 时在语义映射前先写 `notification_received`。
7. decode 失败、timeout、port exit 时按当前 active context 写入错误类 `codex_rpc` trace。

需要重点处理的发送点：

1. `start_initialize/2`：`initialize` 和 `initialized`。
2. `start_request/2`：`model/list`、`thread/read`、`thread/fork`、`thread/rollback`。
3. `send_thread_request/2`：`thread/start` / `thread/resume`。
4. `send_turn_start/2`：`turn/start`。
5. `send_turn_steer/3`：`turn/steer`。
6. `send_turn_interrupt/3`：`turn/interrupt`。
7. `handle_approval_response/2`：`thread/approveGuardianDeniedAction`。
8. `start_thread_name_refresh/2`：完成后刷新 thread name 的 `thread/read`。

### Runner and Pool context

`Avcs.Agent.Runner` 已在调用 Codex client 时传入：

1. `project`
2. `avcs_thread_id`
3. `avcs_turn_id`
4. `codex_thread_id`
5. resolved `reference_paths`

计划要求：

1. 保持 `asset_ids -> reference_paths -> localImage.path` 的边界，Codex RPC trace 不出现 Avcs `asset_id`。
2. `Avcs.Agent.CodexAppServerPool.run_turn/8` 继续把 `avcs_thread_id` / `avcs_turn_id` 放进 opts，保证 worker `CodexClient` 能拿到 trace context。
3. 为 `read_thread`、`fork_thread`、`rollback_thread` 增加可选 trace context opts，例如 `project`、`avcs_thread_id`、`avcs_turn_id`。这样 repair / edit rerun 的 thread-level RPC 也能进入同一 thread trace。
4. `list_models` 默认不写项目 trace，除非调用方显式提供 thread context。

## ui

MVP 不新增独立页面，复用现有 tracing 页面。

前端改动建议：

1. `TracingPage.jsx` 已按 `scope` 自动生成过滤项；新增 `codex_rpc` trace 后可以直接过滤。
2. 可增加一个轻量快捷筛选按钮或 preset：`Codex RPC`，等价于设置 `scope=codex_rpc`。
3. event detail 中保留现有 `Payload` / `Raw` 展示。
4. 对 `scope=codex_rpc` 的事件，可在标题区域额外显示 `payload.method`、`payload.direction`、`payload.rpc_id`，降低打开 JSON 的频率。
5. 导出 markdown 时补充 RPC method / direction / rpc id 列；如果不做列扩展，也必须确保完整 JSON 仍可导出。

不做：

1. 不在前端解析 Codex app-server schema。
2. 不新增前端到 Codex 的调试入口。
3. 不把 `message:send` 包装成 `codex_rpc`。

## tests

后端测试重点：

1. `Avcs.Agent.CodexClient` fake codex run_turn 后，项目 trace 中出现 `scope = "codex_rpc"` 的 `thread/start` 或 `thread/resume`、`turn/start` request。
2. `turn/start` 的 `raw.params.input` 包含 `localImage.path`，不包含 Avcs `asset_id`。
3. response 能通过 `rpc_id` 回填 `payload.method`。
4. notification 能记录 `method = "turn/started"`、`method = "item/completed"` 等真实 Codex method。
5. Codex error response 写入 `status = "error"`，且保留 `payload.error_message`。
6. stdout decode 失败时写入 `decode_failed`，不会写入超长原始字符串。
7. idle timeout / request timeout 写入 `request_timeout`，现有失败 item / turn 状态不回退。
8. `turn_created` 仍是 Avcs trace，`scope` 不变，避免和 `codex_rpc` 混淆。
9. 大 base64 / image result 仍通过 `Avcs.Trace.sanitize_payload/2` 截断。

前端测试 / 验证重点：

1. tracing 页面 scope filter 自动出现 `codex_rpc`。
2. 选择 `codex_rpc` 后只显示真实 Codex RPC 事件。
3. RPC detail 中能看到 `Payload` 摘要和 `Raw` JSON。
4. markdown 导出包含 RPC 事件，并能区分 request / response / notification。

## implementation_steps

1. 增加 `Avcs.Agent.CodexRpcTrace` helper 和单元测试，先锁定 trace event shape。
2. 在 `CodexClient` 中集中引入 `send_rpc` 和 `rpc_requests_by_id`，先覆盖 `turn/start` 主链路。
3. 扩展到 thread start / resume / read / fork / rollback / steer / interrupt / approval response。
4. 增加 decode failed、timeout、port exited 的 trace。
5. 补充 pool / runner 的 thread context 传递，确保 repair / rerun 也能记录 thread-level RPC。
6. 小幅更新 tracing UI 的 `codex_rpc` 快捷筛选和详情摘要。
7. 更新 PRD，并跑后端测试；前端只做 dev server 手动验证，不主动跑生产 build。

## acceptance_criteria

1. 用户打开 `/web/tracing/:thread_id` 后，可以通过 `scope=codex_rpc` 看到真实 Codex JSON-RPC 收发序列。
2. `turn_created` 不再被误解为 Codex RPC；它仍保留为 Avcs 本地业务 trace。
3. `turn/start` 的 Raw 明确展示实际发给 Codex 的 params，包括文本、`localImage.path`、`cwd`、model / effort / approval / sandbox 设置。
4. `codex_rpc` trace 中不出现 Avcs `asset_id` 作为 Codex 输入字段。
5. Codex response / notification 和 Avcs turn / item 映射事件可以按时间线相互对照。
6. 大字段被安全截断，项目 SQLite 不因图片 base64 或超长结果膨胀。
7. 缺少 thread context 的全局 RPC 不强行写入项目 trace。

## prds

完成实现后更新：

1. `docs/prds/features/agent/001-Codex-Agent调用.md`：补充 `codex_rpc` trace scope、request / response / notification 记录规则。
2. `docs/prds/features/agent/002-交互审批.md`：补充审批 response 的 Codex RPC trace。
3. `docs/prds/features/ui/003-Codex聊天区对齐.md`：补充 tracing 页面可按 `codex_rpc` 查看真实协议消息。
4. 必要时同步 `docs/prds/overview.md` 的 Codex app-server 可观测性描述。
