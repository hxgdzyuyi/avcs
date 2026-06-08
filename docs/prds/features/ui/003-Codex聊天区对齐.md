# 014 Codex 聊天区对齐

状态：Draft  
关联 PRD：`docs/prds/features/turns/001-聊天输入与消息展示.md`、`docs/prds/features/turns/002-图片引用与上传.md`、`docs/prds/features/agent/001-Codex-Agent调用.md`、`docs/prds/features/ui/001-三栏工作台UI.md`

## 1. 目标

Avcs 聊天区对齐 Codex 的对话工作流，但业务重点聚焦视觉内容生成。它的核心职责是让用户在当前 thread 中发送任务、查看 turn 过程、理解 Agent 正在做什么，并把生成或引用的图片继续带入下一轮创作。

聊天区需要支持：

1. 展示当前 thread 的标题、运行状态和基础操作。
2. 以 turn 为节奏展示用户输入、Agent 输出、工具调用、图片结果和错误。
3. 将 Codex app-server 的 thread / turn / item 事件映射为 Avcs 可理解的聊天记录。
4. 支持流式 assistant 文本、工具运行状态和最终结果落库后的稳定渲染。
5. 支持图片引用、图片上传、生成结果定位到画板和从画板继续引用。
6. 在切换 thread、刷新页面或 Agent 运行中时保持清晰的状态归属。

## 2. 信息定位

聊天区是「当前 thread 的任务时间线 + 输入器」，不是文件浏览器、日志控制台或完整 IDE。

用户心智：

1. Thread 表示一个持续创作方向或任务上下文。
2. Turn 表示一次用户输入和 Agent 输出的完整回合。
3. Item 表示 turn 内的细粒度内容，例如用户消息、assistant 文本、工具调用、图片结果和错误。
4. 聊天区负责解释 Agent 过程和结果，画板负责承载图片的视觉比较与自由布局。
5. 文件路径、命令输出和工具详情只在需要理解结果或排查失败时展开，不默认挤占主消息流。

## 3. 框架布局

推荐宽度：

1. 桌面默认宽度 `456px`。
2. 最小宽度 `380px`。
3. 最大宽度 `520px`。
4. 消息列表独立滚动，顶部 thread bar 和底部 composer 固定在聊天区内部。

结构：

```text
┌────────────────────────────────────────┐
│ Thread bar                             │
│ 当前 thread 标题        状态  上传  +  │
├────────────────────────────────────────┤
│ Message timeline                       │
│                                        │
│ Turn                                   │
│   user message                         │
│   reasoning / plan / tool status       │
│   assistant message                    │
│   generated image asset rows           │
│                                        │
│ Turn                                   │
│   ...                                  │
├────────────────────────────────────────┤
│ Reference strip                        │
│ CodeMirror composer                    │
│ Add image                         Send │
└────────────────────────────────────────┘
```

## 4. 顶部 Thread Bar

顶部 thread bar 承载当前上下文和低频操作。

元素从左到右：

1. Thread 标题：使用当前 thread 的 `title`，单行省略，hover 或 tooltip 展示完整标题。
2. Agent 状态：`idle`、`running`、`error`。运行中状态必须绑定当前 thread 或当前 turn。
3. 上传图片按钮：打开文件选择，上传后加入 composer 引用。
4. 扫描项目图片按钮：触发项目图片扫描，结果更新资产与画板。
5. 新建 thread 按钮：进入新的空白输入准备状态，不立即创建 thread。

规则：

1. 不在 thread bar 中放大量筛选器；图片筛选属于 BoardPane。
2. 未打开项目时禁用会触发写入的按钮。
3. Agent 运行中仍允许切换 thread，但运行状态应留在对应 thread 上。
4. 当前 thread 不存在时显示 `No thread` 或空状态，不展示假标题；新会话准备状态可以显示 `新会话` 或 `draft` 状态。
5. 归档或删除类 thread 操作需要使用项目内 ConfirmDialog 二次确认，不使用浏览器原生 `window.confirm`。

## 5. Turn 渲染

消息列表必须以 turn 为主结构，而不是把所有 item 无差别平铺。

Turn 容器需要表达：

1. `turn_id`。
2. `thread_id`。
3. 状态：`queued`、`in_progress`、`completed`、`failed`。
4. 创建时间和更新时间。
5. 可选耗时、错误摘要和 token 用量。
6. 当前 turn 内的 item 列表。

渲染规则：

1. 用户消息位于 turn 开头，右侧气泡，浅灰背景，最大宽度约 `72%`。
2. Assistant 消息位于左侧正文，不强制气泡化，长文本保持可读。
3. 工具、计划、推理、文件变化和图片生成过程位于用户消息与最终 assistant 消息之间。
4. 同一 turn 的图片结果紧跟该 turn 展示，不能只出现在画板。
5. 失败 turn 保留用户消息，并在 turn 内显示错误来源和可恢复建议。
6. 正在运行的 turn 显示流式内容和工具状态；完成后以落库 item 为准重建 UI。
7. 非 `steered` 的起始用户消息可进入编辑态；保存动作表现为保存并从该消息重新运行，而不是单纯改文本。
8. 如果目标消息之后存在有效内容，保存前必须用项目内 ConfirmDialog 确认，说明后续消息、工具结果和生成画板对象会退出当前路径。
9. Agent 运行中、目标消息已失效、目标消息是 steered 追加输入或当前无项目连接时，用户消息编辑入口禁用。
10. 保存失败时保留编辑态和草稿文本，通过现有 notice/error 区展示后端错误。

## 6. Item 映射

Avcs item 与 Codex item 需要保持可追踪映射。

| Avcs item 类型 | Codex item / 事件 | 默认渲染 |
| --- | --- | --- |
| `user_message` | `userMessage` | 右侧用户气泡，包含文本和历史引用缩略图 |
| `assistant_message` | `agentMessage`、`item/agentMessage/delta` | 左侧正文，支持流式追加 |
| `tool_call` | `commandExecution`、`mcpToolCall`、`dynamicToolCall`、`webSearch`、`imageGeneration` | 紧凑工具状态行，可展开详情 |
| `tool_result` | `item/completed` 中的工具结果 | 工具完成摘要、耗时、失败原因或结果链接 |
| `image_asset` | `imageGeneration.savedPath`、`imageView.path`、输出目录扫描结果 | 可点击资产行，定位画板对象 |
| `error` | `error`、failed turn、工具失败 | 当前 turn 内红色错误块 |
| `reasoning` | `reasoning`、`item/reasoning/*` | 默认折叠的推理摘要或状态行 |
| `plan` | `plan`、`item/plan/delta`、`turn/plan/updated` | 简短计划列表或折叠状态行 |
| `file_change` | `fileChange`、`turn/diff/updated` | 文件变化摘要，可展开 diff |

MVP 可以先实现前六类稳定渲染，但数据层应保留 Codex 原始 item 的必要字段，避免后续无法还原过程。

## 7. 工具状态

工具调用需要像 Codex 一样让用户知道 Agent 正在执行什么，但 Avcs 默认保持紧凑。

状态行内容：

1. 工具名称：例如 `image_gen`、`command`、`mcp`、`web search`。
2. 状态：`running`、`completed`、`failed`、`cancelled`。
3. 简短参数摘要：例如图片生成 prompt 摘要、命令名、MCP server/tool 名。
4. 可选耗时。
5. 失败时显示错误摘要。

展开详情：

1. 命令执行可展示 cwd、命令、stdout/stderr 摘要、exit code。
2. 文件变化可展示文件列表和 diff 摘要。
3. MCP 工具可展示 server、tool、参数摘要和结果摘要。
4. 图片生成可展示 revised prompt、保存路径和生成状态。

规则：

1. 工具事件必须按 `thread_id`、`turn_id` 和 `item_id` 归属。
2. 切换 thread 后，不属于当前 thread 的工具流式更新不能显示在当前消息列表。
3. 工具完成后应写入 item 或更新现有 item，刷新页面后仍可看到结果摘要。

## 8. 图片结果与引用

图片是 Avcs 聊天区的核心输出之一。

生成图片结果：

1. Agent 生成或编辑的图片保存到当前项目 `output/`。
2. 后端创建或复用 asset，并关联 `thread_id`、`turn_id` 和必要的 `item_id`。
3. 聊天区在对应 turn 下渲染资产行。
4. 点击资产行在画板中定位并选中对应对象。
5. 如果当前窗口隐藏画板，则点击资产行把图片加入下一条消息引用，或打开预览入口。

历史引用展示：

1. 用户消息如果带有图片引用，应展示缩略图或文件名列表。
2. 引用资产丢失时显示缺失状态，不直接暴露不可用本地路径。
3. 同一个 turn 内的用户引用和 Agent 生成结果要区分清楚。

Composer 引用：

1. 引用缩略图显示在输入器上方或内部顶部。
2. 支持单个移除。
3. 长文件名单行省略。
4. Agent 运行中仍可编辑下一条草稿和引用列表。

## 9. Composer

Composer 使用 CodeMirror，承载自然语言 prompt。

能力：

1. 多行输入。
2. 粘贴长文本。
3. 基础撤销重做。
4. 发送快捷键：`Enter` 和 `Mod-Enter` 发送当前 prompt。
5. 上传图片并自动加入引用。
6. 通过调色盘入口配置本轮图片比例、数量和透明背景。
7. Agent 运行中保持可编辑；composer 为空时主按钮显示 Stop，composer 非空时主按钮发送追加输入到当前 active turn。
8. `Shift-Enter` 插入换行，保证多行 prompt 可编辑。
9. `Cmd+V` / `Ctrl+V` 粘贴剪贴板图片时上传为当前消息引用；文本粘贴仍走 CodeMirror 默认行为。

发送规则：

1. 文本为空且没有图片引用时不能发送。
2. 发送时前端只提交文本和 asset id 列表，不直接拼接本地文件路径。
3. 后端根据 asset id 解析项目内受控路径，再传给 Codex app-server。
4. 发送成功后清空当前输入和引用。
5. 发送失败时保留用户输入和引用，并在当前上下文展示错误。
6. 调色盘配置只影响本次发送；发送前由前端拼接到 prompt 后面，不新增 `message:send` 字段。
7. 调色盘配置本身不构成可发送内容；发送成功后恢复默认值。
8. Agent 运行中且 composer 为空时，主按钮调用 `turn:stop`，不走 `message:send` 的空消息校验。
9. Agent 运行中且 composer 非空时，`message:send` 追加 user item 并通过 `turn/steer` 发送到 active turn，不创建新 turn。

视觉：

1. Composer 固定在聊天栏底部。
2. 最小高度 `148px`，最大高度 `280px`。
3. 左下角放添加图片按钮。
4. 右下角放发送按钮，使用明确 action 色。
5. Placeholder 保持一句话，例如 `Describe the image you want to create...`。

### 9.1 图片生成参数

聊天框需要提供调色盘入口，让用户为本轮图片生成补充轻量约束。

参数：

1. 图片比例：`auto`、`1:1`、`16:9`、`9:16`、`4:3`、`3:4`、`3:1`、`1:3`。
2. 图片数量：`1`、`2`、`3`、`4`。
3. 透明背景：开关。

交互：

1. Composer 底部放调色盘图标按钮。
2. 点击打开紧凑参数面板。
3. 有非默认配置时按钮进入 active 状态，tooltip 展示摘要。
4. 未打开项目时禁用。
5. Agent 运行中仍可调整下一条草稿的调色盘配置。

发送拼接：

1. 调色盘配置只保存在前端当前 composer 草稿中。
2. 只影响这一次按 Enter、`Mod-Enter` 或发送按钮发出的提示词。
3. `auto` 比例、数量 `1` 和非透明背景不拼接。
4. 非默认项拼接为短段落，例如 `Image settings: aspect ratio 16:9; image count 2; transparent background.`。
5. 不新增 `message:send.image_settings` 或 turn 结构化字段。
6. 发送成功后恢复默认值，下一轮需要重新选择。

### 9.2 模型选择

聊天框需要对齐 Codex，让用户选择本轮使用的模型与推理强度。

1. Composer 底部放统一设置入口，显示当前模型、推理强度和权限方式摘要，点击打开设置 Dialog。
2. 模型列表来自 Codex `model/list`，由后端拉取后经 WebSocket 暴露给前端，不在前端硬编码白名单。
3. 推理强度选项对齐 Codex `ReasoningEffort`：`none`、`minimal`、`low`、`medium`、`high`、`xhigh`。
4. 未显式选择时不强行写值，沿用 Codex 配置默认。
5. 选择映射到 `turn/start` 的 `model` 与 `effort` 参数。
6. Composer 底部摘要不显示 `Default` / `default` 占位词；模型有具体值时显示具体模型名，无法确定具体模型时省略模型片段。

作用域（已决策：thread 默认 + 可被 turn 覆盖）：

1. 每个 thread 保存默认 `model` / `effort`。
2. Composer 上的选择作用于下一条 turn；与 Codex「override for this turn and subsequent turns」语义一致，覆盖后写回 thread 默认，后续 turn 沿用。
3. 切换 thread 时选择器回显该 thread 的默认值。

### 9.3 权限方式

聊天框需要让用户选择权限方式（沙箱访问级别），对齐 Codex 的运行控制。本节只覆盖非交互的沙箱预设；交互审批属于独立能力，见 `docs/prds/features/agent/002-交互审批.md`。

权限选择：

1. 权限方式放在 composer 统一设置 Dialog 中，呈现为少量预设档而非裸枚举：`Read Only`、`Auto`、`Full Access`。
2. 预设映射到 `turn/start` 的 `sandboxPolicy` 时，必须使用 Codex app-server v2 schema 要求的对象形态：
   - `Read Only` → `{ "type": "readOnly", "networkAccess": true }`，agent 不可写入，仅适合纯查看。
   - `Auto`（默认）→ `{ "type": "workspaceWrite", "writableRoots": ["<current_project_path>"], "networkAccess": true }`，`writableRoots` 限定为当前项目目录。
   - `Full Access` → `{ "type": "dangerFullAccess" }`，放开项目目录之外的写入，仅供高级显式选择。
3. 默认档为 `Auto`：`approvalPolicy` 保持 `never`，与现有非交互行为一致，主流程不被打断。`approvalPolicy` 非 `never` 的交互审批由 `agent/002` 单独引入，本文档不要求实现。
4. 作用域与模型一致：thread 存默认，composer 选择作用于下一条 turn 并写回 thread 默认。
5. 未打开项目时禁用权限选择器。

默认值约定：

1. 沙箱默认 `Auto`（`sandboxPolicy.type: "workspaceWrite"` + 当前项目 `writableRoots` + 网络开启），等于把现有硬编码值提升为默认预设，无需改动主流程即可上线。
2. `Read Only` 会使保存生成图片失败，只能作为用户主动选择的特殊档，不作默认。
3. 安全边界来自沙箱把写入限制在项目目录，而非逐步审批；因此默认非交互是安全且顺滑的。

## 10. 数据与事件映射

需要的数据：

1. Thread：`id`、`title`、`codex_thread_id`、`status`、`default_model`、`default_effort`、`default_approval_policy`、`default_sandbox_mode`、`created_at`、`updated_at`。
2. Turn：`id`、`thread_id`、`codex_turn_id`、`status`、`user_text`、`model`、`effort`、`approval_policy`、`sandbox_mode`、`created_at`、`updated_at`、`completed_at`、`error`。
3. Item：`id`、`thread_id`、`turn_id`、`codex_item_id`、`type`、`role`、`content`、`payload`、`status`、`created_at`、`updated_at`。
4. Asset link：`asset_id`、`thread_id`、`turn_id`、`item_id`、`source`。
5. Runtime state：当前运行的 `thread_id`、`turn_id`、流式文本、工具状态和错误。
6. 历史编辑路径状态：`turns`、`items`、`asset_links` 和 `board_items` 的 `invalidated_at`、`invalidated_by_item_id`；默认查询和 UI 只展示未失效路径。

推荐 WebSocket 请求：

1. `thread:items:list`：读取当前 thread 的扁平 item 列表，每个 item 必须携带 `turn_id`，前端按 `turn_id` 在客户端分组为 turn。后续可升级为 `thread:turns:list`。
2. `message:send`：发送用户文本和当前引用 asset 列表。
3. `thread:select`：切换当前 thread。
4. `assets:reference`：更新 composer 引用资产。
5. `models:list`：读取 Codex `model/list` 返回的可用模型（需新增）。
6. `thread:settings:update`：更新当前 thread 的默认 `model` / `effort` / `approval_policy` / `sandbox_mode`（需新增）。
7. `message:send` 扩展：在文本与 `asset_ids` 外，允许携带本次 turn 的 `model` / `effort` / `approval_policy` / `sandbox_mode` 覆盖值（需新增字段）。
8. `message:edit_rerun`：提交历史起始用户消息的新文本，并从该点重跑。
9. `turn:stop`：停止当前 thread 的 active turn。

审批相关请求（`approval:respond` 等）属于交互审批能力，见 `agent/002-交互审批.md`。

推荐服务端推送：

1. `turn:started`：当前 turn 已创建或 Codex turn 已开始。
2. `assistant:delta`：assistant 文本流式输出片段。
3. `tool:updated`：工具 item 状态变化。
4. `item:created`：新增稳定 item。
5. `item:updated`：更新已有 item 状态或 payload。（需新增：当前后端尚未广播，工具从 `running` 原地更新到 `completed` 依赖此事件。）
6. `thread:items`：刷新当前 thread 的完整消息数据。
7. `agent:run_started`：Agent 开始运行。
8. `agent:run_completed`：Agent 运行完成，`status` 可以是 `completed`、`failed` 或 `interrupted`。
9. `error`：WebSocket、Agent、文件 API 或预览读取错误。

审批相关推送（`approval:requested` / `approval:resolved`）属于交互审批能力，见 `agent/002-交互审批.md`。

所有运行中事件都必须携带 `thread_id` 和 `turn_id`；工具与流式 item 还应携带 `item_id`。

### 10.1 实施约束（已决策）

1. **turn 分组（验收 #2）**：MVP 不新增 `thread:turns:list`，后端 `thread:items:list` 返回扁平 item，前端用 `turn_id` 客户端分组渲染 turn 容器。
2. **工具状态持久化（验收 #5、§7.3）**：runner 在 `item_started` / `item_completed` 时将工具调用落库为 `tool_call` / `tool_result` item，并广播 `item:created` / `item:updated`；前端弃用瞬态 `tools` 数组，工具状态从持久 item 渲染，刷新后仍可见结果摘要。
3. **thread 归属过滤（验收 #4、#9）**：后端事件已携带 `thread_id`，过滤在前端完成 —— `assistant:delta`、`tool:updated`、`item:created`、`item:updated` 的处理必须丢弃 `thread_id !== currentThreadId` 的事件；切换 thread 时清理不属于当前 thread 的临时 streaming UI。
4. **历史编辑重跑**：`message:edit_rerun` 成功后前端用响应里的 `item` 更新用户气泡，并用 `thread:items` 广播刷新当前有效消息窗口，避免分页 cursor 继续指向失效 turn。

## 11. 状态与错误

需要覆盖：

1. 未打开项目：聊天区禁用发送，提示先打开项目。
2. 当前项目无 thread 或处于新会话准备状态：提供可用 composer，发送首条消息后才创建 thread。
3. 当前 thread 无消息：展示安静空态，不写长篇说明。
4. Agent 运行中：显示当前 turn 的流式文本和工具状态。
5. Agent 失败：错误落在对应 turn 内。
6. 工具失败：工具行显示 failed，并可展开错误详情。
7. 图片生成失败：错误说明来源，保留用户输入。
8. WebSocket 断开：保留最近一次消息列表，禁用写入操作。
9. 资产预览失败：资产行显示缺失或不可读取状态。
10. 用户主动停止：turn 显示 stopped/interrupted 中性色状态，不显示为普通失败。
11. 切换 thread：清理不属于当前 thread 的临时 streaming UI。
12. 历史编辑重跑失败：保留用户消息编辑草稿，不退出编辑态。

错误来源必须明确标识为 Agent、文件 API、WebSocket、预览读取或项目数据。

## 12. 视觉规范

颜色：

1. 聊天区背景使用 `#ffffff` 或 `#fbfbfa`。
2. 用户气泡使用浅灰背景。
3. Assistant 文本默认无气泡，使用正文排版。
4. 工具状态行使用浅边框和 muted 文本。
5. 错误使用浅红背景或红色边线，不铺满整个聊天区。
6. 图片资产行使用白底、浅边框和 hover 浅灰底。

文本：

1. 基础字号 `14px`。
2. 工具状态、时间、辅助信息使用 `12px`。
3. Thread 标题使用 `16px` 到 `18px`，单行省略。
4. 消息正文行高保持 `1.45` 到 `1.6`。
5. 字间距保持 `0`，不使用负字距。

间距与尺寸：

1. 消息列表左右 padding `16px`。
2. Turn 间距 `18px` 到 `24px`。
3. 同一 turn 内 item 间距 `8px` 到 `12px`。
4. 用户气泡圆角不超过 `8px`。
5. 工具状态行和资产行圆角不超过 `8px`。
6. 图标按钮推荐 `32px`，紧凑操作可用 `28px`。

## 13. 响应式

桌面：

1. 聊天区保持窄列，右侧画板占据主要空间。
2. 聊天区内部滚动不影响画板滚动。

`<= 1080px`：

1. 画板可隐藏，聊天区仍完整可用。
2. 点击图片资产行时，如果画板不可见，应加入引用或提供预览反馈。

`<= 760px`：

1. 使用顶部 tab 在 Project、Thread、Board 之间切换。
2. Composer 不应遮挡消息列表最后一条内容。
3. 长文件名、长 thread 标题和长工具摘要必须省略或换行，不撑破布局。

## 14. 不做事项

1. 不把聊天区做成完整终端或 IDE。
2. 不在聊天区展示完整文件树。
3. 不让 React 直接读取本地文件、SQLite 或 Codex app-server。
4. 不把图片生成结果只放在文本里而不创建 asset。
5. 不把工具流式状态做成只存在内存、刷新后完全不可追踪的唯一记录。
6. 不展示无实际功能的 Help、Search、Notifications 或复杂筛选入口。

## 15. 验收标准

1. 当前 thread 标题、Agent 状态和基础操作在顶部 thread bar 中清晰可见。
2. 消息列表按 turn 分组，而不是只按 item 平铺。
3. 用户消息、assistant 消息、工具状态、图片结果和错误都能归属到正确 turn。
4. 流式 assistant 文本只显示在对应 thread 和 turn 中。
5. 工具调用显示运行中、完成和失败状态，完成后刷新页面仍能看到结果摘要。
6. 用户历史图片引用能在对应用户消息中看见。
7. 生成图片在聊天中显示为资产行，并能定位到画板对象或加入下一条引用。
8. Agent 运行中空 composer 可停止当前 turn；非空 composer 可发送追加输入到当前 active turn，不能创建重复 turn。
9. 切换 thread 不会把另一个 thread 的 streaming 文本或工具状态显示到当前 thread。
10. 未打开项目、无消息、运行中、失败、连接断开和资产缺失都有明确状态。
11. Composer 通过统一设置 Dialog 选择模型与推理强度，模型列表来自 Codex `model/list`；选择作用于下一条 turn 并写回 thread 默认，切换 thread 正确回显。
12. Composer 通过同一个设置 Dialog 选择权限方式（`Read Only` / `Auto` / `Full Access`），映射到 `turn/start` 的对象形态 `sandboxPolicy`；默认 `Auto` 为 `{ "type": "workspaceWrite", "writableRoots": ["<current_project_path>"], "networkAccess": true }` + `approvalPolicy: never`，主流程不被打断。
13. Composer 底部只保留一个设置入口和紧凑摘要；摘要不出现 `Default` / `default` 占位词，有具体模型时显示具体模型名。
14. Composer 调色盘入口支持本轮选择图片比例、图片数量和透明背景；发送时只拼接到本次 prompt，发送成功后恢复默认，不新增 WebSocket 字段。
15. 用户主动 Stop 后 turn 状态保持为 `interrupted`，刷新后不显示红色错误块。
16. 用户编辑历史起始消息并确认保存后，旧后续路径从消息列表和当前 Output 画板退出，新的 Agent run 从编辑后的用户消息下方继续。
