---
git_commit_message: 'board: plan undo redo history'
plan_state: rendered
---
# 004 画板对象操作 Undo / Redo

## current_status

1. `BoardPane` 已支持 Output 画板对象选择、移动、resize、对齐、统一宽高、间距整理、层级调整、按真实比例重排、删除和引用。
2. 移动、批量移动、布局、层级和真实比例重排都通过 `onUpdateItems(updates, true)` 走 `board:items:update` 保存；拖拽过程中的中间帧使用 `commit=false` 只做乐观更新。
3. 单对象 resize 目前走 `onResize(id, width, height, true)` 和 `board:item:resize`，未汇入批量更新入口。
4. 后端 `Avcs.Board.update_items/2` 已支持批量更新 `x`、`y`、`display_width`、`display_height` 和 `z_index`，并校验只能更新 Output board item。
5. `App.jsx` 保存失败时会提示错误并重新拉取 assets 与 board items。
6. 当前没有 board item 操作历史栈，用户误移动、误缩放、误整理或误改层级后只能手动恢复。

## overview

新增简单的画板对象 Undo / Redo，只覆盖当前浏览器会话内的 Output board item 几何与层级变更。

边界：

1. 只作用于 Output 画板对象，不作用于 Work 素材列表、聊天输入、mask 涂抹、图片文件内容、项目/thread 管理或 Agent turn。
2. 只记录 `board_items` 的 `x`、`y`、`display_width`、`display_height`、`z_index` 变化。
3. 历史栈只保存在前端内存中，不写入项目 SQLite，不跨刷新、跨项目或跨窗口恢复。
4. Undo / Redo 本身仍通过现有 Channel 保存到项目 SQLite，成功后刷新页面可看到撤销后的状态。
5. 不新增 Canvas/WebGL/SVG 主渲染层，不改变画板 DOM 自由布局方案。
6. 不实现专业编辑器级 history，如事务合并配置、历史面板、跨端冲突合并、删除恢复、asset 复制粘贴恢复或持久历史。

## data_model

前端新增内存历史结构：

1. `undoStack`：按时间保存已提交的 board item 操作。
2. `redoStack`：执行 undo 后保存可重做操作；一旦用户提交新的普通操作即清空。
3. 单条 history entry 包含：
   - `id`：前端生成的唯一 id。
   - `label`：用于 tooltip / aria label 的动作名，例如 `Move`、`Resize`、`Arrange`、`Layer order`。
   - `before`：操作前每个 item 的快照。
   - `after`：操作后每个 item 的快照。
4. 快照字段只包含 `id`、`x`、`y`、`display_width`、`display_height`、`z_index`；缺失字段按当前 item 原值补齐。
5. 历史栈长度限制为 50 条，避免长时间编辑占用过多内存。

入栈规则：

1. 只有 `commit=true` 且产生实际差异时入栈。
2. 拖拽、resize 的 pointer move 中间帧不入栈，pointer up 只入一条。
3. 多选移动、布局菜单、层级菜单、快捷键层级调整和真实比例重排各入一条。
4. 保存失败时不保留该 history entry，并沿用当前重新拉取 board items 的恢复策略。
5. 切换项目、重新加载项目或收到全量 `board:items` 同步时清空历史栈，避免旧快照覆盖新状态。

## api

不新增 HTTP JSON API，不新增 Channel 事件。

复用现有事件：

1. `board:items:update`：Undo / Redo 提交批量 `before` 或 `after` 快照。
2. `board:item:resize` 可保留给旧路径，但本计划优先把单对象 resize 提交也改为 `board:items:update`，让所有可撤销 board item 变更经过同一个入口。
3. 服务端继续由 `Avcs.Board.update_items/2` 校验字段、最小尺寸和 Output item 边界。
4. 成功后继续广播 `board:item:updated`；大批量更新继续允许广播 `board:items`。
5. 失败时前端显示错误并重新拉取 assets 与 board items，同时清理本次 pending history。

## ui

入口：

1. 在 Output 画板浮动工具栏新增 Undo 和 Redo 图标按钮，使用 lucide `Undo2` / `Redo2` 或项目内等价图标。
2. Undo 按钮在 `undoStack` 为空时 disabled；Redo 按钮在 `redoStack` 为空时 disabled。
3. Work tab 不展示或禁用 Undo / Redo。
4. tooltip / aria label 展示动作名，例如 `Undo Move`、`Redo Resize`。
5. 按钮位置靠近其它画板编辑工具，避免和 zoom reset 的 `RotateCcw` 语义混淆。

快捷键：

1. `Cmd+Z` / `Ctrl+Z`：Undo。
2. `Cmd+Shift+Z` / `Ctrl+Shift+Z`：Redo。
3. Windows/Linux 可额外支持 `Ctrl+Y` Redo。
4. 焦点在输入框、CodeMirror、contenteditable、select、modal 内或 IME 组合输入期间，不触发画板 Undo / Redo。
5. 快捷键指南 Dialog 中补充 Board 操作项。

交互规则：

1. Undo / Redo 执行期间禁用两个按钮，避免重复提交。
2. 如果被撤销的 item 已不存在，提交前丢弃该 item；若 entry 中所有 item 都不存在，则丢弃该 entry 并继续尝试下一条可用历史或提示无法撤销。
3. Undo / Redo 后保留仍存在的选区；如果选中 item 已不存在，则移除对应 id。
4. Undo / Redo 不改变 camera；用户仍可用 Fit selected / Fit all 调整视图。
5. 操作失败后不让前端长期保持错误乐观状态，继续复用重新拉取 board items 的恢复策略。

## others

实现建议：

1. 在 `App.jsx` 或独立 `web/src/features/board/boardHistory.js` 中集中实现：
   - `createBoardHistoryEntry(items, updates, label)`
   - `applyBoardHistorySnapshot(snapshot)`
   - `pushUndoEntry(entry)`
   - `performUndo()` / `performRedo()`
2. 将 `handleUpdateBoardItems(updates, commit, options)` 扩展为可传 `historyLabel`、`skipHistory`、`afterSuccess`。
3. `BoardPane` 中各提交点传入明确 label：移动、resize、align、normalize、tidy、arrange、layer。
4. 将单对象 resize 的提交改用统一批量更新 helper；保留 `handleResize(..., false)` 只服务拖拽中间帧。
5. 用 `shouldIgnoreGlobalShortcut()` 复用现有快捷键过滤，避免和 composer / modal 冲突。
6. 如没有前端测试框架，不为本计划单独引入；优先把纯函数写成可测试形式，后续测试体系补测。

验证建议：

1. 在 Vite dev server 下手动验证，不运行 `npm run build` 或 `vite build`。
2. 移动单个对象后 `Cmd/Ctrl+Z` 恢复位置，`Cmd/Ctrl+Shift+Z` 或 `Ctrl+Y` 重做。
3. 多选移动、对齐、统一宽高、间距整理、层级调整和真实比例重排都只产生一条历史。
4. resize 拖拽过程中不会产生多条历史，pointer up 后可一次撤销。
5. Undo / Redo 后刷新页面，数据库状态与当前画板一致。
6. 保存失败时显示错误、重新拉取状态，且不会留下可继续应用的错误历史。
7. 切换项目或收到全量 board items 后，旧项目的 Undo / Redo 不再可用。

## prds

完成后同步更新：

1. `docs/prds/features/board/001-画板自由布局.md`：补充画板会话内 Undo / Redo 边界。
2. `docs/prds/features/board/002-画板对象选择移动与缩放.md`：补充移动、resize、布局和层级操作可撤销/重做规则。
3. `docs/prds/features/web/002-WebSocket状态同步.md`：说明 Undo / Redo 复用 `board:items:update`，不新增事件。
4. `docs/prds/features/ui/001-三栏工作台UI.md`：补充浮动工具栏按钮、快捷键和快捷键指南展示。
