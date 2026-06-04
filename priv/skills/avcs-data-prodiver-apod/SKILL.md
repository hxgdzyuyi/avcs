---
name: avcs-data-prodiver-apod
description: 当用户提及 APOD 内容时，抓取 NASA Astronomy Picture of the Day 的条目信息并下载对应图片，返回可用于 Avcs 的图片本地路径、标题、日期、说明文本与版权字段，作为画板素材或聊天引用的基础输入。
---

# Avcs 数据提供者 APOD Skill

## 触发场景

在以下任一场景优先调用本 Skill：

- 用户提及 `APOD`、`astronomy picture of the day`、`NASA 每日天文图`，并要求抓取图片与说明。
- 用户要求“下载今天/某天 APOD”或“给我 APOD 图片和简介”。
- 需要从 APOD 条目取基础文本（标题、日期、说明、版权）并进入项目素材流程。

## 目标

- 获取 APOD 元数据：`title`、`date`、`explanation`、`copyright`、`media_type`、`url`。
- 下载图片到本地文件并返回标准化路径。
- 对 `media_type != image` 的条目给出可执行说明与失败原因。

## 标准执行流程

1. 识别用户意图为 APOD 任务。
2. 调用脚本 `scripts/fetch_apod.py`。
3. 读取 JSON 返回。
4. 若 `status == success`：
   - 使用 `image_path` 作为图片路径。
   - 使用 `title`、`date`、`explanation`、`copyright` 做基础文本说明。
5. API 调用失败（含 key 失效/配额问题）时自动切换到网页抓取（`web_scrape`）。
6. 将文件先存入 `work/`（临时），确认用途后再转入 `output/`。

## 脚本调用

```bash
cd <项目根目录>
python priv/skills/avcs-data-prodiver-apod/scripts/fetch_apod.py \
  --out-dir <输出目录> \
  [--date YYYY-MM-DD] \
  [--api-key <NASA_API_KEY>] \
  [--prefer-hd]
```

- `--date`：可选，ISO 日期（如 `2026-06-01`）。不传时使用 API 默认（通常是最新一条）。
- `--api-key`：可选。未传时使用 `DEMO_KEY`。
- `--out-dir`：可选，默认 `<当前工作目录>/work`（与 `thread-runtime-instructions.md` 的临时目录约定一致）。
- `--prefer-hd`：可选，优先下载 `hdurl`（仅 API 路径）；网页抓取路径直接抓取页面主图。

## 返回 JSON 结构

成功返回示例：

```json
{
  "status": "success",
  "data": {
    "date": "2026-06-01",
    "title": "APOD title",
    "explanation": "...",
    "copyright": "NASA",
    "media_type": "image",
    "source": "api",
    "api_url": "https://api.nasa.gov/planetary/apod?...",
    "url": "https://apod.nasa.gov/apod/asterix.html",
    "apod_url": "https://apod.nasa.gov/apod/asterix.html",
    "image_path": "/absolute/path/work/apod-2026-06-01-title.jpg",
    "image_url_used": "https://.../hd.jpg"
  },
  "reason": null,
  "error": null
}
```

失败/不可下载场景：

```json
{
  "status": "not_available",
  "reason": "media_type_is_video",
  "error": null,
  "data": {
    "date": "2026-06-01",
    "title": "...",
    "explanation": "...",
    "copyright": "...",
    "media_type": "video",
    "source": "api",
    "api_url": "https://api.nasa.gov/planetary/apod?...",
    "url": "https://apod.nasa.gov/apod/..."
  }
}
```

当 API 与网页抓取都失败时：

```json
{
  "status": "failed",
  "reason": "api_and_web_failed",
  "error": "...",
  "data": {
    "api_url": "https://api.nasa.gov/planetary/apod?..."
  }
}
```

## 说明与边界

- `media_type=video` 时返回元数据，不下载视频。
- 网页抓取失败会回退失败；当 API 可用时仍优先使用 API 结果。
- `DEMO_KEY` 是默认值，但可能受限于调用配额，频繁请求建议用户提供 `api_key`。
- 不支持强行下载 `work/` 以外目录；如需交付，先落 `work/` 再移动到 `output/`。
