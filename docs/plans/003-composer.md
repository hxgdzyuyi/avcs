---
git_commit_message: 'web: support composer image paste attachments'
plan_state: rendered
---
# Composer 图片粘贴附件实施计划

## current_status

当前聊天输入和图片引用链路已具备基础能力：

1. `PromptEditor.jsx` 使用 CodeMirror，支持文本输入和发送快捷键，但没有剪贴板图片 paste handler。
2. `ChatPane.jsx` 已渲染 composer reference strip，支持缩略图展示和单个移除。
3. `App.jsx` 的 `handleUpload` 只处理文件选择器上传，上传成功后把 asset id 加入 `references`。
4. `web/src/api.js` 的 `uploadAsset(file)` 已通过 `FormData` 调用 `/api/assets/upload`。
5. `AssetController.upload/2` 和 `Avcs.Assets.upload_image/3` 会把上传图片保存到当前项目 `work/`，按 hash 去重，并创建或复用 asset、board item。
6. `message:send` 已把 `asset_ids` 写入 user item payload；`Avcs.Agent.Runner` 会把这些 asset id 解析为本地路径传给 Codex。

因此本计划只补齐“从剪贴板图片到现有 asset 引用”的前端入口，不新增 React 直接文件系统访问，不新增独立后端协议。

## overview

用户在 Composer 中按 `Ctrl+V` 或 `Cmd+V` 粘贴截图/图片时，前端从剪贴板读取图片 `File`，复用现有上传 API 入库，并将返回的 asset 自动加入当前消息引用。

实施边界：

1. 粘贴图片等价于聊天区上传图片，文件进入当前项目 `work/`。
2. 去重、预览、引用发送和 Agent 入参沿用现有 asset 链路。
3. 文字粘贴继续交给 CodeMirror 默认行为。
4. 不把图片 base64 写入 localStorage、React state 或 SQLite。
5. 不使用 Chromium File System Access API，不让 React 拼接本地路径读取图片。
6. 不改变 Agent `turn/start` 封装；发送时仍只提交文本和 asset id 列表。

## data_model

不新增数据库表和字段。

沿用现有字段：

1. `assets.hash`：项目内去重；重复粘贴同一张图时复用同一个 asset。
2. `assets.source`：可继续使用 `upload`，不强制新增 `paste` 枚举。
3. `items.payload.asset_ids`：用户消息引用图片列表。
4. `asset_links`、`board_items`：继续由 `Avcs.Assets.upsert_asset/3` 维护。

前端临时状态：

1. `references`：已完成上传并可发送的 asset id。
2. `pending_pastes` 或等价组件状态：正在上传的粘贴图片，用于 composer 内 loading/error 展示；不持久化。

## api

不新增 HTTP API。

复用现有接口：

1. `POST /api/assets/upload`：接收剪贴板图片生成的 `File`。
2. `GET /api/assets/:id/preview`：显示 composer 缩略图。
3. `message:send`：继续发送 `{ text, asset_ids }`。
4. `assets:list`、`board:items:list`：上传后刷新资产和画板状态。

前端需要把上传逻辑从 `handleUpload(event)` 拆成可复用函数，例如 `uploadReferenceFile(file)`：

1. 文件选择器调用该函数。
2. 粘贴图片也调用该函数。
3. 上传成功后调用 `addReference(asset.id)` 并刷新资产/画板。
4. 上传失败只更新 notice 或粘贴占位错误，不清空当前 prompt。

## ui

Composer 交互：

1. 用户焦点在 CodeMirror 输入器内时，粘贴剪贴板图片会立即开始上传。
2. 剪贴板没有图片时，保持文本粘贴默认行为。
3. 支持 `image/png`、`image/jpeg`、`image/gif`、`image/webp`；其它 MIME 给出清晰错误。
4. 多张图片同时出现在剪贴板时按顺序上传，成功后依次加入 reference strip。
5. 上传中的图片在 reference strip 中显示临时缩略图或 loading chip，避免用户误以为粘贴无效。
6. 上传完成后显示现有缩略图卡片、文件名和删除按钮。
7. 删除按钮只移除当前消息引用，不删除项目 asset 文件。
8. Agent 运行中仍允许用户编辑下一条草稿和调整引用；如果当前实现发送按钮禁用，粘贴上传不应被 Agent running 阻断。

实现细节：

1. 在 `PromptEditor.jsx` 增加 `onPasteImages` prop，并用 `EditorView.domEventHandlers({ paste })` 读取 `event.clipboardData.items`。
2. 只在找到图片 item 时拦截默认行为；普通文本、代码和长 prompt 粘贴不受影响。
3. 从 `DataTransferItem.getAsFile()` 得到图片文件；必要时用 `new File([blob], generatedName, { type })` 生成稳定文件名。
4. 建议文件名形如 `clipboard-YYYYMMDD-HHMMSS-01.png`，扩展名由 MIME 推导。
5. `ChatPane.jsx` 把 `onPasteImages` 传给 `PromptEditor`，并在 composer 区域显示 pending/error 状态。

## others

错误处理需要覆盖：

1. 未打开项目时粘贴图片：提示先打开项目，不读取或上传图片。
2. 剪贴板 item 为空或无法转成 File：提示剪贴板图片不可用。
3. MIME 不支持：提示支持的图片格式。
4. 上传失败、权限问题、hash 失败、资产文件丢失：沿用 `/api/assets/upload` 的错误，并保留输入文本。
5. 重复粘贴同一图片：复用 asset，reference 列表不重复加入同一 asset id。
6. 上传未完成时点击发送：禁用发送或只发送已完成引用，行为必须明确且不会丢失 pending 图片。

验证重点：

1. 在 CodeMirror 中粘贴文本仍然正常。
2. 粘贴系统截图后 composer 出现缩略图，资产进入项目 `work/`。
3. 粘贴同一图片两次不会重复创建 asset 文件，也不会重复显示同一引用。
4. 删除缩略图后发送，消息不带该图片引用。
5. 带粘贴图片发送后，user item payload 有对应 `asset_ids`，Runner 能解析出图片路径。
6. 上传失败时 prompt 和已完成引用不丢失。
7. 只做开发验证，不主动运行前端生产 build。

## prds

完成实现后同步更新：

1. `docs/prds/features/turns/001-聊天输入与消息展示.md`：补充 Composer 支持剪贴板图片粘贴，以及上传中/错误状态。
2. `docs/prds/features/turns/002-图片引用与上传.md`：把剪贴板粘贴列为图片引用来源，说明它复用聊天区上传并保存到 `work/`。
3. `docs/prds/features/assets/001-资产导入扫描与去重.md`：如实现中区分 `source=paste`，同步补充来源枚举；否则说明粘贴归入 `upload`。
