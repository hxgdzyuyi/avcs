---
git_commit_message: 'web: add board pan zoom viewport'
plan_state: finished
---
# 画板视图 Pan / Zoom 实施计划

## current_status

当前画板已经有基础自由布局：

1. `BoardPane.jsx` 用 DOM 绝对定位渲染图片对象，`x`、`y`、`display_width`、`display_height` 和 `z_index` 来自 `board_items`。
2. `App.jsx` 负责本地即时更新，并在 pointer up 后通过 `board:item:move`、`board:item:resize` 保存到项目 SQLite。
3. `Avcs.Board` 只保存对象位置和显示尺寸，不保存视图状态。
4. 样式中 `board-shell` 目前使用 `overflow:auto`，`board-canvas` 是固定 `1800x1200` 白色区域。
5. PRD 要求画板主渲染层继续使用普通 HTML DOM，不引入 Canvas/WebGL/SVG；后续缩放只影响视图，不改变对象真实坐标和显示尺寸。

## overview

新增画板 viewport/camera 层，实现类似无限画布的平移和缩放。

核心原则：

1. `board_items.x/y/display_width/display_height` 是世界坐标和世界尺寸。
2. `camera = { x, y, zoom }` 是前端视图状态，表示当前视口左上角对应的世界坐标和缩放倍率。
3. 屏幕坐标和世界坐标通过 helper 转换：
   - `screenX = (worldX - camera.x) * camera.zoom`
   - `worldX = screenX / camera.zoom + camera.x`
4. 平移只移动 camera，不批量改写所有 board item。
5. 缩放以鼠标所在点为中心，缩放前后该点对应的世界坐标保持不变。
6. 图片对象内容随 camera 缩放表达视图 zoom；选中框、控制点、标签等操作 UI 保持屏幕尺寸，不跟随图片一起缩放。
7. “无限”来自虚拟世界坐标和 viewport transform，不创建巨大的物理画布。

实施边界：

1. 改造 `BoardPane.jsx`，新增 viewport ref、camera state、坐标转换和 pan/zoom 事件。
2. 保留现有 `BoardObject` 图片 DOM 渲染、图片引用、Reveal、Copy path。
3. 将选中框、控制点和对象标签从缩放内容层拆到屏幕 overlay 层，或对这些操作 UI 做逆缩放，避免控件尺寸随 zoom 变大变小。
4. 改造拖拽和 resize 计算，屏幕 delta 需要除以 `camera.zoom` 后再更新世界坐标或世界尺寸。
5. `handleLocateAsset` 不再依赖 `scrollIntoView`，改为设置 camera，使目标对象居中显示。
6. 不实现小地图、吸附、旋转、裁切、图层树或文本对象。

## data_model

不新增数据库表和字段。

已有 `board_items` 继续作为世界数据：

1. `x`、`y`：对象左上角世界坐标。
2. `display_width`、`display_height`：对象世界尺寸。
3. `z_index`：世界层级。
4. `asset_id`、`thread_id`、`turn_id`、`item_id`、`source`：来源和筛选。

前端新增临时视图状态：

```js
camera = {
  x: 0,
  y: 0,
  zoom: 1
}
```

`camera` 默认不持久化到项目 SQLite。切换项目或重新加载页面时可以重置为默认视图，避免把个人视角混入项目业务数据。

## api

不新增 HTTP API 或 WebSocket 事件。

沿用现有事件：

1. `board:items:list`：读取世界对象。
2. `board:item:move`：保存对象世界坐标 `x`、`y`。
3. `board:item:resize`：保存对象世界尺寸 `display_width`、`display_height`。
4. `board:item:updated`：同步服务端保存结果。
5. `assets:reference`、`assets:select`：继续用于图片引用和选择。

保存 payload 必须传世界坐标，不传 screen 坐标，也不传 camera。

## ui

画板结构调整：

1. `board-shell` 改为固定 viewport，`overflow:hidden`，负责接收 pan/zoom 事件。
2. 新增 `board-world` 内容层，使用 `transform-origin: 0 0` 和 CSS `matrix(zoom, 0, 0, zoom, -camera.x * zoom, -camera.y * zoom)` 映射世界到屏幕。
3. `board-object` 在 `board-world` 内继续使用 `translate(item.x, item.y)` 和固定世界尺寸，只承载图片本体。
4. 新增 `board-overlay` 屏幕层，不应用 camera transform；选中框、控制点和对象标签根据选中对象的世界 bounds 转成 screen bounds 后渲染。
5. `board-overlay` 中控制点、边框宽度、标签字体和间距使用固定 px，zoom 为 `0.1` 或 `6` 时也保持可点击、可读。
6. `board-overlay` 默认 `pointer-events: none`；只有 resize handle 和必要的 selection box 操作区开启 `pointer-events: auto`，避免遮挡空白 pan/click。
7. 白色工作区不再依赖固定 `1800x1200` 尺寸；可以保留浅色背景边界感，但不能限制对象坐标范围。

交互：

1. 鼠标滚轮缩放，缩放范围先限制为 `0.1` 到 `6`。
2. 缩放中心是鼠标所在屏幕点；滚轮缩放后鼠标下的世界点不漂移。
3. wheel zoom 和工具栏 zoom 共用 `zoomAtScreenPoint` helper；wheel 使用鼠标点，工具栏使用 viewport 中心点。
4. 拖动画板空白区域平移 camera，使用抓取画布语义：`nextCamera.x = startCamera.x - screenDeltaX / zoom`，`nextCamera.y = startCamera.y - screenDeltaY / zoom`。
5. 空白区域平移可以加入 inertia 或 smooth transition，让体验接近 tldraw；拖拽中仍以即时响应优先，松手后的惯性可作为增强。
6. 点击空白区域仅在没有发生明显拖动时清空选择。
7. 拖动对象时保持现有即时移动体验，但对象位移使用 `screenDelta / zoom`。
8. 拖动 overlay 里的右下角 resize 控制点时，尺寸变化使用 `screenDelta / zoom`，并保留最小尺寸限制。
9. 浮动工具栏新增 Zoom in、Zoom out、Reset zoom、Fit selected、Fit all 等图标按钮，并显示当前 zoom 百分比。
10. `Fit all` 定义为 fit 当前已加载并可见的 board items。
11. 画板隐藏在窄屏时，现有“加入引用”的降级行为保持不变。

背景与性能：

1. 默认仍不显示强网格，符合画板自由布局 PRD。
2. 如需要网格或点阵背景，只用 CSS 背景和 camera 派生的 `--grid-size`、`--grid-x`、`--grid-y`，不使用 Canvas/SVG。
3. 先保留现有对象渲染；当对象数量明显增多时，再根据 camera viewport 计算可见范围，只渲染与视口相交的对象。

## others

实现时需要重点覆盖这些边界：

1. 坐标 helper 统一放在 `BoardPane.jsx` 或邻近普通 `.js` 模块中，禁止引入 TypeScript。
2. 所有 pointer 命中测试先从 screen 坐标转 world 坐标，再决定移动、缩放或清空选择。
3. 浮点数保存允许小数；显示标签继续四舍五入。
4. zoom 很大或很小时，screen/world 坐标转换可能出现浮点误差；显示用像素坐标可结合 `Number.EPSILON`、`Math.round` 或固定小数位收敛，避免 1px 抖动。
5. selection overlay 必须跟随 camera 和 board item 状态更新，但控件尺寸不能乘以 zoom。
6. move / resize 在 pointer down 记录对象快照；保存失败时回滚快照或重新拉取 `board:items:list`；服务端 `board:item:updated` 结果优先生效。
7. 多选时保留现有 `n selected` 标签，不让标签和工具栏遮挡主要操作。
8. 保存失败时沿用现有 notice 机制，并避免前端状态和数据库长期不一致。
9. 验证时只跑相关前端开发检查或浏览器手测，不主动运行生产 build。

## prds

完成实现后同步更新：

1. `docs/prds/features/board/001-画板自由布局.md`：移除“不做缩放/无限画布”的过期描述，改为 DOM viewport/camera 缩放约束。
2. `docs/prds/features/board/002-画板对象选择移动与缩放.md`：补充在 camera zoom 下移动、resize、选择框和尺寸标签的行为。
