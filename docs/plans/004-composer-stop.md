---
git_commit_message: 'chat: plan composer stop action'
plan_state: finished
---
# Composer stop action while running

## current_status

当前聊天 composer 已使用 CodeMirror，发送按钮位于右下角，`App.jsx` 用 `runningTurns` 维护当前运行中的 thread/turn。

现有行为：

1. `ChatPane` 的 `sendDisabled` 在 `agentRunning` 时直接禁用发送按钮。
2. 输入为空且没有图片引用时，发送按钮也会禁用。
3. `PromptEditor` 运行中仍可编辑，因为只受 `canUseChat` 控制。
4. `App.handleSend` 在 `agentRunning` 时直接返回，因此前端无法触发后端已有的 active turn steer。
5. 后端 `message:send` 如果发现当前 thread 有 active turn，会追加 steered user item 并调用 `turn/steer`。
6. Codex schema 快照已有 `turn/interrupt`，参数是 `threadId` 和 `turnId`；当前 `CodexClient`、`CodexAppServerPool`、`Runner` 和 Channel 尚未暴露停止能力。
7. 运行完成事件已经通过 `agent:run_completed` 清理前端运行态，但本地 turn 目前把 Codex `interrupted` 映射成 `failed`。

主要缺口：

1. 当前 thread 运行中且 composer 为空时，主按钮是 disabled，而不是 running/stop 状态。
2. 用户无法从 composer 停止当前 Codex turn。
3. 运行中非空输入的 steer 能力已在后端存在，但被前端 guard 挡住。
4. 用户主动 Stop 不应被展示成普通失败。

## overview

目标是让 composer 主按钮参考 Codex 的发布框：当前 thread 正在运行时，空 composer 的主按钮进入 running/stop 状态，点击后停止当前 turn；如果运行中 composer 有文本或图片引用，则继续作为追加输入发送到 active turn。

边界：

1. React 仍只通过 Phoenix Channel 调用后端，不直接调用 Codex app-server。
2. Stop 只作用于当前 thread 的 active turn，不影响其他正在运行的 thread。
3. 非空输入继续复用 `message:send` + `turn/steer`，不创建新 turn。
4. 空输入 + running 调用新增 stop 事件，不经过 `message:send` 的空消息校验。
5. Stop 覆盖 running、queued、waiting approval 三类运行态。
6. 本计划不增加暂停、恢复、重试、后台任务队列管理页或全局 kill app-server 操作。

## data_model

不新增表。复用项目 SQLite 的 `turns` 和 `items`。

调整 turn 状态约定：

1. 新增本地 turn 状态值 `interrupted`，表示用户主动停止或 Codex 返回 `interrupted`。
2. `completed_at` 在 `completed`、`failed`、`interrupted` 时写入。
3. 用户主动 Stop 不新增 `error` item；turn 可保存简短 `error` 文本用于 trace，例如 `Stopped by user`，但 UI 不按失败样式渲染。
4. `Avcs.Agent.Runner.local_turn_status/1` 把 Codex `interrupted` 映射为本地 `interrupted`，不再映射为 `failed`。
5. `turn_error_message/1` 对 Codex `interrupted` 返回 `nil` 或 `Stopped by user`，避免聊天列表出现红色错误块。

前端临时状态：

```js
{
  runningTurns: {
    [threadId]: {
      thread_id: threadId,
      turn_id: turnId,
      status: "running" | "waiting_approval" | "stopping"
    }
  }
}
```

`stopping` 只用于前端请求已发出、等待 `agent:run_completed` 的过渡态，不写入 SQLite。

## api

新增 Channel 事件：

```json
{
  "thread_id": "avcs-thread-id",
  "turn_id": "avcs-turn-id"
}
```

事件名：`turn:stop`

响应：

```json
{
  "thread_id": "avcs-thread-id",
  "turn_id": "avcs-turn-id",
  "status": "stopping"
}
```

后端规则：

1. `thread_id` 必须属于当前项目；缺省时可使用当前 selected thread。
2. `turn_id` 缺省时解析当前 thread 的 active turn；传入时必须匹配 active turn。
3. 没有 active turn 返回 `turn_not_running`。
4. queued turn 还未分配 worker 时，从 pool waiting queue 中移除并把本地 turn 标记为 `interrupted`。
5. 已分配 worker 时，通过 Codex app-server 发送 `turn/interrupt`。
6. 如果 Codex turn id 尚未从 `turn/start` response 或 `turn/started` notification 得到，记录 pending interrupt，拿到 Codex turn id 后立即发送。
7. `turn/interrupt` 返回成功只表示停止请求已被 Codex 接受；最终状态仍以后续 `turn/completed` 或 runner cleanup 为准。

新增或调整后端函数：

```elixir
Avcs.Agent.Runner.stop(project, thread_id, turn_id)
Avcs.Agent.CodexAppServerPool.interrupt_turn(project, thread_id, turn_id)
Avcs.Agent.CodexClient.interrupt_turn_on(worker, thread_id, turn_id, opts \\ [])
Avcs.Turns.interrupt_turn(project, turn_id, codex_turn_id \\ nil, reason \\ "Stopped by user")
```

`CodexClient` 请求参数：

```json
{
  "threadId": "codex-thread-id",
  "turnId": "codex-turn-id"
}
```

推送策略：

1. Stop 请求 accepted 后可以不新增推送，只由前端本地进入 `stopping`。
2. turn 真正结束时继续广播 `agent:run_completed`，`status` 使用 `interrupted`。
3. 同步广播 `threads:updated` 和项目更新时间，保持左侧栏运行态、更新时间一致。
4. 如果 interrupt 失败，广播 `error`，并保持 running 状态直到 Codex turn 自然完成或失败。

兼容现有 `message:send`：

1. 空消息仍由 `message:send` 返回 `empty_message`，不承担 stop 语义。
2. 运行中非空消息继续走 active turn steer，并保留 `payload.steered = true`。
3. `App.handleSend` 需要移除 `agentRunning` 直接返回的 guard，让 steer 能从 UI 触发。

## ui

`ChatPane` 增加 `onStop` prop，并把主按钮模式从单一 send 改为派生状态：

```js
const hasDraft = prompt.trim() || references.length > 0;

if (agentRunning && !hasDraft) mode = "stop";
else if (agentRunning && hasDraft) mode = "steer";
else if (hasDraft) mode = "send";
else mode = "disabled";
```

按钮行为：

1. `stop`：按钮可点击，使用 stop 图标，`title` / `aria-label` 为 `Stop`，点击调用 `onStop(activeRun)`。
2. `stopping`：Stop 请求已发出后按钮禁用，`title` / `aria-label` 为 `Stopping`。
3. `steer`：运行中有文本或引用时按钮可点击，调用现有 `onSend`，发送后清空本轮输入和引用。
4. `send`：非运行态有文本或引用时调用现有 `onSend`。
5. `disabled`：未运行且无文本/引用时禁用。

禁用规则：

1. WebSocket 离线或未打开项目时，按钮禁用。
2. 有上传中的 pending image 时，只禁用 `send` / `steer`，不阻止 `stop`。
3. waiting approval 状态下，空 composer 仍显示 Stop，点击后 interrupt 当前 turn。
4. 运行中切换到非当前 thread 时，只有该 thread 被选中后才显示 Stop。

视觉要求：

1. 继续使用圆形 icon button，不加入长文案。
2. `send` / `steer` 使用现有 `Send` icon 和 action 色。
3. `stop` / `stopping` 使用 lucide stop 类图标，例如 `CircleStop` 或 `Square`。
4. `.send-button` 增加 `running` / `stopping` class 或 `data-mode`，在 Sass 中维护颜色、hover、disabled，不使用 inline 静态视觉样式。
5. `interrupted` turn 在列表中显示为 `stopped` 或 `interrupted` 的中性色状态，不使用错误红色。

键盘行为：

1. `Enter` 和 `Mod-Enter` 仍走 composer 主 action。
2. 运行中空 composer 触发 Stop。
3. 运行中非空 composer 触发 steer。

## commands

实现后建议运行：

```bash
mix test test/avcs/agent/codex_client_test.exs test/avcs/agent_runner_test.exs test/avcs_web/channels/avcs_channel_test.exs
```

前端调试仍使用 Vite dev server，不主动运行生产 build：

```bash
cd web && npm run dev
```

## others

验收重点：

1. 当前 thread 运行中且 composer 为空时，右下角主按钮显示 running/stop 状态且可点击。
2. 点击 Stop 后，Codex turn 被 interrupt，前端进入短暂 stopping 状态，随后运行态清除。
3. 用户主动 Stop 的 turn 不显示为普通失败，不产生红色错误块。
4. 当前 thread 运行中且 composer 有文本或图片引用时，按钮仍能发送追加输入并走 steer。
5. 有图片上传中时，用户仍能 Stop 当前 turn。
6. waiting approval 时 Stop 可用，停止后审批 UI 不再保持 pending。
7. Stop 只影响当前 thread，不影响左侧其他 running thread。
8. 刷新页面后，被停止的 turn 状态保持为 `interrupted`。

## prds

完成实现后同步更新：

1. `docs/prds/features/turns/001-聊天输入与消息展示.md`：把“Agent 运行中发送按钮 loading 或 disabled”改为“空 composer 显示 Stop，非空 composer 可 steer”，并补充 `interrupted` 状态展示。
2. `docs/prds/features/ui/003-Codex聊天区对齐.md`：补充 composer 主按钮 running/stop/steer 模式和 `interrupted` turn UI。
3. `docs/prds/features/web/002-WebSocket状态同步.md`：补充 `turn:stop` 客户端事件与 `agent:run_completed.status = interrupted`。
4. `docs/prds/features/agent/001-Codex-Agent调用.md`：补充 Codex app-server `turn/interrupt` 封装、pending interrupt 和 queued turn cancel 规则。
