# 006 Codex Agent 调用

状态：Draft  
领域：`lib/avcs/agent`

## 1. 目标

Avcs 通过 `codex app-server` 调用 Codex Agent 能力，不在 Avcs 内部实现独立大模型服务、工具协议或复杂 Agent 编排。

## 2. 调用方式

MVP 默认启动命令：

```bash
codex app-server
```

该命令默认使用 `stdio://`，通过 stdin/stdout 传输 newline-delimited JSON，也就是 JSONL。消息遵循 JSON-RPC 2.0 形态，但 wire format 省略 `"jsonrpc": "2.0"` 字段。

参考文档：

1. Codex App Server
2. Codex CLI reference 中的 `codex app-server`

## 3. 协议流程

后端需要按 Codex app-server 官方协议完成：

1. 启动并持有 `codex app-server` 进程。
2. 连接建立后先发送 `initialize` 请求。
3. 随后发送 `initialized` 通知。
4. 使用 `thread/start` 创建 Codex 会话。
5. 需要继续同一 Codex 会话时使用 `thread/resume`。
6. 用户发送消息时，通过 `turn/start` 传入 `threadId`、用户文本、聊天输入区当前引用的图片路径、当前项目 `cwd` 和必要运行设置。
7. 当前 thread 已有 active turn 且用户继续输入时，通过 `turn/steer` 把追加输入发送到 active turn，不创建新的 Avcs turn。
8. 用户主动停止时，通过 `turn/interrupt` 发送 `threadId` 和 `turnId`；如果 Codex turn id 尚未返回，先记录 pending interrupt，拿到 id 后立即发送。
9. queued turn 尚未分配 app-server worker 时，直接取消队列并把本地 turn 标记为 `interrupted`。
10. 用户编辑历史起始消息并重跑时，如本地 thread 已有 `codex_thread_id`，优先调用 `thread/fork` 创建新 Codex thread，再对新 thread 调用 `thread/rollback` 回到锚点前的 Codex 历史。
11. `thread/rollback` 的 `numTurns` 由本地有效 turn 路径计算，包含被编辑的锚点 turn，保证后续 `turn/start` 使用编辑后的文本重新执行。
12. 持续读取 `thread/*`、`turn/*`、`item/*`、工具进度和错误通知。
13. 将 Codex 输出转换为 Avcs 自己的 turn/item/asset 记录。

## 4. 行为约束

1. Agent 不主动追问用户缺失信息。
2. 信息不足时，Agent 应使用合理默认值继续完成任务，并在输出中简短说明假设。
3. Agent 不做跨项目长期记忆。
4. Agent 只接收当前 thread、用户输入、聊天输入区当前引用的资产和必要项目元信息。
5. 图片生成必须真实接入 Codex built-in `image_gen`；MVP 不用 mock/stub 替代图片生成。
6. Avcs 通过系统提示词限制图片生成风格、输出路径、命名规则和结果回传格式，要求 Agent 将生成图片保存到或回传到当前项目 `output/` 目录可捕获的位置。
7. 当本轮包含 `mask_edit` 时，Avcs 传入原图和 mask 图两条引用，并在发送给 Codex 的文本中附加视觉参考指令：mask 白色或已标记区域表示需要编辑，黑色或未标记区域表示尽量保持不变。
8. `mask_edit` 不等同正式图片编辑 API 的 mask 参数；Agent 只能按视觉参考能力执行。
9. Codex `thread/rollback` 只影响 Codex 会话历史，不撤销 Avcs 项目文件夹中的 `work/`、`output/` 或 SQLite 记录；本地旧路径由 Avcs 自己用 invalidation 字段隐藏。
10. 如果 `thread/fork` 或 `thread/rollback` 不可用，Avcs 可降级清空本地 `codex_thread_id` 并新开 Codex thread，但必须记录 trace，且 Agent 只能获得编辑后的当前 turn 上下文。

## 5. 事件映射

Codex app-server 输出需要映射到 Avcs：

1. `thread/*` 映射到 thread 状态。
2. `turn/*` 映射到 turn 生命周期；Codex `interrupted` 映射为 Avcs `interrupted`，不按普通失败处理。
3. `item/*` 映射到用户消息、Assistant 消息、工具调用、工具结果、图片资产和错误。
4. 工具进度映射到聊天区工具状态行。
5. 错误通知映射到当前 turn 的 error item 和前端 error 事件。
6. `mask_edit` 元信息写入本地 user message payload，用于追溯本轮原图与 mask 引用关系。
7. 历史编辑重跑时，本地会先广播更新后的用户 item 和刷新后的有效 item 列表，再沿用普通 `turn/start` 生命周期映射新输出。

## 6. 兼容性

Codex app-server 当前属于实验性接口。Avcs 实现应显式记录兼容的 Codex CLI 版本，并在升级 Codex 时重新验证 JSON Schema 与事件映射。

Avcs 将 Codex app-server JSON Schema 作为 Elixir 后端协议契约提交到仓库：

```bash
codex app-server generate-json-schema --out priv/codex_app_server/schemas
```

`priv/codex_app_server/schema_manifest.json` 记录 `codex_version`、`schema_command`、`schema_draft` 和 `generated_at`。升级 Codex CLI 后必须重新生成 schema，检查 `priv/codex_app_server/schemas` 和 manifest 的 diff，并更新后端事件映射测试。

Schema 只用于 Elixir 后端开发期和测试期协议校验，不暴露给 React，不意味着 Avcs 前端可以直接调用 Codex app-server，也不意味着前端可以引入 TypeScript。

校验策略：

1. 单元测试中关键 request / response / notification 必须通过 JSON Schema。
2. dev / test 运行时校验关键消息，失败记录 warning 后继续使用兼容解析。
3. prod 默认不运行 schema 校验，避免 Codex 协议漂移直接中断用户流程。

## 7. 错误处理

需要覆盖：

1. app-server 启动失败。
2. initialize 失败。
3. stdio JSONL 解析失败。
4. `thread/start` 或 `thread/resume` 失败。
5. `turn/start` 失败。
6. Agent 运行中断。
7. 工具调用失败。
8. 历史编辑重跑中的 `thread/fork` 或 `thread/rollback` 失败。

错误应写入当前 turn/item，并通过 WebSocket 推送给前端。

用户主动 Stop 属于 `interrupted` 状态，不新增 error item，也不在前端显示为红色失败。

## 8. 验收标准

1. 后端可以启动并持有 `codex app-server` 进程。
2. 后端能完成 initialize / initialized 流程。
3. 后端能通过 `thread/start` 或 `thread/resume` 管理 Codex 会话。
4. 用户发送消息时，后端能通过 `turn/start` 传入文本、图片引用、项目 `cwd` 和必要设置。
5. 当前 thread 运行中追加输入时，后端能通过 `turn/steer` 发送到 active turn。
6. 用户停止当前 turn 时，后端能通过 `turn/interrupt` 或 queued cancel 把本地 turn 收敛为 `interrupted`。
7. Agent 输出能写回项目 SQLite 的 turn/item。
8. Avcs 不在内部实现独立大模型服务或自定义工具协议。
9. 历史消息编辑重跑时，后端能使用 `thread/fork` 和 `thread/rollback` 准备 Codex 历史，或在不可用时降级为新 Codex thread 并记录 trace。
