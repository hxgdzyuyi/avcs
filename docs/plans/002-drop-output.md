---
git_commit_message: 'feat: support copying work assets to output'
plan_state: finished
---
# 002 Drop Work 图片到 Output

## current_status

原需求：Board 中拖拽图片到 Output 松开后，自动复制导入到 `output/` 文件夹，并在 Output 中显示。

当前实现：

1. `work/` 图片只作为 asset 展示在 Board 的 Work tab，不创建 `board_items`。
2. `output/` 图片会通过 `Avcs.Assets.upsert_asset/3` 自动创建或恢复 `board_items`。
3. `Avcs.Board.list_items/1` 只返回 `assets.relative_path LIKE 'output/%'` 的有效画板对象。
4. `assets.hash` 在项目 SQLite 内唯一，不能为同一张图同时创建 Work asset 和 Output asset 两条记录。
5. 前端已有 Output / Work tab，但 Work asset row 还不能拖拽，Output 也没有 drop target。
6. Phoenix HTTP API 还没有“把已有项目 asset 复制/提升到 output”的入口。

## overview

实现 Work 图片到 Output 画板的手动提升：

1. 用户在 Work tab 拖拽图片到 Output tab 或 Output 画板区域。
2. 前端只提交 `asset_id` 和可选 drop 坐标，不直接复制文件、不拼接本地路径。
3. 后端校验 asset 属于当前项目、文件存在、不是 mask asset。
4. 后端把图片复制到 `<project>/output/`，并把该 asset 的 canonical 路径更新为 `output/...`。
5. 后端创建或恢复对应 `board_item`，通过现有 asset / board 事件刷新前端。
6. 前端切换到 Output，选中新建或恢复的画板对象并聚焦到可见区域。

在当前 hash 唯一约束下，拖入 Output 后该图片不再作为 Work asset 展示；旧 `work/` 文件即使仍存在，也不新增第二条 asset 记录。如果后续要求 Work 与 Output 同时保留同一 hash 的可见资产，需要先改为 `asset_locations` 一类多文件位置模型，本计划不扩展该数据模型。

## data_model

不新增表。

复用现有表：

1. `assets`：更新目标 asset 的 `file_path`、`relative_path`、`file_name`、`source`、`updated_at`；保留 `hash` 唯一约束。
2. `board_items`：为提升后的 output asset 创建或恢复唯一画板对象。
3. `asset_links`：保留原有关联；本次手动提升不强制绑定 thread / turn / item。

新增后端能力建议：

1. `Avcs.Assets.copy_to_output(project, asset_id, opts \\ [])`。
2. `relative_path` 已是 `output/%` 时不重复复制，只确保 board item 存在并返回。
3. `relative_path` 是 `work/%` 时复制文件到 `Avcs.Projects.output_dir(project)`，目标文件名沿用当前 hash 命名策略避免覆盖。
4. 复制后在同一事务中更新 asset canonical 路径，并调用现有 output board item 创建逻辑。
5. 可选 `opts[:x]` / `opts[:y]` 用于 drop 到画板时指定初始位置；未提供时沿用当前自动排布。
6. `source` 建议使用 `manual_output` 或 `output_copy`，避免误标为 Agent 生成图。

错误边界：

1. asset 不存在。
2. asset 文件缺失。
3. asset 不在当前项目内。
4. mask asset 不允许提升到 Output。
5. 图片格式不支持或 hash / stat 读取失败。
6. 复制到 `output/` 或写 SQLite 失败。

## api

新增 Phoenix HTTP API：

```http
POST /api/assets/:id/copy_to_output
```

请求：

```json
{ "x": 120.0, "y": 80.0 }
```

`x`、`y` 可省略；字段为 Output 画板世界坐标。

成功响应：

```json
{
  "success": true,
  "data": {
    "asset": {},
    "board_item": {}
  }
}
```

失败响应沿用统一响应信封，建议错误码：

1. `asset_not_found`
2. `asset_not_copyable`
3. `asset_file_missing`
4. `asset_copy_to_output_failed`

Controller 成功后广播：

1. `assets:updated`
2. `board:items`

如果后续需要更细粒度增量事件，可补充 `board:item:created`；当前前端已经能消费全量 `board:items`。

## ui

前端改动：

1. `web/src/api.js` 增加 `copyAssetToOutput(id, placement)`。
2. `App.jsx` 增加 `handleCopyAssetToOutput(assetId, placement)`，成功后刷新或依赖广播同步 `assets` / `boardItems`。
3. `BoardPane.jsx` 的 `WorkAssetList` 支持拖拽 Work asset row。
4. Output tab 和 Output 画板区域支持 `dragover` / `drop`。
5. 拖拽悬停 Output tab 时切换到 Output；落在画板区域时把屏幕点换算成世界坐标传给 API。
6. 落在 Output tab 或非画板区域时不传坐标，由后端自动排布。
7. 请求期间显示轻量 drop / busy 状态，失败时通过现有 notice 展示错误。
8. 成功后选中新建或恢复的 board item，并触发 `fit_if_outside` 聚焦。
9. Work row 可保留一个图标按钮作为非拖拽 fallback，调用同一 `copyAssetToOutput` 动作。

i18n 需要新增或复用文案：

1. `board.copy_to_output`
2. `board.drop_to_output`
3. `app.image_copied_to_output`

## others

测试重点：

1. `Avcs.Assets.copy_to_output/3`：Work asset 复制到 `output/`、更新 canonical 路径、创建 board item。
2. 已是 Output asset 时幂等返回，不重复创建文件或 board item。
3. 相同 hash 不新增第二条 asset 记录。
4. mask asset、缺失文件、越界路径返回明确错误。
5. HTTP API 响应符合统一信封，并在成功后广播 `assets:updated` / `board:items`。
6. 前端 drop 到 Output tab、drop 到 Output canvas、API 失败回退的交互验证。

## prds

完成实现后更新：

1. `docs/prds/features/assets/001-资产导入扫描与去重.md`：补充 Work asset 可手动提升为 Output asset，以及 hash 唯一约束下 canonical 路径迁移规则。
2. `docs/prds/features/board/001-画板自由布局.md`：补充 Work tab 拖拽到 Output 的交互。
3. `docs/prds/features/board/002-画板对象选择移动与缩放.md`：补充成功后选中和聚焦 Output board item。
4. `docs/prds/features/web/001-Phoenix本地文件API.md`：补充 `POST /api/assets/:id/copy_to_output`。
5. 必要时同步 `docs/prds/overview.md` 的资产与画板闭环描述。
