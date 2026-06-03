# Avcs 项目指南

## 产品定位

Avcs 是 local-first 的 AI Visual Content Studio。MVP 是 Phoenix 承载的本地 Web 应用，用本地项目文件夹保存素材、输出和项目 SQLite，通过 Codex app-server 调用 Agent 能力。

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
- Agent：`codex app-server`，默认 `stdio://` JSONL 通信
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
  agent/        # Codex app-server 进程与协议封装

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
- React 不直接调用 Codex app-server，不直接读写任何 SQLite，不直接拼接本地文件路径读取图片。
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

## Codex app-server

Agent 调用通过 `codex app-server` 封装，不在 Avcs 内部实现独立大模型服务或自定义工具协议。

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
- 不要让 React 绕过 Phoenix 直接访问 SQLite、Codex app-server 或本地文件。
- 不要在 React 项目中引入 TypeScript、Tailwind 或 CSS-in-JS。
- 不要把生成图片保存到 `work/`；Agent 生成和加工结果应进入 `output/`。
- 不要用固定网格替代画板自由布局；画板图片应作为可移动、可缩放的 DOM 对象存在。
