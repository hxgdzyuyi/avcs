# 011 WebSocket 状态同步

状态：Draft  
领域：`lib/avcs_web/channels`

## 1. 目标

React 与 Elixir 的应用状态同步主要通过 WebSocket / Channel 完成。文件系统操作使用 Phoenix HTTP API，API 完成后通过 WebSocket 推送项目、thread、asset 和 board 状态变化。

## 2. 通信边界

运行时通信：

```text
React 前端  <--WebSocket/HTTP API-->  Elixir/Phoenix  <--stdio JSONL-->  Codex app-server
```

职责：

1. React 不直接调用 Codex app-server。
2. React 不直接读写全局 SQLite 或项目 SQLite。
3. React 不直接读写本地文件系统。
4. Elixir 负责校验事件、写库、管理项目文件夹、保存图片资产，并把状态变更推送给 React。
5. Codex app-server 的输出由 Elixir 解析为 turn/item/asset 事件，再通过 WebSocket 推送给 React。

## 3. 客户端发送事件

事件命名保持直观、面向业务：

1. `project:current`：读取当前项目。
2. `threads:list`：读取 thread 列表。
3. `thread:create`：新会话准备态发送第一条消息时创建 thread；点击铅笔入口不发送该事件。
4. `thread:select`：切换当前 thread。
5. `thread:items:list`：读取当前 thread 的聊天内容。
6. `message:send`：发送用户消息和当前聊天输入区引用的 asset 列表，并触发 Elixir 通过 stdio 调用 Codex app-server。
7. `assets:list`：读取资产列表。
8. `assets:reference`：更新当前聊天输入区引用的图片资产。
9. `assets:select`：更新画板当前选中的图片资产。
10. `board:items:list`：读取画板对象列表。
11. `board:item:move`：更新画板对象位置。
12. `board:item:resize`：更新画板对象显示尺寸。

## 4. Phoenix HTTP API 对应动作

文件系统相关动作不走 WebSocket：

1. `project:create_blank` 对应输入项目名，并在 `~/Documents/Avcs` 下创建不重名的空白项目文件夹。
2. `project:open_folder` 对应输入本地绝对路径，并打开或初始化现有项目文件夹。
3. `assets:import` 对应导入图片。
4. `assets:upload` 对应聊天区上传图片。
5. `assets:scan` 对应扫描项目目录图片。
6. 图片预览、打开所在文件夹、复制本地路径等文件系统相关动作。

## 5. 服务端推送事件

1. `project:updated`：当前项目状态更新。
2. `threads:updated`：thread 列表更新。
3. `thread:items`：返回或刷新聊天内容。
4. `agent:run_started`：Agent 开始运行。
5. `assistant:delta`：Agent 文本流式输出片段。
6. `item:created`：新增 turn/item。
7. `tool:updated`：工具调用状态更新。
8. `asset:created`：新增图片资产。
9. `assets:updated`：资产列表更新。
10. `board:item:created`：新增画板对象。
11. `board:item:updated`：画板对象位置、尺寸或层级更新。
12. `asset:referenced`：图片资产被加入当前聊天输入引用。
13. `agent:run_completed`：Agent 运行完成。
14. `error`：可恢复错误或失败状态。

## 6. 状态与错误

UI 必须覆盖：

1. WebSocket 连接中。
2. 已连接。
3. 断开。
4. 重连中。
5. 重连失败。
6. 当前请求失败。
7. 后端返回业务错误。

聊天区和画板区都应展示可恢复的错误信息，避免用户不知道当前失败发生在 Agent、文件系统还是前端加载。

## 7. 验收标准

1. React 与 Elixir 的应用状态通信通过 WebSocket 完成。
2. 项目、thread、turn、item、asset、board item 的状态变化能通过事件同步到前端。
3. 文件操作仍通过 HTTP API，不混入 WebSocket。
4. WebSocket 断开、重连中或重连失败都有可见反馈。
5. 具体事件 payload 可以随实现调整，但不能破坏通信边界。
