# 002 Thread 管理

状态：Draft  
领域：`lib/avcs/threads`

## 1. 目标

一个项目可以包含多个 thread。每个 thread 承载一次持续创作方向或任务上下文，用户可以在左栏创建、切换、重命名和删除或归档 thread。

## 2. Thread 数据

Thread 需要记录：

1. 标题。
2. 创建时间和更新时间。
3. 所属项目。
4. turn 列表。
5. 关联资产列表。
6. 左侧栏显示顺序 `sidebar_order`。
7. 归档或删除状态，具体实现可使用软删除以避免误删历史数据。

Thread 之间不共享记忆，但可以引用同一个项目文件夹中的资产。

## 3. 用户流程

1. 左栏展示全局项目列表。
2. 用户展开某个项目后，左栏展示该项目下的 thread 列表。
3. 用户可以切换项目，并恢复该项目的当前 thread 或默认 thread。
4. 用户可以点击新会话入口进入准备状态，此时不立即创建 thread。
5. 用户在准备状态发送第一条消息后，系统创建 thread 并保存该消息。
6. 用户可以选择一个 thread，聊天区加载该 thread 的 turn/item。
7. 用户可以重命名 thread。
8. 用户可以删除或归档 thread；如果 UI 暴露删除，需要有明确确认。

## 4. 左栏要求

左栏负责项目上下文和 thread 切换，对齐 Codex 的「项目管理器 + 会话列表」心智，不做完整文件浏览器。详细 UI 规格见 `docs/prds/features/ui/002-Codex左侧栏对齐.md`。

信息层级：

1. 顶部分类区：`项目`、侧栏控制、更多菜单和文件夹加号入口。
2. 项目列表区：展示全局 SQLite 中的项目索引，支持项目切换和展开收起。
3. Thread 列表区：展示展开项目下的历史对话或任务 thread。
4. 底部状态区：WebSocket、Agent、文件 API 的简短状态。

视觉规则：

1. 当前项目和当前 thread 使用浅灰或浅蓝灰选中底，不使用大面积高饱和蓝色填充。
2. 项目行高 `32px` 到 `36px`，thread 行高 `30px` 到 `34px`，圆角不超过 `8px`。
3. Thread 行的重命名、删除按钮默认隐藏，hover 或选中时出现。
4. 项目名、thread 标题和项目路径必须单行省略，hover 或 tooltip 展示完整内容。
5. 项目 thread 过多时默认折叠为少数相关 thread，并提供 `展开显示`。

## 5. WebSocket 事件

客户端发送：

1. `threads:list`：读取 thread 列表。
2. `thread:create`：在用户发送新会话第一条消息时创建 thread；点击新会话入口本身不调用。
3. `thread:select`：切换当前 thread。
4. `thread:reorder`：按客户端传入的完整 thread ID 列表重写当前项目未归档 thread 的 `sidebar_order`。
5. `thread:items:list`：读取当前 thread 的聊天内容。

服务端推送：

1. `threads:updated`：thread 列表更新。
2. `thread:items`：返回或刷新聊天内容。
3. `error`：thread 操作失败。

## 6. 空状态

未打开项目时：

1. 禁用 thread 新建。
2. 不展示空的 thread 列表噪声。

Thread 为空时：

1. 聊天区展示空消息列表和可用 composer。
2. 用户可以直接发送第一条消息；如果当前处于新会话准备状态，系统先创建 thread，再创建 turn/item。

## 7. 验收标准

1. 一个项目可以创建多个 thread。
2. 用户能在左栏切换当前 thread。
3. 当前 thread 有明确选中态。
4. 切换 thread 后，聊天区展示对应 turn/item。
5. Thread 列表更新通过 WebSocket 同步到前端。
6. Thread 数据写入项目 SQLite，不写入全局 SQLite。
