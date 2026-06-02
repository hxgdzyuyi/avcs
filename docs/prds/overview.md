# Avcs PRD 总览

状态：Draft  
日期：2026-06-01

## 1. 文档结构

Avcs PRD 按总览和功能文档拆分。`docs/prds/features/{domain}/` 下的文件名前缀只在对应 domain 目录内排序，不按 `docs/prds/` 全局递增。

| Domain | 域内编号 | 功能 | 文档 |
| --- | --- | --- | --- |
| projects | 001 | 项目打开与初始化 | `features/projects/001-项目打开与初始化.md` |
| threads | 001 | Thread 管理 | `features/threads/001-Thread管理.md` |
| turns | 001 | 聊天输入与消息展示 | `features/turns/001-聊天输入与消息展示.md` |
| turns | 002 | 图片引用与上传 | `features/turns/002-图片引用与上传.md` |
| assets | 001 | 资产导入扫描与去重 | `features/assets/001-资产导入扫描与去重.md` |
| agent | 001 | Codex Agent 调用 | `features/agent/001-Codex-Agent调用.md` |
| agent | 002 | 交互审批 | `features/agent/002-交互审批.md` |
| assets | 002 | 图片生成与结果入库 | `features/assets/002-图片生成与结果入库.md` |
| board | 001 | 画板自由布局 | `features/board/001-画板自由布局.md` |
| board | 002 | 画板对象选择移动与缩放 | `features/board/002-画板对象选择移动与缩放.md` |
| web | 001 | Phoenix 本地文件 API | `features/web/001-Phoenix本地文件API.md` |
| web | 002 | WebSocket 状态同步 | `features/web/002-WebSocket状态同步.md` |
| web | 003 | 桌面 App 打包 | `features/web/003-桌面App打包.md` |
| ui | 001 | 三栏工作台 UI | `features/ui/001-三栏工作台UI.md` |
| ui | 002 | Codex 左侧栏对齐 | `features/ui/002-Codex左侧栏对齐.md` |
| ui | 003 | Codex 聊天区对齐 | `features/ui/003-Codex聊天区对齐.md` |

## 2. 产品定位

Avcs 是 local-first 的 AI Visual Content Studio。MVP 形态是由 Phoenix 提供统一入口的本地 Web 应用，用本地项目文件夹保存素材、输出和项目 SQLite，通过 Codex app-server 调用 Agent 能力。该本地 Web 应用可以被 Tauri 打包为 macOS Apple Silicon 桌面 app；Tauri 只负责启动本地 Phoenix release 和承载 WebView，不改变 Avcs 的业务边界。

Avcs 面向已经拥有 Codex 订阅、希望充分利用现有 AI 能力的个人创作者，把「和 AI 对话」与「查看本地项目素材」放在同一个工作界面里。

MVP 不把 Avcs 定义成重型设计软件，也不预设复杂品牌系统、图层编辑器或资产管理平台。核心价值是：用户通过 Phoenix 本地 API 打开一个本地项目文件夹后，在同一个项目里管理 thread、turn、item、asset 和画板对象，并围绕图片生成与继续迭代形成闭环。

## 3. 核心词汇表

| 词汇 | 定义 |
| --- | --- |
| 项目文件夹 | 用户选择并授权给 Avcs 使用的本地目录，既是素材与生成结果的文件归属位置，也是项目 SQLite、`work/` 和 `output/` 的容器。 |
| 全局 SQLite | 位于 `~/.avcs/avcs.sqlite3` 的全局项目索引库，只保存项目 ID、项目名称、项目文件夹路径、项目 SQLite 路径和最近打开时间等关联信息。 |
| 项目 SQLite | 位于项目文件夹内的 SQLite，例如 `<project>/.avcs/project.sqlite3`，保存该项目自己的结构化业务数据。 |
| Thread | 项目中的一次持续对话，用于承载一个创作方向或任务上下文。一个项目可以包含多个 thread。 |
| Turn | Thread 中的一次完整交互回合，包含一次用户输入以及由此产生的 Agent 输出、工具调用和结果。 |
| Item | Turn 内的细粒度内容单元，例如用户消息、Agent 文本、工具调用、工具结果、图片资产或错误信息。 |
| Asset | 项目中的素材文件。MVP 主要指图片，包括生成图片、导入图片、用户手动放入项目文件夹的图片和 Agent 引用的图片。 |
| 画板 | 右侧视觉工作区，用白色自由工作区承载项目图片对象，支持图片摆放、预览、选中、引用和轻量组织。 |
| 画板对象 | 画板中一个可视图片实例，引用某个 Asset，并记录画板位置、显示宽高和层级等展示信息。 |
| Agent | Avcs 通过 Codex app-server 调用的 AI 执行单元，负责理解用户自然语言、生成文本、调用工具并返回图片生成或加工结果。 |
| Codex app-server | Avcs 后端通过 `codex app-server` 调用的 Codex 能力入口。MVP 默认使用 `stdio://` JSONL 传输和 Codex app-server 官方 JSON-RPC 协议。 |
| `image_gen` | Codex built-in 图片生成工具，MVP 中图片生成必须真实接入，并优先通过它完成。 |
| CodeMirror | 聊天区输入编辑器，用于承载多行自然语言 prompt、粘贴内容和基础快捷键；MVP 不把它扩展成完整代码 IDE。 |

## 4. 产品目标

1. 让用户以本地文件夹为项目单位管理视觉创作上下文。
2. 提供低干扰的三栏工作台，同时展示项目、对话和视觉结果。
3. 复用 Codex app-server 的 Agent 能力，避免在 Avcs 内部重新实现复杂 Agent 编排。
4. 优先做好 Phoenix 文件 API、本地文件、thread、turn、item、图片资产之间的映射关系。
5. 真实接入 Codex built-in `image_gen` 的图片生成，并把生成结果和项目数据沉淀到项目文件夹。
6. 确保全局 SQLite 只保存项目关联信息，项目业务数据全部归属到项目 SQLite。

## 5. 非目标

MVP 阶段明确不做以下能力：

1. 不做多人协作、云同步、团队权限和在线项目空间。
2. 不做完整的专业设计编辑器，例如复杂图层树、矢量编辑、钢笔工具、文本路径、布尔运算等。
3. 不做长期记忆系统，不跨项目记住用户偏好。
4. 不做复杂 Agent 预设和多 Agent 工作流，当前 Agent 本质上是对 Codex 的调用封装。
5. 不做主动追问式需求收集。信息不足时，Agent 应基于用户现有输入和项目上下文给出可执行结果。
6. 不承诺视频广告、包装工程文件、印刷级交付等高复杂度生产能力。
7. 不依赖浏览器私有或特定 Chromium 的本地文件系统能力；本地文件访问由 Phoenix 后端 API 承担。
8. MVP 不实现独立的最近项目启动页；左栏可以展示全局项目索引。MVP 也不自动修复已移动项目文件夹在全局 SQLite 中的路径映射。

## 6. 核心场景

### 6.1 新建或打开项目

用户打开 Avcs 后，可以通过 Phoenix 提供的本地 API 新建空白项目或打开一个本地文件夹作为项目。新建空白项目时，用户输入项目名，后端自动在 `~/Documents/Avcs` 下创建项目目录；如果同名目录已存在，自动递增为 `<项目名> 2`、`<项目名> 3`。打开现有文件夹时，用户输入本地绝对路径。Avcs 将项目名称、项目对应的文件夹路径和最近打开时间写入 `~/.avcs/avcs.sqlite3`，并在项目文件夹内初始化项目 SQLite、`work/` 和 `output/`。

### 6.2 与 Agent 对话生成图片

用户在当前 thread 中输入自然语言，例如「给一家咖啡店生成三张简洁风格的 logo 概念图」。Avcs 将请求交给 Codex app-server。Agent 生成图片后，Avcs 将图片保存到项目 `output/` 目录，并在右侧画板展示。

### 6.3 基于现有图片继续迭代

用户可以从画板中点击一张或多张图片，将其加入聊天输入区的图片引用，再继续对 Agent 发送指令。用户也可以直接在聊天区上传图片；上传图片先写入当前项目 `work/` 目录，计算 hash 去重并创建或复用 asset 记录，然后自动作为当前聊天输入的图片引用。

### 6.4 管理 thread 与资产

一个项目下可以有多个 thread。用户可以切换 thread 查看不同创作方向。画板以自由工作区形式展示当前项目中的图片对象，并能够标记图片来自当前 thread、当前 turn 或当前 item。

## 7. 信息架构

### 7.1 Project

Project 对应一个本地文件夹。项目文件夹至少包含：

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

`~/.avcs/avcs.sqlite3` 只保存全局项目关联，例如项目 ID、项目名称、项目文件夹路径、项目 SQLite 路径、最近打开时间。

空白项目默认创建在：

```text
~/Documents/Avcs/<project-name>
```

同名目录自动递增，例如 `~/Documents/Avcs/<project-name> 2`。

### 7.2 Thread

Thread 对应项目中的一次持续对话。一个项目可以有多个 thread，thread 之间不共享记忆，但可以引用同一个项目文件夹中的资产。

### 7.3 Turn 与 Item

Turn 表示一次用户输入和 Agent 输出的完整回合。Item 表示回合中的细粒度内容，基础类型包括：

1. `user_message`
2. `assistant_message`
3. `tool_call`
4. `tool_result`
5. `image_asset`
6. `error`

### 7.4 Asset

Asset 表示项目中的素材文件，MVP 主要是图片。导入图片和扫描项目文件夹时，Avcs 按文件 hash 去重。同一项目内已经存在相同 hash 的图片时，不重复创建资产文件；必要时只新增 asset 与 thread、turn、item 或来源之间的关联记录。

### 7.5 画板对象

画板对象表示一个 asset 在右侧画板中的可视摆放实例。MVP 中一个 asset 默认对应一个画板对象，后续可以扩展为同一 asset 多实例摆放。

## 8. 技术边界

1. 后端：Elixir / Phoenix。
2. 数据库：SQLite。
3. 前端：React + Vite。
4. 前端语言：纯 JavaScript；React 组件使用 `.jsx`，普通模块使用 `.js`。
5. 前端样式：纯 Sass/SCSS；禁止 Tailwind、CSS-in-JS、Less 和组件库主题系统。
6. 聊天输入：CodeMirror。
7. 应用形态：Phoenix 承载的本地 Web 应用；MVP 支持用 Tauri 打包为 macOS Apple Silicon 桌面壳，但业务能力仍通过 Phoenix 提供。
8. 本地文件访问：前端不依赖 Chromium File System Access API，所有文件操作通过 Phoenix API 进入后端。
9. Agent：Codex app-server，默认 `stdio://` JSONL 通信，后端基于版本化 JSON Schema 快照校验关键协议消息。
10. 图片生成：真实接入 Codex built-in `image_gen`。
11. 画板：普通 HTML DOM 元素自由布局，不使用 Canvas/WebGL/SVG 作为主渲染层。
12. 应用通信：React 与 Elixir 的状态同步主要使用 WebSocket；React 与 Elixir 的本地文件操作使用 Phoenix HTTP API；Elixir 与 Codex app-server 使用 stdio。

## 9. 代码结构约定

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

## 10. 数据存储

Avcs 使用两层 SQLite：

1. 全局 SQLite：`~/.avcs/avcs.sqlite3`，只保存项目关联信息。
2. 项目 SQLite：每个项目文件夹内一个 SQLite，保存该项目自己的 thread、turn、item、asset 和项目设置。

推荐目录：

```text
~/.avcs/
  avcs.sqlite3
  cache/
  logs/

~/Documents/Avcs/
  <blank-project>/

<project>/
  .avcs/
    project.sqlite3
    cache/
      thumbnails/
      temp/
  work/
  output/
```

`~/.avcs/avcs.sqlite3` 是全局项目索引库，MVP 只负责项目关联，建议表结构：

1. `projects`：项目 ID、项目名称、项目对应的文件夹路径、项目 SQLite 路径、归档时间、创建时间、更新时间、最近打开时间。

项目 SQLite 是项目数据的主库，建议表结构：

1. `project_meta`：项目自身元信息，例如项目 ID、schema 版本、创建时间、更新时间。
2. `threads`：项目下的对话。
3. `turns`：对话回合。
4. `items`：回合内容项。
5. `assets`：图片资产索引，保存文件路径、来源、hash、尺寸、MIME 类型等元数据；同一项目内 hash 应唯一，用于导入和扫描去重。
6. `asset_links`：资产与 thread/turn/item 的关联。
7. `board_items`：画板对象，保存 asset 在画板中的位置、显示宽高、层级和来源标记。
8. `settings`：项目级设置。

`~/.avcs/avcs.sqlite3` 中的 `projects.folder_path` 是全局项目列表与本地文件夹的映射来源；项目内的业务数据以 `<project>/.avcs/project.sqlite3` 为准。项目删除只删除全局 SQLite 中的引用，不删除本地项目文件夹。MVP 不自动修复已移动项目文件夹的映射。

## 11. 通信边界

运行时通信分为两段：

```text
React 前端  <--WebSocket/HTTP API-->  Elixir/Phoenix  <--stdio JSONL-->  Codex app-server
```

职责划分：

1. React 不直接调用 Codex app-server，也不直接读写全局 SQLite、项目 SQLite 或本地文件系统。
2. React 与 Elixir 之间的项目状态、thread 切换、聊天消息、Agent 流式输出、工具状态、资产刷新等应用事件主要通过 WebSocket 传递。
3. 本地文件夹打开、资产导入、聊天区图片上传、资产扫描、图片读取、打开所在文件夹、复制路径等文件系统相关操作通过 Phoenix HTTP API 进入后端。
4. Elixir 负责维护 WebSocket 连接、校验事件、写入全局 SQLite 和项目 SQLite、管理项目文件夹、保存图片资产，并把状态变更推送给 React。
5. Codex app-server 的输出由 Elixir 解析为 turn/item/asset 事件，再通过 WebSocket 推送给 React。

## 12. 开发入口

Phoenix 作为统一访问入口，开发端口使用 `9500`。Vite dev server 独立运行，开发端口使用 `9501`。

```bash
# 一键启动两个进程
./bin/tmux

# 终端 1：启动 Phoenix
PORT=9500 PHX_PORT=9500 VITE_PORT=9501 mix phx.server

# 终端 2：启动 Vite
cd web && PHX_PORT=9500 VITE_PORT=9501 npm run dev -- --host 127.0.0.1 --port 9501
```

用户访问：

```text
http://localhost:9500/web
```

## 13. MVP 总体验收

1. 用户可以通过 Phoenix 本地 API 打开一个本地文件夹作为项目，并在再次打开同一文件夹后恢复数据。
2. 一个项目可以创建多个 thread，并能在左栏切换。
3. 用户可以在中栏发送消息，消息被保存到当前 thread。
4. React 不依赖 Chromium File System Access API；所有本地文件操作都通过 Phoenix API 完成。
5. React 与 Elixir 的应用状态通信通过 WebSocket 完成。
6. 后端可以通过 `codex app-server` 的 stdio JSONL 协议调用 Codex app-server，使用版本化 JSON Schema 快照校验关键协议消息，并把 Agent 输出写回 turn/item。
7. Agent 通过真实 Codex built-in `image_gen` 生成图片后，图片能保存到当前项目目录。
8. 右侧画板可以在白色自由工作区中自动展示项目图片对象。
9. 用户可以选中画板图片对象，并看到选中框、控制点、图片名称和显示尺寸。
10. 用户可以移动和缩放画板图片对象，位置和显示尺寸能保存并在再次打开项目后恢复。
11. 用户点击画板图片后，该图片会加入聊天输入区作为图片引用。
12. 用户可以在聊天区上传图片，上传成功后图片保存到当前项目 `work/` 目录并加入聊天输入引用。
13. 带图片引用发送消息后，Agent 能收到对应图片路径或引用。
14. 导入、上传和扫描图片时，同一项目内相同 hash 的图片不会重复创建资产文件。
15. 左栏展示全局项目索引；MVP 不做独立最近项目启动页。项目路径失效时提示用户重新打开文件夹，不自动修复 SQLite 映射。
16. Elixir/Phoenix 与 Vite 在开发环境通过 `/web` 代理 Vite，生产环境服务构建产物。
17. 前端代码保持纯 JavaScript，React 组件使用 `.jsx`，不得引入 TypeScript、`.ts`、`.tsx` 或 `tsconfig.json`；样式保持纯 Sass/SCSS。
18. `~/.avcs/avcs.sqlite3` 只保存项目名称、项目文件夹、项目 SQLite 路径等项目关联信息。
19. 每个项目文件夹都有自己的项目 SQLite，用于保存 thread、turn、item、asset、画板对象和项目设置。

## 14. 后续迭代方向

1. 资产标签、收藏、评分和版本关系。
2. 更强的图片筛选和对比视图。
3. 可配置的图片生成提示词模板。
4. 简单品牌包：颜色、字体、关键词、禁用元素。
5. 批量生成和批量导出。
6. 更完整的文件夹监听与外部文件同步。
7. 可选的轻量编辑能力，例如裁切、尺寸调整、背景色、导出格式转换。
