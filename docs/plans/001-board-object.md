---
git_commit_message: 'board: plan image preview dialog'
plan_state: finished
---
# Board image preview dialog

## current_status

当前 `BoardPane` 已经实现 Output 图片对象的 DOM 自由布局、选择、移动、缩放、多选布局工具、`Reference`、`Reveal`、`Copy path`、Fit selected、Fit all 和 zoom 控制。

现有行为：

1. Output 画板对象通过 `BoardObject` 渲染为普通 DOM 元素和 `img`。
2. 图片预览 URL 已由 `web/src/api.js` 的 `previewUrl(asset)` 指向 Phoenix HTTP 预览接口 `/api/assets/:id/preview`。
3. 当前 `startObjectDrag` 在非追加选择时会立即调用 `onReferenceAsset(item.asset_id)`，因此点击画板图片会把图片加入聊天输入区引用。
4. `Reference` 工具按钮也能将当前选中图片加入聊天输入区引用。
5. Work tab 的素材行点击同样会调用 `onReferenceAsset(asset.id)`，本计划不改变 Work tab 行为。
6. `docs/prds/features/board/001-画板自由布局.md` 和 `docs/prds/features/board/002-画板对象选择移动与缩放.md` 仍写着“点击画板图片加入聊天引用”，需要在实现完成后同步修订，避免和本需求冲突。

主要缺口：

1. Output 画板图片没有 ChatGPT 风格的全屏预览 dialog。
2. 预览、选择、拖拽移动和加入引用目前没有清晰分流。
3. 现有点击即引用会让用户很难只查看大图。
4. 画板没有全屏图片查看时的顶部标题栏、关闭按钮、居中大图、底部描述编辑输入和键盘关闭能力。

## overview

目标是在 Board 的 Output 图片对象上实现点击打开全屏图片预览 dialog，视觉和交互参考 ChatGPT 图片查看效果：顶部轻量栏显示关闭按钮和图片标题，中间居中展示完整图片，底部提供紧凑的“描述编辑”输入。

边界：

1. 只针对 Output 画板对象点击打开预览；Work tab 素材列表仍保留点击加入引用的现有行为。
2. 画板主渲染层继续使用普通 HTML DOM，不引入 Canvas/WebGL/SVG。
3. 预览 dialog 是前端临时 UI 状态，不写入 SQLite。
4. 图片文件仍通过 Phoenix 预览 API 读取，React 不直接拼接本地路径读取文件。
5. `Reference`、`Reveal`、`Copy path` 保留为明确按钮操作，不再由 Output 图片普通点击隐式触发引用。
6. 本计划不实现图片裁切、旋转、缩放到原图像素编辑、滤镜、历史版本对比或专业批注。

第一阶段覆盖：

1. 单击 Output 图片对象，打开全屏预览 dialog。
2. 拖动画板对象时只移动对象，不打开 dialog。
3. Shift/Cmd/Ctrl 追加选择时只更新选区，不打开 dialog。
4. Dialog 顶部显示关闭按钮和图片文件名。
5. Dialog 中间用 `img` 等比例完整显示图片，按 viewport 自适应，不裁切。
6. Dialog 底部显示紧凑描述编辑 composer；发送时把当前预览图片作为本轮唯一图片引用。
7. Esc、顶部关闭按钮和点击背景空白区都可以关闭 dialog。

## data_model

不新增表，不修改项目 SQLite。

前端新增临时状态，建议放在 `BoardPane` 内部：

```js
{
  previewDialog: {
    assetId: "asset-id",
    boardItemId: "board-item-id",
    prompt: "",
    isSending: false
  }
}
```

状态规则：

1. `assetId` 用于从 `assets` 查找文件名、尺寸、相对路径和 `previewUrl(asset)`。
2. `boardItemId` 用于关闭后恢复焦点或保持当前选区。
3. `prompt` 是 dialog 底部输入内容，不写入全局 composer state。
4. `isSending` 只表示 dialog 内发送请求的前端过渡状态，不写入 SQLite。
5. 切换项目、资产列表移除该 asset、切换到 Work tab 或卸载 `BoardPane` 时关闭 dialog。

## api

不新增后端 API。复用现有接口：

1. `GET /api/assets/:id/preview`：dialog 图片显示。
2. `message:send`：底部描述编辑发送消息。
3. `assets:reference`：保留给显式 Reference 按钮，不由 Output 图片普通点击触发。

为实现底部描述编辑，`App.jsx` 向 `BoardPane` 传入新回调：

```js
onSendImagePrompt(assetId, text)
```

回调规则：

1. `text` 必须非空；空输入时发送按钮 disabled。
2. 发送 payload 等价于普通 composer 发送：`{ text, asset_ids: [assetId] }`。
3. 不污染当前主 composer 的 `references`，也不把 dialog 图片追加到主 composer 引用条。
4. 如果当前 thread 正在运行且后端支持 steer，则沿用现有 `message:send` 的运行中追加输入语义。
5. 发送失败时保留 dialog 和输入内容，展示现有 notice/error。
6. 发送成功后清空 dialog 输入；建议关闭 dialog 并回到画板，减少焦点冲突。

## ui

### Board click behavior

调整 `BoardObject` 点击和拖拽分流：

1. `onPointerDown` 仍用于选择和启动拖拽。
2. 指针移动距离超过 4px 视为拖拽，只移动对象，不打开预览。
3. pointer up 时如果没有拖拽且不是 Shift/Cmd/Ctrl 追加选择，则选中该对象并打开预览 dialog。
4. Shift/Cmd/Ctrl 点击继续追加或取消选择，不打开预览。
5. Resize handle、layout toolbar、floating tools 的 pointer/click 事件必须阻止冒泡，避免误开预览。
6. 移除 Output 图片普通点击里的隐式 `onReferenceAsset(item.asset_id)`；加入引用只通过 `Reference` 工具按钮或 dialog 底部发送。

### Dialog layout

新增组件建议：

```text
web/src/features/board/ImagePreviewDialog.jsx
```

组件 props：

```js
{
  asset,
  prompt,
  isSending,
  onPromptChange,
  onSend,
  onClose,
  onReference,
  onReveal,
  onCopyPath
}
```

结构：

1. 最外层使用 fixed fullscreen overlay，覆盖整个工作台。
2. 顶部栏高度约 `64px`，左侧是关闭按钮，旁边显示图片文件名。
3. 顶部右侧可放 `Reference`、`Reveal`、`Copy path` 三个 icon 按钮，沿用 lucide icons 和 `IconButton`。
4. 中央区域使用 flex 居中图片，背景为极浅灰或白色。
5. 图片使用 `max-width: min(100%, calc(100vw - 48px))` 和 `max-height: calc(100vh - 180px)`，`object-fit: contain`，不裁切。
6. 透明 PNG 继续使用棋盘底纹，和画板对象视觉一致。
7. 底部 composer 宽度约 `min(920px, calc(100vw - 48px))`，居中悬浮在底部，视觉参考 ChatGPT 的圆角输入条。
8. 底部输入使用现有 `PromptEditor` / CodeMirror，不新增 textarea 作为聊天输入替代。
9. 底部发送按钮使用现有发送 icon；空 prompt 或 `isSending` 时 disabled。

样式入口：

1. `web/src/styles/_components.scss` 增加 `.image-preview-dialog`、`.image-preview-topbar`、`.image-preview-stage`、`.image-preview-image-wrap`、`.image-preview-composer` 等类。
2. 使用 Sass 维护颜色、阴影、边框、hover、disabled 和响应式规则。
3. 不使用 Tailwind、CSS-in-JS、Less 或组件库主题系统。
4. Dialog z-index 必须高于 board overlay、floating tools、settings 页面普通内容和 notice。

### Responsive behavior

1. 桌面端图片居中显示，底部 composer 不遮挡图片主体；必要时中央区域为图片预留底部安全距离。
2. 移动或窄屏时顶部栏仍显示关闭按钮和文件名，文件名溢出省略。
3. 窄屏底部 composer 宽度跟随 viewport，两侧保留 12px 到 16px 间距。
4. 图片尺寸优先完整显示；当图片过高时垂直缩小，不出现页面级滚动。
5. Dialog 打开时锁定页面滚动，关闭后恢复。

### Accessibility

1. Dialog 使用 `role="dialog"` 和 `aria-modal="true"`。
2. 顶部关闭按钮 `aria-label` 为 `Close image preview`。
3. `Esc` 关闭 dialog。
4. 打开后焦点进入关闭按钮或底部输入；关闭后尽量恢复到触发的 board object。
5. Tab 焦点限制在 dialog 内部。
6. 图片 `alt` 使用 `asset.file_name`。

## commands

实现后建议运行定向测试：

```bash
mix test test/avcs_web/controllers/asset_controller_test.exs test/avcs_web/channels/avcs_channel_test.exs
```

前端调试只启动 Vite dev server，不主动运行生产 build：

```bash
cd web && npm run dev
```

手动验收时用浏览器检查：

1. 点击 Output 图片打开全屏 dialog。
2. 拖动 Output 图片不会打开 dialog。
3. Shift/Cmd/Ctrl 点击仍能多选，不打开 dialog。
4. Dialog 图片完整显示，横图、竖图、透明 PNG 都不裁切。
5. Esc、关闭按钮、背景空白区都能关闭。
6. Dialog 底部输入发送时，消息携带当前图片引用，主 composer 引用条不被污染。

## others

验收重点：

1. Output 画板普通点击的默认结果从“加入引用”改为“打开预览 dialog”。
2. 画板拖拽、缩放、多选、布局工具和 camera pan/zoom 不受影响。
3. `Reference` 工具按钮仍能把选中图片加入聊天输入引用。
4. 全屏 dialog 与参考图一致：顶部关闭和标题、中间大图、底部描述编辑输入。
5. React 不直接访问本地文件路径，图片仍走 Phoenix preview API。
6. 不引入 TypeScript、Tailwind、CSS-in-JS、Less、Canvas/WebGL/SVG 主渲染层。

## prds

完成实现后同步更新：

1. `docs/prds/features/board/001-画板自由布局.md`：把“点击画板图片加入聊天输入区引用”改为“点击 Output 画板图片打开全屏预览；引用通过 Reference 操作或预览 dialog 发送”。
2. `docs/prds/features/board/002-画板对象选择移动与缩放.md`：补充点击预览、拖拽不预览、追加选择不预览，以及移除普通点击隐式引用。
3. `docs/prds/features/turns/002-图片引用与上传.md`：补充 Board 预览 dialog 底部描述编辑发送时自动携带当前图片引用。
4. `docs/prds/features/ui/001-三栏工作台UI.md`：补充 Board 图片全屏预览 dialog 的顶部栏、居中大图和底部 composer。
