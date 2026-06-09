---
name: avcs-imagegen-codex
description: Codex Agent 在 Avcs 项目中生成或编辑光栅图片资产时使用。只使用 Codex built-in image_gen；不使用 AvcsAgent 后端 image_gen、OpenAI API、SDK、自定义脚本生成器或浏览器截图流程。
---

# Avcs Codex 图片生成 Skill

用于 Codex Agent 在 Avcs 项目中生成或编辑图片资产。

## 顶层规则

- 当前 harness 是 Codex Agent 时，图片生成与编辑只使用 Codex built-in `image_gen`。
- 不要切换到 AvcsAgent 后端 `image_gen` tool、CLI、SDK、OpenAI API、自定义脚本生成器或其它模型调用路径。
- 不要通过 Shell 探测 `image_gen`，例如 `which image_gen` 或 `command -v image_gen`。
- 如果 Codex built-in `image_gen` 不可用、失败或能力不足，直接说明限制。
- 用户要求海报、封面、信息图、广告图、带文字视觉稿或需要精确排版时，仍只调用 Codex built-in `image_gen`；如果文字准确性或排版精度超出可靠能力，直接说明限制。
- 不要将图片任务转成 HTML/CSS/DOM/SVG/Canvas/WebGL 页面、模板或代码产物。
- 不要为了生成图片而创建 HTML 文件，也不要通过 Chrome、Chromium、Playwright、Puppeteer、browser、chrome-devtools 或浏览器截图流程把 HTML/网页渲染成 PNG/JPEG/WebP。
- Codex built-in `image_gen` 返回的 `savedPath` 是生成源码路径，不是最终项目交付路径。
- 最终交付结果必须保存到当前项目 `output/`；输入素材、中间产物、抠图源和草稿放入 `work/`。
- 不要让最终交付结果停留在 `work/`、`$CODEX_HOME/generated_images/...` 或其它临时目录。

## 何时使用

- 生成新的光栅图片：照片、插画、产品图、海报、网站首图、精灵、纹理、封面、信息图。
- 基于一张或多张参考图生成风格、构图、主体或情绪相近的变体。
- 编辑现有图片：替换背景、移除对象、调整光照或天气、合成对象、风格转换、生成透明背景素材。
- 为 Avcs 画板、聊天引用、项目输出或前端原型准备图片资产。

## 何时不要使用

- 扩展已有 SVG/vector 图标、logo 系统或代码原生插画。
- 制作简单形状、流程图、线框图或可用 HTML/CSS/SVG 更稳定表达的 UI 元素。
- 修改已有可编辑源文件中的小型本地素材，例如 repo-native SVG、CSS 或 DOM 图形。
- 用户明确要求确定性的代码产物，而不是 AI 生成的位图。

## 工作流

1. 明确目标：生成或编辑。
2. 明确图片用途：预览、Avcs 画板、聊天引用、项目输出、前端页面资产或其它用途。
3. 收集必要输入：提示词、必须出现的文字、约束、避免项、参考图和编辑目标图。
4. 对每张输入图标注角色：参考图、编辑目标、插入/合成素材或风格参考。
5. 将用户提示词整理成清晰的生产规格；用户已经写得很具体时，只做结构化，不额外添加创意要求。
6. 调用 Codex built-in `image_gen` 生成或编辑。
7. 使用 built-in `image_gen` 返回的确定产物路径，不要通过 `find` 扫描目录再定位文件。
8. 将最终交付结果保存到 `<project>/output/`；把输入素材、中间产物和草稿保存到 `<project>/work/`。
9. 仅在一次性核对场景下检查一次结果：主体、风格、构图、文字准确性、保留项、避免项和 Avcs 用途是否满足。
10. 如需迭代，只做一个明确、局部的修正，再重复执行单次生成与单次核对。

## 透明背景请求

Codex Agent 的透明背景仍以 Codex built-in `image_gen` 作为唯一生成路径。由于 built-in 工具未暴露可控的原生透明背景参数，先生成纯色抠图背景版本，再用本 skill 自带脚本转为带 alpha 通道的 PNG/WebP。

默认提示词补充：

```text
在完全平整、纯色、无纹理的 #00ff00 抠图背景上生成主体。
背景必须是单一均匀颜色，不要阴影、渐变、纹理、反射、地面或光照变化。
主体与背景保持清晰分离，边缘干净，并留出充足边距。
主体中不要使用 #00ff00。
不要投影、接触阴影、反射、水印或文字，除非用户明确要求。
```

如果主体本身包含绿色，改用 #ff00ff。对于毛发、烟雾、玻璃、液体、半透明材质、强反光物体或复杂边缘，先说明 built-in 路径可能无法得到干净透明边缘。

默认处理步骤：

1. 使用 Codex built-in `image_gen` 生成纯色抠图背景图片。
2. 将生成源图保存到当前项目 `work/`，文件名建议加 `-keyed`，例如 `badge-keyed.png`。
3. 运行本 skill 自带脚本生成透明图。`<avcs-imagegen-codex-skill-dir>` 是当前 `SKILL.md` 所在目录：

```bash
python <avcs-imagegen-codex-skill-dir>/scripts/remove_chroma_key.py \
  --input <project>/work/<name>-keyed.png \
  --out <project>/output/<name>.png \
  --auto-key border \
  --soft-matte \
  --transparent-threshold 12 \
  --opaque-threshold 220 \
  --despill
```

4. 如果边缘仍有明显纯色残边，重试一次并增加 `--edge-contract 1`。
5. 验证输出文件有 alpha 通道、四角透明、主体覆盖合理、没有明显抠图颜色残边。
6. 最终项目引用 `output/` 中的透明文件，不引用 `work/` 中的 `-keyed` 源图。

脚本依赖 Pillow。如果当前环境缺少 Pillow，说明无法完成本地透明背景后处理；不要切换到 CLI、SDK、OpenAI API 或其它图片生成路径。

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
