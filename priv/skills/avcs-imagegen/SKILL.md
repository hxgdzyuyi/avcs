---
name: avcs-imagegen
description: 在 Avcs 项目中生成或编辑光栅图片资产时使用，包括照片、插画、纹理、精灵、产品图、界面概念图、透明背景素材和参考图变体。只允许使用内置 image_gen 工具生成或编辑图片，不使用 CLI、SDK、OpenAI API、自定义脚本生成器或其它模型调用路径。
---

# Avcs 图片生成 Skill

用于在 Avcs 项目中生成或编辑图片资产。图片生成与图片编辑只使用 built-in `image_gen`，不要切换到 `scripts/image_gen.py`、OpenAI API、SDK runner、外部命令行生成器或任何自定义模型服务。

## 顶层规则

- 默认且唯一的生成/编辑路径是 built-in `image_gen`。
- `image_gen` 必须通过 Codex 内置 tool 直接调用，不得通过 Shell 探测（例如 `which image_gen`、`command -v image_gen`）或进程/系统可执行路径判断。
- 如果 built-in `image_gen` 不可用、失败或能力不足，直接说明限制；不要自行改用 CLI、API、SDK 或其它模型路径。
- 用户要求批量生成时，对每个资产或变体分别调用 built-in `image_gen`；不要改用批处理 CLI。
- 用户要求透明背景时，仍先用 built-in `image_gen` 生成可处理的图片；不要改用原生透明背景 CLI/API。
- `image_gen` 通常会在返回中给出确定的产物路径（如 `ig_*.png`）。必须直接使用该路径，不要通过 `find` 扫描目录再次定位 PNG，再进行拷贝。
- 透明背景通过本 skill 自带的 `scripts/remove_chroma_key.py` 做本地像素后处理；它不是图片生成路径，可以使用。运行时从当前 `SKILL.md` 所在目录推导该脚本的绝对路径，不要假设当前工作目录是 Avcs 仓库。
- 不要创建或调用一次性图片生成脚本。
- 不要将图片生成任务转成 HTML/CSS/DOM/SVG/Canvas/WebGL 页面、模板或代码产物。
- 不要为了生成图片而创建 HTML 文件，也不要通过 Chrome、Chromium、Playwright、Puppeteer、browser、chrome-devtools 或任何浏览器截图流程把 HTML/网页渲染成 PNG/JPEG/WebP。
- 用户要求海报、封面、信息图、广告图、带文字视觉稿或需要精确排版时，仍只调用 built-in `image_gen`；如果文字准确性或排版精度超出 built-in `image_gen` 的可靠能力，直接说明限制，不要改用 HTML 排版、浏览器截图或其它渲染管线。
- `work/` 用于输入素材、引用图、待编辑图、Agent 中间产物、debug 文件、抠图源、临时生成图和草稿图。
- `output/` 只用于最终交付结果。
- 不要让最终交付结果停留在 `work/`、`$CODEX_HOME/generated_images/...` 或其它临时目录；必须保存到当前项目 `output/`，除非用户明确指定其它项目内路径。

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

## 决策流程

先判断两个问题：

1. 用户是要生成新图片，还是编辑现有图片？
2. 结果是只用于预览，还是要作为当前 Avcs 项目资产保存？

意图判断：

- 用户要求改变现有图片并保留其中部分内容时，按编辑处理。
- 用户提供图片仅作为风格、构图、主体或情绪参考时，按生成处理。
- 用户没有提供图片时，按生成处理。
- 如果本地图片文件是编辑目标，先用可用的图片查看工具检查该文件，让图片进入对话上下文，再使用 built-in `image_gen` 执行编辑。

执行判断：

- 单个资产：调用一次 built-in `image_gen`。
- 多个不同资产：为每个资产写独立提示词并分别调用 built-in `image_gen`。
- 同一资产多个变体：为每个变体分别调用 built-in `image_gen`，并在保存时使用清晰的版本化文件名。

## 工作流

1. 明确目标：生成或编辑。
2. 明确图片用途：预览、Avcs 画板、聊天引用、项目输出、前端页面资产或其它用途。
3. 收集必要输入：提示词、必须出现的文字、约束、避免项、参考图和编辑目标图。
4. 对每张输入图标注角色：参考图、编辑目标、插入/合成素材或风格参考。
5. 将用户提示词整理成清晰的生产规格；用户已经写得很具体时，只做结构化，不额外添加创意要求。
6. 使用 built-in `image_gen` 生成或编辑。
7. 获取并使用 `image_gen` 的确定产物路径（例如 `ig_*.png`）；不要通过 `find` 扫描目录再定位文件。将该路径作为本次结果唯一来源；若需重命名或移入项目目录，按用途保存到 `work/` 或 `output/`。
8. 仅在一次性核对场景下检查一次结果：主体、风格、构图、文字准确性、保留项、避免项和 Avcs 用途是否满足。
9. 如需迭代，只做一个明确、局部的修正，再重复执行单次生成与单次核对。
10. 预览用途可以直接展示图片；项目资产必须保存到当前项目内。
11. 保存项目资产时，输入素材、引用图、待编辑图、Agent 中间产物、debug 文件、抠图源、临时生成图和草稿图放入 `<project>/work/`；最终交付结果放入 `<project>/output/`；如果用户指定项目内路径，则按用户路径保存。
12. 不要覆盖已有资产，除非用户明确要求替换；否则使用 `name-v2.png`、`name-edited.png`、`name-variant-01.png` 这类文件名。
13. 不要让项目引用的图片只停留在 `$CODEX_HOME/generated_images/...` 或其它默认生成目录。
14. 最终回复要说明：使用的是 built-in `image_gen`、最终保存路径、最终提示词或提示词集合。

## 透明背景请求

透明背景也只使用 built-in `image_gen` 作为生成路径。由于 built-in 工具未暴露可控的原生透明背景参数，先生成纯色抠图背景版本，再用本 skill 自带脚本转为带 alpha 通道的 PNG/WebP。

默认提示词补充：

```text
在完全平整、纯色、无纹理的 #00ff00 抠图背景上生成主体。
背景必须是单一均匀颜色，不要阴影、渐变、纹理、反射、地面或光照变化。
主体与背景保持清晰分离，边缘干净，并留出充足边距。
主体中不要使用 #00ff00。
不要投影、接触阴影、反射、水印或文字，除非用户明确要求。
```

如果主体本身包含绿色，改用 #ff00ff。对于毛发、烟雾、玻璃、液体、半透明材质、强反光物体或复杂边缘，先说明 built-in 路径可能无法得到干净透明边缘；仍不得自行切换到 CLI/API。

默认处理步骤：

1. 使用 built-in `image_gen` 生成纯色抠图背景图片。
2. 将选中的生成源图保存到当前项目 `work/`，文件名建议加 `-keyed`，例如 `badge-keyed.png`。这是抠图源和中间产物，不是最终交付结果。
3. 运行本 skill 自带脚本生成透明图。`<avcs-imagegen-skill-dir>` 是当前 `SKILL.md` 所在目录：

```bash
python <avcs-imagegen-skill-dir>/scripts/remove_chroma_key.py \
  --input <project>/work/<name>-keyed.png \
  --out <project>/output/<name>.png \
  --auto-key border \
  --soft-matte \
  --transparent-threshold 12 \
  --opaque-threshold 220 \
  --despill
```

4. 如果边缘仍有明显纯色残边，重试一次并增加 `--edge-contract 1`。只有边缘明显锯齿且主体不是玻璃、金属或反光材质时，才少量使用 `--edge-feather 0.25`。
5. 验证输出文件有 alpha 通道、四角透明、主体覆盖合理、没有明显抠图颜色残边。
6. 最终项目引用 `output/` 中的透明文件，不引用 `work/` 中的 `-keyed` 源图；源图可保留在 `work/` 作为调试产物，也可按用户要求清理。

脚本依赖 Pillow。如果当前环境缺少 Pillow，说明无法完成本地透明背景后处理；不要切换到 CLI、SDK、OpenAI API 或其它图片生成路径。

## 提示词整理

把用户需求整理为简洁的规格。只添加能明显提高结果质量的信息，不要随意加入额外角色、物体、品牌、口号、配色或故事情节。

可用结构：

```text
用途分类: <见下方分类>
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

## 用途分类

生成类：

- `photorealistic-natural`：自然真实的照片、生活方式或编辑类场景。
- `product-mockup`：产品、包装、商品、周边和目录图。
- `ui-mockup`：应用或网页界面概念图、线框图和视觉稿。
- `infographic-diagram`：结构化信息图、图解和带文字的视觉说明。
- `scientific-educational`：教学、科学、技术和准确标签图。
- `ads-marketing`：广告、营销图和活动创意。
- `productivity-visual`：幻灯片、图表、流程和业务视觉。
- `logo-brand`：logo、标志和品牌探索图。
- `illustration-story`：故事插画、漫画和叙事画面。
- `stylized-concept`：风格化概念图、3D 渲染和艺术设定。
- `historical-scene`：历史或时代场景。

编辑类：

- `text-localization`：替换或翻译图片中文字，并保留布局。
- `identity-preserve`：保留人物身份、姿态或关键外观。
- `precise-object-edit`：移除、替换或新增指定对象。
- `lighting-weather`：只改变光照、天气、季节或氛围。
- `background-extraction`：生成纯色抠图背景或透明背景素材。
- `style-transfer`：将参考风格应用到主体或场景。
- `compositing`：多图合成、插入对象并匹配透视与光照。
- `sketch-to-render`：草图、线稿或低保真图转高保真渲染。
