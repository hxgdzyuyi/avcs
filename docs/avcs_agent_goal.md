## Goal

实现一个基础版双 harness：

1. `Codex Agent`：保留现有 `codex app-server`。
2. `AvcsAgent`：用户没有 Codex 时，通过 Vercel AI Gateway 调用项目自有 agent。
3. `/web/settings` 可全局切换：`auto | codex | avcs_agent`。
4. `auto` 优先 Codex；Codex 不可用且 AvcsAgent 已配置时使用 AvcsAgent。

默认配置：

```text
agent.harness = codex
agent.avcs_agent.base_url = https://ai-gateway.vercel.sh/v1
agent.avcs_agent.text_model = deepseek/deepseek-v4-pro
agent.avcs_agent.image_model = openai/gpt-image-2
agent.avcs_agent.max_tool_steps = 3
agent.avcs_agent.compact_threshold = 0.75
```

开发测试前提：`/web/settings` 已配置可测试的 Vercel AI Gateway API key。直接复用它，但只能通过 settings / secrets 读取；不要硬编码、打印、写入文档、fixtures、项目 SQLite、trace raw、日志或 WebSocket payload。

## Read First

先读：

```text
AGENTS.md
README.md
docs/prds/overview.md
docs/prds/features/agent/001-Codex-Agent调用.md
docs/prds/features/assets/002-图片生成与结果入库.md
docs/prds/features/turns/001-聊天输入与消息展示.md
docs/prds/features/web/002-WebSocket状态同步.md
lib/avcs/agent/harness.ex
lib/avcs/agent/harness_runtime.ex
lib/avcs/agent/harness/codex.ex
lib/avcs/agent/runner.ex
lib/avcs/site_settings.ex
lib/avcs/projects.ex
web/src/features/settings/SettingsPage.jsx
web/src/App.jsx
priv/agent/thread-runtime-instructions.md
priv/skills/avcs-imagegen-avcs-agent/SKILL.md
priv/skills/avcs-imagegen-codex/SKILL.md
```

机制学习只用于基础版设计：

1. Pi Agent：轻量 coding agent 配置和运行。
2. Codex：harness loop、tools、环境上下文、compaction。
3. OpenCode：agent 配置、工具权限、compaction 思路。
4. ShareAI Learn Claude Code：`s01` loop、`s02` tools、`s05` skills、`s06` compact。

## Scope

只做基础版：

1. 双 harness 配置切换。
2. AvcsAgent 最小 loop。
3. 最小 skills：图片生成 + 当前已有 data provider context。
4. 基于 token 预算的本地上下文压缩。
5. 自建 `image_gen` 图片工具，支持文生图、项目内参考图输入、PNG mask edit 和 OpenAI Image API 常用选项。
6. pi-agent 风格 Avcs 受控工具：默认开放 `read`、`ls`、`find`、`grep`、`bash`，`write`、`edit` 仅显式开启。
7. 图片结果入库到 `output/`、asset、chat item、board item。

明确不做：

1. subagent、多 agent、任务图、后台任务、worktree 隔离。
2. MCP、浏览器工具、subagent、多 agent workflow、任意 shell 或任意文件系统访问。pi-agent 风格工具名只作为能力基线和命名参考，必须由 Avcs-native Elixir/Phoenix 受控白名单实现。
3. Codex Guardian approval、repair thread 的 AvcsAgent 复刻；`thread/fork` / `thread/rollback` 只做 Avcs 本地 SQLite 当前路径语义，不复刻 Codex app-server 协议。
4. skill marketplace、skill installer、跨项目 skill registry。
5. AvcsAgent streaming partial images、正式 variation，以及默认 `gpt-image-2` 不支持的原生透明背景。
6. per-thread 复杂 harness 策略；基础版只记录实际使用的 harness、运行配置和受控工具白名单。

## Constraints

1. React 不直接调用 Vercel、OpenAI、Codex app-server、SQLite 或本地文件系统。
2. Phoenix 是文件、SQLite、agent、asset 入库边界。
3. 生成结果进入项目 `output/`；`work/` 只放上传、导入和待处理素材。
4. 前端保持 JavaScript + JSX；不要加 TypeScript。
5. 样式保持 Sass/SCSS；不要加 Tailwind、CSS-in-JS、Less 或组件库主题系统。
6. 远端 id 统一写 `remote_*` 字段，不保留 `codex_*` 字段。
7. 不主动运行 production build。

## Data And Harness

直接迁移到基础版统一字段，不写新旧字段兼容逻辑。全局 Ecto 数据库跑 migration；项目 SQLite 直接更新 schema version 和建表 / 迁移逻辑。

```text
threads.agent_harness
threads.remote_thread_id
turns.agent_harness
turns.remote_turn_id
turns.remote_model
items.remote_item_id
items.tool_name
trace_events.agent_harness
trace_events.provider
trace_events.model
```

要求：

1. Codex Agent 和 AvcsAgent 都写 `remote_*` 字段。
2. 迁移现有 `codex_thread_id`、`codex_turn_id`、`codex_item_id` 到对应 `remote_*` 字段。
3. 同步更新查询、trace、测试 fixture 和索引名称。
4. 不保留 `codex_*` 双写、fallback read 或兼容分支。
5. 实现后直接运行 migration 验证。

Harness 目标：

```text
Avcs.Agent.Harness.Codex
Avcs.Agent.Harness.AvcsAgent
Avcs.Agent.AvcsAgentClient
Avcs.Agent.Tools.ImageGen
Avcs.Agent.Tools.Read
Avcs.Agent.Tools.Ls
Avcs.Agent.Tools.Find
Avcs.Agent.Tools.Grep
Avcs.Agent.Tools.Bash
Avcs.Agent.Tools.Write
Avcs.Agent.Tools.Edit
```

## AvcsAgent Loop

实现最小 loop：

```text
build_context -> call_model -> stream_delta -> handle_tool_calls -> append_tool_results -> maybe_compact -> finish_or_repeat
```

要求：

1. messages 从本地有效 thread / turn / item 构建，并由 Elixir context transform 统一区分 system、user item、assistant item、tool call、tool result、reference asset、board context 和 data provider context。
2. 使用 `deepseek/deepseek-v4-pro`。
3. 支持 SSE streaming，映射到现有 `assistant:delta`。
4. `max_tool_steps = 3`。
5. Stop 取消当前 HTTP stream / Task，turn 收敛为 `interrupted`。
6. running 中追加输入按 `turn/steer` 语义处理为 pending steer；AvcsAgent 在模型响应或工具批次之间的安全点将其作为 turn continuation 注入当前 turn，Stop 仍按 `turn/interrupt` 收敛为 `interrupted`。

## Skills

最小 skills 机制：

1. 按需加载，不把全部 skill 塞进系统提示词。
2. 初期接图片生成 skill、data provider context 和受控 provider 执行闭环。
3. skill 输出作为结构化 context / tool result 注入下一次模型输入。
4. Codex built-in `image_gen` 只属于 Codex harness；AvcsAgent 使用服务端 `image_gen` tool。

Data provider 由模型调用 AvcsAgent `bash` 工具闭环执行。该 `bash` 不是 shell，只接受 `{"command_kind":"data_provider","provider":"..."}` 形式的 allowlist descriptor，由 Phoenix 后端运行 APOD / Steam 内置脚本，输出只能进入当前项目 `work/`，并入库为 provider asset。

## Context Compaction

AvcsAgent compaction：

1. 超过 `compact_threshold` 时触发。
2. 按估算 token 预算触发，基础版使用本地规则摘要，不依赖额外远端 summarizer。
3. 摘要保留：用户目标、未完成事项、关键 tool result、asset ids、输出路径、错误。
4. 大输出只保留摘要和引用。
5. 不删除 SQLite 历史。

引用图片由 Phoenix 后端读取当前项目内 asset 文件，并作为 OpenAI-compatible structured content item 传入模型；如果 gateway / 模型拒绝结构化图片输入，返回用户可见的 vision-capable model 错误提示，不退回项目路径文本。

## image_gen Tool

支持文生图、参考图输入、PNG mask edit 和常用图片参数：

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

1. 没有参考图和 mask 时调用 Vercel AI Gateway `/images/generations`，模型默认 `openai/gpt-image-2`。
2. 存在 `reference_asset_ids` 或 `mask_asset_id` 时解析当前项目 asset。默认 Vercel AI Gateway 下，`openai/gpt-image-*` 等 image-only 模型不走 `/chat/completions` 参考图路径；Google Gemini 等多模态图片模型通过 `/chat/completions`、`modalities: ["image"]` 和 data URL `image_url` 传入参考图/带 alpha 通道的 PNG mask；非 Vercel OpenAI-compatible base URL 可通过 `/images/edits` multipart `image[]` / `mask` 传入。
3. base64 解码后写入项目 `output/`。
4. 复用现有 hash 去重、asset、asset link、board item 和 WebSocket 更新。
5. `size`、`quality`、`output_format`、`output_compression`、`background`、`moderation` 透传给图片接口；`aspect_ratio` 可映射为常用 `size`。
6. tool result 只返回 asset id、相对路径、尺寸、hash、mime type、reference_count、mask_asset_id、request 摘要和短状态。
7. `gpt-image-2` 不支持原生透明背景，`background: "transparent"` 前置返回 unsupported；正式 variation 和 streaming partial images 留给后续计划。

## pi-agent 风格受控工具

AvcsAgent 对模型暴露的工具名尽量与 pi-agent core 对齐，但实现不迁入 pi-agent Node runtime、依赖、sidecar、tool executor、包结构或 JSONL SessionRepo。所有工具都通过 Avcs Elixir/Phoenix 后端执行。

默认 active tools：

```text
image_gen, read, ls, find, grep, bash
```

显式开启工具：

```text
write, edit
```

工具边界：

1. `read`：读取当前项目允许范围内 UTF-8 文本文件，拒绝 `.avcs/`、SQLite、secret-like 文件、项目外路径、symlink escape、二进制和过大文件。
2. `ls`：列当前项目目录，默认非递归，递归时不进入 `.avcs/`，不跟随 symlink。
3. `find`：按文件名或 glob 查找项目文件，不扫描 `.avcs/`，不跟随项目外 symlink。
4. `grep`：用 Elixir 内部搜索文本内容，不拼 shell，带文件大小、结果数和超时保护。
5. `write`：默认仅允许 `work/` 与 `output/`，默认 `if_exists=error`，写图片时复用 Avcs asset 入库逻辑。
6. `edit`：第一阶段只允许 `work/` 下文本文件，`old_text` 必须精确匹配，可校验 `expected_sha256`。
7. `bash`：不是任意 shell，只运行 APOD / Steam data provider allowlist；trace 只记录命令类型、provider、参数摘要、exit status、duration 和限长脱敏 stdout/stderr 摘要。

即使 `active_tools` 显式包含某工具，也必须经过路径、scope、secret、SQLite、symlink 和工具参数权限检查。未启用工具返回标准 tool result：`status=failed`、`error.code=tool_not_allowed`，并记录 `preToolUse` failed trace。

## Settings UI

`/web/settings` 增加：

1. Harness：`Auto`、`Codex Agent`、`AvcsAgent`。
2. AvcsAgent：base URL、API key 状态、连接测试、text model、image model。
3. Codex-only effort / approval / sandbox 在 AvcsAgent 下禁用或标为不适用。
4. 英文和中文 i18n。

## Docs

更新：

```text
AGENTS.md
README.md
docs/prds/overview.md
docs/prds/features/agent/001-Codex-Agent调用.md
docs/prds/features/agent/003-AvcsAgent调用.md
docs/prds/features/assets/002-图片生成与结果入库.md
docs/prds/features/turns/001-聊天输入与消息展示.md
docs/prds/features/web/002-WebSocket状态同步.md
priv/agent/thread-runtime-instructions.md
priv/skills/avcs-imagegen-avcs-agent/SKILL.md
priv/skills/avcs-imagegen-codex/SKILL.md
```

文档必须说明：Codex Agent 用 Codex built-in `image_gen`；AvcsAgent 用 Avcs 后端 `image_gen` tool。

## Verification

运行：

```bash
mix ecto.migrate
mix test test/avcs/agent_runner_test.exs
mix test test/avcs_web/channels/avcs_channel_test.exs
mix test
```

手工验收：

1. `/web/settings` 可切换 `auto | codex | avcs_agent`。
2. 使用已配置 Gateway key，AvcsAgent 可调用 `deepseek/deepseek-v4-pro`。
3. AvcsAgent 可通过 `image_gen` 调用 `openai/gpt-image-2`。
4. 图片进入 `output/`，并出现在 chat asset row 和 board。
5. 长 thread 触发 token budget compaction 后仍能继续。
6. 未使用 skill 不进入主 prompt。
7. Codex Agent 原路径不回退。
8. Gateway key 不泄漏。

## Done When

最终回复说明：

1. 修改文件。
2. 两种 harness 如何切换。
3. loop、skills、compaction 的基础实现。
4. `image_gen` 入库流程。
5. 测试结果。
6. 未完成项或风险。

## References

1. https://learn.shareai.run/zh/docs/s00-architecture-overview/
2. https://opencode.ai/docs/agents/
3. https://openai.com/index/unrolling-the-codex-agent-loop/
4. https://pi.dev/docs/latest
5. https://vercel.com/docs/ai-gateway/openai-compat
6. https://vercel.com/docs/ai-gateway/capabilities/image-generation/openai
7. https://vercel.com/ai-gateway/models/deepseek-v4-pro
8. https://vercel.com/ai-gateway/models/gpt-image-2
