---
git_commit_message: 'board: detail selection and layout tools plan'
plan_state: finished
---
# Board view selection and layout tools

## current_status

当前 `BoardPane` 已经有 DOM 画板、`board-world` camera transform、输出图片对象、Work/Output tab、单个对象移动、单个对象右下角缩放、选中框、名称标签、尺寸标签、引用、Reveal、Copy path、Fit selected、Fit all 和 zoom 控制。

主要缺口：

1. 画板空白处左键拖拽目前直接进入 pan，实际更像 Pan 工具，不符合默认 Select 工具预期。
2. 现有工具栏里 `Select mode` 只是常亮按钮，没有真正的工具模式状态，也没有右侧 Pan 工具入口。
3. 多选只支持 Shift/Cmd/Ctrl 点击追加选择，不支持区域框选。
4. 多选后可以看到多个单独选中框，但没有聚合选区、顶部浮动布局工具条和批量布局操作。
5. 后端 `Avcs.Board` 只有单对象 `move_item/4`、`resize_item/4`；Channel 只有 `board:item:move`、`board:item:resize`，没有批量保存接口。

## overview

目标是把画板交互调整成设计工具式工作流：默认是 Select 工具，用户可以点击或区域框选一个或多个 `output/` board item；被选对象显示蓝色/紫色选中态、名称、尺寸和选中范围；右侧工具栏提供 Select/Pan 切换；多选时顶部浮动工具条提供对齐、统一尺寸和间距整理。

边界：

1. 画板主渲染层继续使用普通 HTML DOM，不引入 Canvas/WebGL/SVG。
2. `camera`、当前工具、选区和框选矩形都是前端临时 UI 状态，不写入 SQLite。
3. 批量布局只修改 `board_items.x`、`board_items.y`、`display_width`、`display_height` 和 `updated_at`。
4. 操作对象仅限当前可见的 Output board item；Work tab 仍是素材列表，不参与画板框选和布局。
5. 保留现有单对象移动、单对象缩放、引用、Reveal、Copy path、Fit selected、Fit all 和滚轮/触控板 pan/zoom。
6. 本计划不实现旋转、裁切、蒙版、图层面板、吸附、小地图、文本对象或复杂快捷键。

## data_model

不新增表。复用项目 SQLite 中的 `board_items`：

1. `x`、`y`：世界坐标左上角。
2. `display_width`、`display_height`：显示尺寸，不修改原始图片文件。
3. `z_index`：当前计划不调整层级。
4. `asset_id` 唯一约束保持不变，一个 `output/` asset 对应一个 board item。
5. `thread_id`、`turn_id`、`item_id`、`source` 仅作为来源标记，不参与布局计算。

布局计算规则：

1. 所有计算使用世界坐标，屏幕拖拽 delta 必须除以 `camera.zoom`。
2. Align 使用当前选区边界作为基准：left/top 取最小边，right/bottom 取最大边，center 使用选区外框中心。
3. Normalize width/height 使用 primary selection 的宽高；primary selection 是最后一次明确点击的对象，fallback 为 `selectedIds[0]`。
4. Tidy horizontal 按对象中心点 x 排序，从最左侧对象位置开始，将相邻对象整理为 16px 横向间距。
5. Tidy vertical 按对象中心点 y 排序，从最上方对象位置开始，将相邻对象整理为 16px 纵向间距。
6. 如果间距计算为负数，保留排序并使用最小间距 `16`，允许整理后的选区向右或向下扩展。
7. 尺寸最小值统一为 `64`，前后端使用同一约束，避免保存后回弹。

## api

保留现有单对象事件：

1. `board:item:move`：单个对象移动。
2. `board:item:resize`：单个对象缩放。

新增批量更新能力：

```elixir
Avcs.Board.update_items(project, updates)
```

`updates` 示例：

```elixir
[
  %{"id" => board_item_id, "x" => 120.0, "y" => 80.0},
  %{"id" => other_id, "x" => 260.0, "y" => 80.0, "display_width" => 320.0}
]
```

后端规则：

1. 只允许更新属于当前项目且关联 `output/%` asset 的 board item。
2. `id` 必须存在；不存在返回 `board_item_not_found`，不要静默忽略。
3. 坐标和尺寸必须是有限数字；非法值返回 `invalid_board_item_update`。
4. `display_width`、`display_height` 小于 `64` 时按 `64` 保存。
5. 批量更新在同一个 SQLite transaction 内完成。
6. 返回更新后的 board item 列表，按 `z_index ASC, created_at ASC` 排序。

新增 Channel 事件：

```json
{
  "items": [
    { "id": "board_item_id", "x": 120, "y": 80 },
    { "id": "other_id", "x": 260, "y": 80, "display_width": 320 }
  ]
}
```

事件名：`board:items:update`

响应：

```json
{
  "items": []
}
```

推送策略：

1. `board:items:update` 成功后广播 `board:item:updated`，每个更新对象一条，兼容现有前端事件合并逻辑。
2. 如果一次批量操作超过 50 个对象，可以额外广播 `board:items` 全量列表，避免客户端漏合并。
3. 单对象事件仍可内部复用 `update_items/2`，减少保存逻辑分叉。

## ui

`BoardPane` 增加这些状态：

```js
{
  toolMode: "select",
  primarySelectedId: null,
  marquee: null,
  layoutMenu: null
}
```

工具模式：

1. 默认 `toolMode` 是 `select`。
2. 右侧浮动按钮栏增加 Select 和 Pan 两个互斥按钮；Select 使用指针图标，Pan 使用手型图标。
3. Select 模式下空白处点击清空选区，空白处拖拽创建区域框选。
4. Pan 模式下按住画板拖拽只移动 camera，不选择、不移动、不引用图片对象。
5. 滚轮和触控板 pan/zoom 保持现有行为，在 Select/Pan 两种模式下都可用。

选择与框选：

1. 点击对象选中该对象，并设为 primary selection。
2. Shift/Cmd/Ctrl 点击对象追加或取消选择，保持现有多选能力。
3. 框选矩形绘制在 `board-overlay` 的屏幕层，拖拽结束后转换为世界坐标。
4. 框选命中规则使用矩形相交，不要求完全包住对象。
5. 普通框选替换当前选区；按住 Shift/Cmd/Ctrl 框选追加到当前选区。
6. 选区变化后过滤掉已经不存在或不可见的 board item。

移动与缩放：

1. 拖拽已选中的对象时，移动整个选区。
2. 拖拽未选中的对象时，先把它设为单选，再移动该对象。
3. pointer move 期间即时更新前端位置；pointer up 后通过 `board:items:update` 批量保存。
4. 单选时保留右下角 resize handle；多选时不做整体缩放，只通过 Normalize width/height 批量调整尺寸。
5. 保存失败时显示错误，并重新调用 `assets:list` 与 `board:items:list` 恢复服务端状态。

选中态：

1. 单选继续显示对象边框、四角控制点、名称和尺寸。
2. 多选时每个对象显示轻量选中框，同时显示一个覆盖全部对象的聚合选区边界。
3. 聚合选区标签显示 `{n} selected`，不遮挡图片主体。
4. 选中框、控制点、标签和工具条保持固定屏幕尺寸，不随 `camera.zoom` 缩放。

顶部浮动布局工具条：

1. 选中对象数量大于 1 时显示，定位在 `board-overlay` 顶部或聚合选区上方，避免超出 viewport。
2. 工具条包含 Align 和 Tidy 两组菜单，不在页面中加入说明性长文案。
3. Align 菜单项：`Align Left`、`Horizontal Center`、`Align Right`、`Align Top`、`Vertical Center`、`Align Bottom`、`Normalize Width`、`Normalize Height`。
4. Tidy 菜单项：`Tidy Horizontal Space`、`Tidy Vertical Space`。
5. Align、Normalize 和 Tidy 都在至少 2 个对象时可用。
6. 触发布局操作后先本地计算并更新 UI，再批量保存；保存失败按服务端状态回滚。

样式入口：

1. `web/src/styles/_components.scss` 增加 `board-marquee`、`board-selection-bounds`、`board-layout-toolbar` 和菜单样式。
2. 继续通过稳定 `className` 写 Sass，不使用 Tailwind、CSS-in-JS、Less 或组件库主题系统。
3. 工具按钮继续复用 `IconButton` 和 lucide icons；菜单项使用紧凑按钮，不让文字溢出容器。

## commands

实现后使用定向测试验证后端批量保存：

```bash
mix test test/avcs/local_first_test.exs test/avcs_web/channels/avcs_channel_test.exs
```

前端调试只启动 Vite dev server，不主动运行生产 build：

```bash
cd web && npm run dev
```

## others

验收重点：

1. 默认鼠标拖拽空白区域是区域框选，不再直接 pan。
2. 右侧按钮栏可以切换 Pan 工具，并能拖动画板视图。
3. 多选移动、对齐、统一宽高和间距整理会保存到项目 SQLite，刷新后位置和尺寸一致。
4. 布局操作在不同 zoom 下仍按世界坐标保存。
5. Work 素材列表不被框选和布局操作影响。

## prds

完成实现后同步更新：

1. `docs/prds/features/board/002-画板对象选择移动与缩放.md`：补充 Select/Pan 工具、区域多选、多选移动、聚合选区和布局操作。
2. `docs/prds/features/web/002-WebSocket状态同步.md`：补充 `board:items:update` 批量更新事件。
3. `docs/prds/features/ui/001-三栏工作台UI.md`：补充右侧工具模式按钮和顶部浮动布局工具条。
