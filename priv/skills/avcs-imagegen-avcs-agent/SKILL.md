---
name: avcs-imagegen-avcs-agent
description: AvcsAgent 在 Avcs 项目中生成或编辑光栅图片资产时使用。只使用 Avcs 后端 image_gen tool；支持文生图、reference_asset_ids 参考图、mask_asset_id PNG mask edit 和常用 OpenAI image options。
---

# AvcsAgent 图片生成 Skill

用于 AvcsAgent 通过 Phoenix 后端 `image_gen` tool 在当前 Avcs 项目中生成或编辑图片资产。

## 顶层规则

- 当前 harness 是 AvcsAgent 时，图片生成只使用 Avcs 后端 `image_gen` tool。
- 不要调用 Codex built-in `image_gen`、CLI、SDK、OpenAI API、自定义脚本生成器或其它模型调用路径。
- AvcsAgent `image_gen` 支持文生图；仅当当前图片模型传输方式支持参考图时，才通过 `reference_asset_ids` 把当前项目图片 asset 作为视觉参考输入。
- AvcsAgent `image_gen` 在当前图片模型传输方式支持参考图时，支持通过 `mask_asset_id` 对第一张参考图执行 PNG mask edit；mask 必须是当前项目内带 alpha 通道的 PNG asset。
- 默认 Vercel AI Gateway 下，`openai/gpt-image-*`、DALL-E、Imagen、Flux 和 Grok image 等 image-only 模型走 `/images/generations` 文生图，不走 `/chat/completions` 参考图；Google Gemini image 等多模态图片输出模型按 Vercel 文档走 `/chat/completions`、`modalities: ["image"]`，有参考图时再用 data URL `image_url` 发送项目图片。
- 非 Vercel OpenAI-compatible base URL 下，参考图和 mask 可走 OpenAI Images API `/images/edits` multipart `image[]` / `mask`。
- 如有 APOD 或其它 data provider 图片结果，当前图片模型支持参考图时把 provider 返回的图片 `asset_id` 放入 `reference_asset_ids`；当前模型只支持文生图时，把 provider 摘要写入 prompt 后不传参考图。
- `gpt-image-2` 不支持 `background: "transparent"`；正式 variation 和 streaming partial images 暂不支持。
- 生成文件由 Phoenix 后端写入当前项目 `output/`，并入库为 asset、chat item 和 board item。
- 不要将图片任务转成 HTML/CSS/DOM/SVG/Canvas/WebGL 页面、模板或代码产物。
- 不要为了生成图片而创建 HTML 文件，也不要通过 Chrome、Chromium、Playwright、Puppeteer、browser、chrome-devtools 或浏览器截图流程把 HTML/网页渲染成 PNG/JPEG/WebP。

## Tool 参数

`image_gen` 常用参数：

```json
{
  "prompt": "string",
  "aspect_ratio": "string",
  "size": "1024x1024",
  "quality": "low | medium | high | auto",
  "output_format": "png | jpeg | webp",
  "output_compression": 80,
  "background": "auto | opaque | transparent",
  "moderation": "auto | low",
  "count": 1,
  "reference_asset_ids": ["asset-id"],
  "mask_asset_id": "asset-id"
}
```

使用要求：

- `prompt` 必填。
- `count` 默认 1，最大 4。
- `aspect_ratio` 只在未显式传 `size` 时映射为常用尺寸。
- `mask_asset_id` 必须和至少一张 `reference_asset_ids` 一起使用。
- `output_compression` 只对 `jpeg` 和 `webp` 有效。
- `background: "transparent"` 在默认 `gpt-image-2` 下会被后端拒绝。

## Data Provider 图片

当本轮有 APOD 或其它 data provider：

1. 先按 provider skill 调用受控 `bash` data provider descriptor。
2. 如果 provider 返回 `provider_status == "success"` 且 summary 中有图片 `asset_id`，当前图片模型支持参考图时后续 `image_gen` 传：

```json
{
  "reference_asset_ids": ["<provider image asset_id>"]
}
```

3. 如果当前图片模型只支持文生图，不传 `reference_asset_ids`，但必须把 provider 的标题、日期、说明、来源 URL、版权和其它关键摘要写入 prompt。
4. 提示词中同时写入 provider 的标题、日期、说明、来源 URL、版权和其它关键摘要。
5. 如果 provider 返回 `not_available` 或 `failed`，报告状态和原因，不要编造来源数据。

## 工作流

1. 明确目标：生成、参考图变体，还是 mask edit。
2. 明确图片用途：画板、聊天引用、项目输出、前端页面资产或其它用途。
3. 收集必要输入：提示词、必须出现的文字、约束、避免项、参考图 asset id 和 mask asset id。
4. 对每张输入图标注角色：参考图、编辑目标、插入/合成素材或风格参考。
5. 将用户提示词整理成清晰的生产规格；用户已经写得很具体时，只做结构化，不额外添加创意要求。
6. 调用 Avcs 后端 `image_gen` tool；不要自行读写图片 API。
7. 生成结果会由后端保存到 `<project>/output/` 并入库，不要把最终交付结果保存到 `work/`。
8. 如需迭代，只做一个明确、局部的修正，再重复单次生成。

## 提示词整理

把用户需求整理为简洁的规格。只添加能明显提高结果质量的信息，不要随意加入额外角色、物体、品牌、口号、配色或故事情节。

可用结构：

```text
用途分类: <照片/产品图/海报/信息图/插画/透明背景素材等>
资产用途: <画板/聊天引用/前端页面/产品图/输出文件等>
主要请求: <用户核心需求>
输入图片: <图片 1: 角色; 图片 2: 角色>
场景/背景: <环境>
主体: <主要对象>
风格/媒介: <照片/插画/3D/像素风等>
构图/取景: <近景/广角/俯视/居中/留白等>
光线/情绪: <光照与氛围>
色彩: <配色要求>
材质/纹理: <表面细节>
文字: "<必须逐字出现的文本>"
约束: <必须保留/必须改变>
避免: <不要出现的内容>
```
