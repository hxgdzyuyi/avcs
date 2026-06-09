# Avcs 项目指南

## 产品定位

Avcs 是 local-first 的 AI Visual Content Studio。MVP 是 Phoenix 承载的本地 Web 应用，用本地项目文件夹保存素材、输出和项目 SQLite，通过后端 Agent Harness 调用 Agent 能力。Harness 可选择 Codex Agent 或 AvcsAgent。

需求细节以 `docs/prds/overview.md` 和 `docs/prds/features/` 下的功能 PRD 为准；实现前如果发现本文与 PRD 冲突，优先更新本文或 PRD，避免让两个约定同时存在。

`docs/prds/features/{domain}/` 下 PRD 文件名前缀只针对上级 domain 目录排序，不按 `docs/prds/` 或 `docs/prds/features/` 全局递增。

## 技术栈

- 后端：Elixir / Phoenix
- 数据库：SQLite
  - 全局库：`~/.avcs/avcs.sqlite3`
  - 项目库：`<project>/.avcs/project.sqlite3`
- 前端：React + Vite
- 前端语言：纯 JavaScript，禁止 TypeScript
- 前端样式：纯 Sass/SCSS，禁止 Tailwind、CSS-in-JS、Less 和组件库主题系统
- 聊天输入：CodeMirror
- Agent：`auto | codex | avcs_agent` 双 harness；Codex 使用 `codex app-server` 的 `stdio://` JSONL，AvcsAgent 由 Phoenix 通过 Vercel AI Gateway OpenAI-compatible API 调用
- 画板：普通 HTML DOM 元素自由布局，不使用 Canvas/WebGL/SVG 作为主渲染层

## 项目结构

后端建议按以下边界组织：

```text
lib/avcs/
  projects/     # 项目打开、初始化、全局索引和项目元信息
  threads/      # thread 列表、创建、选择和归档
  turns/        # turn 与 item 持久化
  assets/       # 图片 asset、hash 去重、导入、扫描、预览
  board/        # 画板对象位置、尺寸、层级
  agent/        # Agent Harness、Codex app-server 协议封装、AvcsAgent client 和工具

lib/avcs_web/
  controllers/  # Phoenix HTTP API
  channels/     # WebSocket / Channel 事件
  plugs/
  router.ex
  endpoint.ex
```

前端建议目录：

```text
web/
  package.json
  vite.config.js
  index.html
  src/
    main.jsx
    App.jsx
    socket/
    components/
    features/
      projects/
      threads/
      chat/
      board/
    styles/
      main.scss
      _tokens.scss
      _layout.scss
      _components.scss
```

React 组件使用 `.jsx`，普通模块使用 `.js`。不要添加 `.ts`、`.tsx`、`tsconfig.json` 或 TypeScript 专用构建配置。

## 开发运行约定

- 开发期间不要主动运行 `npm run build`、`vite build` 或其它前端生产构建命令，除非用户明确要求验证生产构建或发布产物。
- 日常前端调试使用 Vite dev server，例如在 `web/` 下运行 `npm run dev`，并通过 Phoenix/Vite 的开发代理联调。
- `web/vite.config.js` 的生产构建输出目录是 `priv/static/assets/web`；执行 build 会生成 `priv/static/assets/web/assets/`、`priv/static/assets/web/.vite/` 等静态产物目录。

## 前端样式约定

- 样式统一写在 Sass/SCSS 中，由 `styles/main.scss` 汇总入口。
- 组件通过稳定的 `className` 使用 Sass 类名。
- 设计 token、布局变量和组件基础样式优先放在 `styles/` 下的共享 partial 中。
- 画板对象的 `x`、`y`、显示宽高、层级等运行时数值可以由 React 写入 inline style 或 CSS custom properties。
- 颜色、边框、控制点、排版、间距、hover/selected/error 等静态视觉规则仍由 Sass 维护。

## 本地文件与项目目录

前端不直接读写本地文件系统，也不依赖 Chromium File System Access API。所有文件操作走 Phoenix API。

项目目录结构：

```text
<project>/
  .avcs/
    project.sqlite3
    cache/
      thumbnails/
      temp/
  work/
  output/
```

- `work/`：导入图片、聊天区上传图片、用户手动放入的参考素材和待加工素材。
- `output/`：Agent 生成图片、加工结果和导出结果。
- 导入、上传和扫描图片时按 hash 去重。
- 同一项目内相同 hash 的图片不要重复创建资产文件；必要时只新增关联记录。

## 通信边界

- React 与 Elixir 的应用状态同步主要通过 WebSocket / Channel。
- 本地文件夹打开、图片导入、聊天区上传、图片扫描、预览、打开所在文件夹、复制路径等文件操作通过 Phoenix HTTP API。
- React 不直接调用 Codex app-server、Vercel AI Gateway、OpenAI-compatible API，不直接读写任何 SQLite，不直接拼接本地文件路径读取图片。
- HTTP 除文件 API 外，还用于前端入口、静态资源和图片预览。

## Phoenix HTTP API 约定

新增 JSON API 时，默认使用统一响应信封，字段使用 `snake_case`。

成功响应：

```json
{ "success": true, "data": {} }
```

失败响应：

```json
{ "success": false, "data": null, "error": { "code": "...", "message": "...", "details": "..." } }
```

列表响应的 `data` 使用 `{ "items": [...] }`。单对象响应的 `data` 直接返回对象，不额外包 `{ item: ... }`。

## WebSocket 事件约定

事件命名保持直观、面向业务，例如：

- `project:current`
- `threads:list`
- `thread:create`
- `thread:select`
- `thread:items:list`
- `message:send`
- `assets:list`
- `assets:reference`
- `assets:select`
- `board:items:list`
- `board:item:move`
- `board:item:resize`

服务端推送事件用于同步状态变化，例如 `asset:created`、`assets:updated`、`board:item:created`、`board:item:updated`、`agent:run_started`、`agent:run_completed`、`error`。

## Agent Harness

Agent 调用通过 `Avcs.Agent.HarnessRuntime` 统一选择实际 harness，Runner 不直接调用具体 client。

全局设置：

```text
agent.harness = codex
agent.avcs_agent.base_url = https://ai-gateway.vercel.sh/v1
agent.avcs_agent.text_model = deepseek/deepseek-v4-pro
agent.avcs_agent.image_model = openai/gpt-image-2
agent.avcs_agent.max_tool_steps = 3
agent.avcs_agent.compact_threshold = 0.75
```

- 默认使用 `codex`。用户可切换到 `auto`，此时优先 Codex；Codex 不可用且 AvcsAgent 已配置时使用 AvcsAgent。
- `/web/settings` 可以全局切换 `auto | codex | avcs_agent`。
- Vercel AI Gateway API key 只能通过 settings / secrets 读取，不硬编码、不打印、不写入文档、fixture、项目 SQLite、trace raw、日志或 WebSocket payload。
- thread、turn、item 和 trace 中远端 id 统一使用 `remote_*` 字段，并记录实际 `agent_harness`。

## Codex Agent / Codex app-server

Codex Agent 调用通过 `codex app-server` 封装。Codex Harness 使用 Codex app-server 的官方协议，不在 Avcs 内部复刻 Codex 工具协议。

实现要点：

1. 默认启动 `codex app-server`，使用 `stdio://` JSONL。
2. 连接建立后先发送 `initialize`，随后发送 `initialized`。
3. 使用 `thread/start` 或 `thread/resume` 管理 Codex 会话。
4. 用户发送消息时使用 `turn/start`，传入文本、聊天输入区当前引用的图片路径、当前项目 `cwd` 和必要设置。
5. 持续解析 `thread/*`、`turn/*`、`item/*`、工具进度和错误通知，并写入 Avcs 的 turn/item/asset/board 记录。
6. Codex app-server JSON Schema 快照提交在 `priv/codex_app_server/schemas/`，生成命令是 `codex app-server generate-json-schema --out priv/codex_app_server/schemas`。
7. `priv/codex_app_server/schema_manifest.json` 记录生成时的 Codex CLI 版本、命令、schema draft 和生成时间。
8. dev/test 运行时可以校验关键 request/response/notification，失败记录 warning 后继续兼容解析；prod 默认不因 schema 校验失败中断流程。
9. Codex app-server 是实验性接口，升级 Codex CLI 后必须重新生成 schema、检查 diff，并更新事件映射测试。
10. Codex Agent 的图片生成使用 Codex built-in `image_gen`；该 built-in 工具不属于 AvcsAgent。

## AvcsAgent

AvcsAgent 是用户没有 Codex 时的基础 harness。Phoenix 后端通过 Vercel AI Gateway 调用文本模型和图片模型，不让 React 直接调用远端模型服务。

实现要点：

1. 使用 OpenAI-compatible `/chat/completions` SSE streaming，把文本增量映射为 `assistant:delta`。
2. loop 为 `build_context -> call_model -> stream_delta -> handle_tool_calls -> append_tool_results -> maybe_compact -> finish_or_repeat`。
3. 基础版默认 active tools 为 `image_gen`、`read`、`ls`、`find`、`grep`、`bash`；`write`、`edit` 仅显式开启。所有工具都由 Avcs-native Elixir/Phoenix 后端受控白名单实现；不提供 MCP、浏览器、任意 shell、任意文件系统、subagent 或多 agent 工作流。Avcs 后端 `image_gen` tool 支持文生图、参考图、PNG mask edit，以及 `size`、`quality`、`output_format`、`output_compression`、`background`、`moderation` 等常用 OpenAI Image API 选项。
4. `image_gen` 调用 `agent.avcs_agent.image_model`，无参考图和 mask 时走 Vercel AI Gateway OpenAI-compatible `/images/generations`。有参考图或 mask 时，默认 Vercel AI Gateway 走 `/chat/completions`，使用 `modalities: ["image"]` 和 data URL `image_url` 传入项目图片；非 Vercel OpenAI-compatible base URL 可走 `/images/edits` multipart `image[]` / `mask`。mask 必须是当前项目内带 alpha 通道的 PNG，并与第一张参考图尺寸一致。base64 解码后写入当前项目 `output/`，再走现有 hash 去重、asset、chat item 和 board item 入库流程。`gpt-image-2` 不支持 transparent background；正式 variation 和流式 partial images 暂不实现。
5. running 中 steer 基础版不支持，返回 `steer_unsupported` 并保留草稿；Stop 中断当前 HTTP stream / Task 后把 turn 收敛为 `interrupted`。
6. 超过 `agent.avcs_agent.compact_threshold` 时做简单上下文压缩；SQLite 历史不删除。

## 画板约定

画板类似轻量设计工具工作区，但 MVP 只做 DOM 元素级组织：

- 白色自由工作区中展示图片对象。
- 图片对象、选中边框、控制点、名称和尺寸标注都使用 DOM 元素。
- 选中图片对象时展示蓝色选中框、边角控制点、图片名称和显示尺寸。
- 支持移动和缩放图片对象，保存位置、显示宽高和层级到项目 SQLite。
- 点击 Output 画板图片只选中对象；选中后通过 `board-layout-toolbar` 的“编辑”按钮打开全屏图片预览，引用通过 Reference 操作或预览 dialog 底部发送完成。
- 不实现 Canvas/WebGL/SVG 主渲染层，不做专业图层树、裁切、旋转、蒙版、文本对象、对齐吸附、小地图或复杂快捷键。

## 常见错误

- 不要把项目业务数据写入 `~/.avcs/avcs.sqlite3`；全局 SQLite 只保存软件级元数据和项目关联信息。
- 不要让 React 绕过 Phoenix 直接访问 SQLite、Codex app-server、Vercel AI Gateway、OpenAI-compatible API 或本地文件。
- 不要在 React 项目中引入 TypeScript、Tailwind 或 CSS-in-JS。
- 不要把生成图片保存到 `work/`；Agent 生成和加工结果应进入 `output/`。
- 不要混淆图片工具：Codex Agent 用 Codex built-in `image_gen`；AvcsAgent 用 Avcs 后端 `image_gen` tool。
- 不要用固定网格替代画板自由布局；画板图片应作为可移动、可缩放的 DOM 对象存在。
