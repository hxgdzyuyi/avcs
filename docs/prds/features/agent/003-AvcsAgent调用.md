# 008 AvcsAgent 调用

状态：Draft  
领域：`lib/avcs/agent`

## 1. 目标

AvcsAgent 是用户没有 Codex 时的基础版 Agent Harness。Phoenix 后端通过 Vercel AI Gateway OpenAI-compatible API 调用文本模型和图片模型，并把输出统一映射为 Avcs 的 thread、turn、item、asset 和 board 事件。

AvcsAgent 不复刻 Codex app-server、Guardian approval、repair thread、MCP、浏览器工具、任意 shell 或任意文件系统能力。AvcsAgent 可以暴露 pi-agent 风格工具名（`read`、`write`、`edit`、`bash`、`grep`、`find`、`ls`），但它们全部由 Avcs-native Elixir/Phoenix 后端受控白名单实现，不迁入 pi-agent Node runtime、依赖、sidecar、tool executor、包结构或 JSONL SessionRepo。`thread/fork` / `thread/rollback` 只实现 Avcs 本地 SQLite 当前路径语义，不调用或复刻 Codex app-server 协议。

## 2. 全局设置

默认设置：

```text
agent.harness = codex
agent.avcs_agent.base_url = https://ai-gateway.vercel.sh/v1
agent.avcs_agent.text_model = deepseek/deepseek-v4-pro
agent.avcs_agent.image_model = openai/gpt-image-2
agent.avcs_agent.max_tool_steps = 3
agent.avcs_agent.compact_threshold = 0.75
```

`/web/settings` 可以切换：

1. `codex`：固定使用 Codex Harness，也是默认值。
2. `auto`：优先 Codex；Codex 不可用且 AvcsAgent 已配置时使用 AvcsAgent。
3. `avcs_agent`：固定使用 AvcsAgent Harness。

Vercel AI Gateway API key 复用 `providers.vercel_ai_gateway.api_key` secret。明文 key 只能由后端 settings / secrets 读取；不得硬编码、打印、写入项目 SQLite、trace raw、turn/item payload、WebSocket payload、fixtures 或文档示例。

## 3. 调用流程

AvcsAgent 最小 loop：

```text
build_context -> call_model -> stream_delta -> handle_tool_calls -> append_tool_results -> maybe_compact -> finish_or_repeat
```

行为要求：

1. `build_context` 由 Elixir context transform 从本地有效 thread / turn / item 构建 messages，并区分 system、user item、assistant item、tool call、tool result、reference asset、board context 和 data provider context。
2. `call_model` 使用 `agent.avcs_agent.text_model` 调用 OpenAI-compatible `/chat/completions`。
3. `stream_delta` 解析 SSE，把 assistant 文本增量映射到现有 `assistant:delta` WebSocket 推送。
4. `handle_tool_calls` 只执行 Avcs 后端注册的受控工具。默认开放 `image_gen`、`read`、`ls`、`find`、`grep`、`bash`；`write`、`edit` 仅显式开启。
5. `append_tool_results` 把结构化 tool result 写回 messages，再继续下一轮模型调用。
6. 工具循环次数超过 `agent.avcs_agent.max_tool_steps` 后停止继续调用工具，并把 turn 收敛为可展示结果。
7. Stop 中断当前 HTTP stream / Task，turn 收敛为 `interrupted`。
8. running 中追加输入按 `turn/steer` 语义进入当前 active turn 的 pending steer 队列；AvcsAgent 在模型响应或工具批次之间的安全点将其作为 turn continuation 注入下一次模型请求，不创建新的 Avcs turn。
9. 引用图片由 Phoenix 后端读取当前项目内 asset 文件，并作为 OpenAI-compatible structured content item 传入模型；如果 gateway / 模型拒绝结构化图片输入，返回用户可见的 vision-capable model 错误提示。

## 4. Skills 与上下文

基础版只接入最小 skills：

1. 图片生成 skill：从 Avcs 内置 `priv/skills/avcs-imagegen-avcs-agent/` 加载，并引导模型调用 Avcs 后端 `image_gen` tool。Codex Harness 使用独立的 `priv/skills/avcs-imagegen-codex/`，避免两个 harness 的图片能力说明互相干扰。
2. Data Provider context：如果本轮携带 provider，后端注入 provider context 和对应 skill，模型通过受控 `bash` data provider descriptor 获取来源数据。

未使用的 skill 不进入主 prompt。skill 只从 Avcs 内置目录加载，不实现 marketplace、外部安装或跨项目 registry。skill 输出和 tool result 以结构化 JSON 或短摘要进入下一次模型输入，避免把大输出直接塞回上下文。

Codex Agent 使用 Codex built-in `image_gen`；AvcsAgent 使用 Avcs 后端 `image_gen` tool。两者共享 Avcs 的资产入库和画板展示结果，但工具调用路径不同。

Data provider 执行闭环：APOD / Steam provider 进入 context 后，模型调用 AvcsAgent `bash` tool；`bash` 只接受 `{"command_kind":"data_provider","provider":"..."}` descriptor，由 Phoenix 运行内置 provider 脚本，把下载文件写入当前项目 `work/`，解析 JSON，图片入库为 provider asset，并把 `asset_id`、`image_path`、`title`、`date`、`explanation`、`copyright` 等摘要作为 tool result 返回。下一轮模型再基于 provider context 调用 `image_gen` 生成 `output/` 海报，不要求用户手动运行脚本。

## 5. Context Compaction

AvcsAgent 使用基于 token 预算的上下文压缩：

1. 超过 `agent.avcs_agent.compact_threshold` 时触发。
2. 基础版使用本地规则摘要，不依赖额外远端 summarizer。
3. 摘要保留用户目标、未完成事项、关键 tool result、asset id、输出路径和错误。
4. 大输出只保留摘要和引用。
5. 不删除项目 SQLite 历史。

## 6. image_gen Tool

AvcsAgent 的 `image_gen` 是 Phoenix 后端工具，支持文生图、参考图输入、PNG mask edit，以及 OpenAI Image API 的常用生成选项：

```json
{
  "name": "image_gen",
  "parameters": {
    "type": "object",
    "properties": {
      "prompt": { "type": "string" },
      "aspect_ratio": { "type": "string" },
      "size": { "type": "string" },
      "quality": { "type": "string", "enum": ["low", "medium", "high", "auto"] },
      "output_format": { "type": "string", "enum": ["png", "jpeg", "webp"] },
      "output_compression": { "type": "integer", "minimum": 0, "maximum": 100 },
      "background": { "type": "string", "enum": ["auto", "opaque", "transparent"] },
      "moderation": { "type": "string", "enum": ["auto", "low"] },
      "count": { "type": "integer", "minimum": 1, "maximum": 4 },
      "reference_asset_ids": { "type": "array", "items": { "type": "string" } },
      "mask_asset_id": { "type": "string" }
    },
    "required": ["prompt"]
  }
}
```

行为：

1. Vercel AI Gateway 下，`openai/gpt-image-*`、DALL-E、Imagen、Flux 和 Grok image 等 image-only 模型使用 OpenAI-compatible `/images/generations` 文生图，模型使用 `agent.avcs_agent.image_model`。
2. Vercel AI Gateway 下，Google Gemini image 等多模态图片输出模型按 Vercel 文档通过 OpenAI-compatible `/chat/completions`、`modalities: ["image"]` 生成图片；存在 `reference_asset_ids` 或 `mask_asset_id` 时，Phoenix 后端解析这些 asset、读取当前项目内图片文件，并用 data URL `image_url` 把图片作为视觉参考或 mask edit 输入。
3. 非 Vercel OpenAI-compatible base URL 可通过 `/images/edits` multipart `image[]` / `mask` 发送参考图和 mask。
4. 图片响应使用 base64，后端解码并写入当前项目 `output/`。
5. 写入后复用现有 hash 去重、asset、asset link、chat item、board item 和 WebSocket 更新流程。
6. `size`、`quality`、`output_format`、`output_compression`、`background`、`moderation` 透传给图片接口；`aspect_ratio` 在未显式传 `size` 时映射为常用尺寸。
7. `mask_asset_id` 必须是当前项目内 PNG asset，并要求同时提供至少一张参考图；mask 必须包含 alpha 通道，可读取尺寸时，mask 尺寸必须与第一张参考图一致。
8. tool result 只返回 asset id、相对路径、尺寸、hash、MIME 类型、参考图数量、mask asset id、请求摘要和短状态，不返回 API key、远端原始响应、参考图二进制或大段二进制。
9. `gpt-image-2` 不支持 `background: "transparent"`，后端前置返回 unsupported；正式 variation 和 streaming partial images 暂不实现。

## 6.1 pi-agent 风格受控工具

AvcsAgent 工具名尽量与 pi-agent core 对齐，但这些只是模型可见的 Avcs 受控工具名：

1. `read`：参数 `path`、`offset`、`limit`。读取当前项目允许范围内 UTF-8 文本文件，拒绝 `.avcs/`、SQLite、secret-like 文件、项目外路径、symlink escape、二进制和过大文件。返回 `content`、`path`、`relative_path`、`size`、`truncated`。
2. `ls`：参数 `path`、`recursive`、`limit`。默认非递归，不进入 `.avcs/`，不跟随 symlink。返回 `entries`：`name`、`relative_path`、`type`、`size`、`mtime`。
3. `find`：参数 `path`、`pattern`、`limit`。按文件名或 glob 查找，不扫描 `.avcs/`，不跟随项目外 symlink。
4. `grep`：参数 `path`、`pattern`、`glob`、`case_sensitive`、`limit`、`context_lines`。使用 Elixir 内部搜索，不拼 shell，带文件大小、结果数和超时保护。
5. `write`：参数 `path`、`content`、`encoding`、`if_exists`。默认只允许写 `work/` 和 `output/`，默认 `if_exists=error`，写图片时复用 Avcs asset 入库逻辑。默认不在 active tools 中。
6. `edit`：参数 `path`、`old_text`、`new_text`、`occurrence` / `all`、`expected_sha256`。第一阶段只允许 `work/` 下文本文件，`old_text` 必须精确匹配。默认不在 active tools 中。
7. `bash`：不是 shell，不接受 `/bin/sh -c`、管道、重定向或任意命令字符串；只运行 APOD / Steam data provider allowlist。trace 记录 `command_kind`、provider、参数摘要、exit status、duration 和限长脱敏 stdout/stderr 摘要。

所有工具都必须做参数规范化、权限检查、trace、错误 envelope、可审计事件和用户可见错误提示。即使 `active_tools` 显式包含某工具，也不能绕过 Avcs 权限检查。未启用或不存在的工具返回标准 tool result：`status=failed`、`error.code=tool_not_allowed` 或 `invalid_tool_name`，并记录 `preToolUse` failed trace。

## 7. 数据与事件

AvcsAgent 与 Codex Agent 都使用 provider-neutral 字段：

1. `threads.agent_harness`
2. `threads.remote_thread_id`
3. `turns.agent_harness`
4. `turns.remote_turn_id`
5. `turns.remote_model`
6. `items.remote_item_id`
7. `items.tool_name`
8. `trace_events.agent_harness`
9. `trace_events.provider`
10. `trace_events.model`

WebSocket payload 不因 harness 改变。前端继续消费 `assistant:delta`、`item:created`、`tool:updated`、`asset:created`、`board:item:created` 和 `agent:run_completed` 等 Avcs 业务事件。`tool:updated.status` 使用 `started`、`updated`、`completed` 或 `failed` 表达工具生命周期。AvcsAgent 额外推送 `agent:state_snapshot`，用于表达 `phase`、`is_streaming`、current assistant item、pending tool calls、error、active tool、pending steer 和 queued turn input。

AvcsAgent 记录 `model`、reasoning effort、approval policy、sandbox mode 等运行配置；Codex-only 配置在 AvcsAgent 下标记为 `not_applicable`，不作为可绕过限制的开关。active tools 可以按 turn/runtime opts 动态收窄或显式开启 `write` / `edit`，但不能通过配置绕过工具内部权限检查，不能开启 MCP、浏览器、任意 shell、任意 FS、subagent 或多 agent workflow。

AvcsAgent 调用 Vercel AI Gateway / OpenAI-compatible API 时记录 `trace_events.scope = "vercel_api"`。事件只保存 safe summary，例如 endpoint、method、model、stream、attempt、duration、HTTP status、usage、图片数量和限长错误摘要；不得保存 API key、Authorization header、完整 prompt、完整 response body、文件字节、data URL 或 base64 图片内容。`/web/tracing/` 需要像 `codex_rpc` 一样提供 `vercel_api` 快捷筛选。

## 8. 错误处理

需要覆盖：

1. Gateway API key 未配置。
2. `/models` 或连接测试失败。
3. `/chat/completions` 请求失败。
4. SSE 解析失败或远端连接中断。
5. tool call JSON 参数无效。
6. `image_gen` 请求失败、base64 解码失败、图片格式无法识别或输出写入失败。
7. asset / board item 入库失败。
8. Stop 中断。

错误应写入当前 turn/item，并通过 WebSocket 推送给前端；用户主动 Stop 属于 `interrupted`，不按普通失败渲染。

## 9. 验收标准

1. `/web/settings` 可切换 `auto | codex | avcs_agent`。
2. `auto` 优先 Codex；Codex 不可用且 Gateway key 已配置时使用 AvcsAgent。
3. AvcsAgent 可通过 `deepseek/deepseek-v4-pro` 产生流式 assistant 文本。
4. AvcsAgent 可通过后端 `image_gen` 调用 `openai/gpt-image-2`。
5. 生成图片进入当前项目 `output/`，并创建 asset、chat item 和 board item。
6. 长 thread 触发 token budget compaction 后仍能继续。
7. running 中追加输入进入当前 active turn 的 pending steer 队列，并在安全点作为 turn continuation 继续。
8. Gateway key 不出现在 trace raw、turn/item payload、WebSocket payload、日志或文档示例中。
