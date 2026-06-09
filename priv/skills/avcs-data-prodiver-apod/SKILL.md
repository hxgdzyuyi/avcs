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
2. 在 AvcsAgent 中调用受控 `bash` tool，而不是手动执行 shell 命令。
3. 读取 `bash` tool result 中的 provider JSON 摘要。
4. 若 `status == success`：
   - 使用 `image_path` 作为图片路径。
   - 使用 `title`、`date`、`explanation`、`copyright` 做基础文本说明。
5. API 调用失败（含 key 失效/配额问题）时自动切换到网页抓取（`web_scrape`）。
6. 将文件先存入 `work/`（临时），确认用途后再转入 `output/`。

## AvcsAgent 调用

```json
{
  "command_kind": "data_provider",
  "provider": "avcs-data-prodiver-apod",
  "args": {
    "date": "YYYY-MM-DD"
  }
}
```

- `--date`：可选，ISO 日期（如 `2026-06-01`）。不传时使用 API 默认（通常是最新一条）。
- `bash` tool 由 Phoenix 后端运行内置 `scripts/fetch_apod.py`，不是任意 shell。
- `--out-dir` 由 Avcs 后端固定为当前项目 `work/`，模型不要自行传本地路径。
- API key 不通过 tool arguments 传递；脚本默认使用 `DEMO_KEY`。
- 默认下载 APOD 普通图片 URL；只有明确传入 `args.prefer_hd: true` 时才使用 `--prefer-hd`。

底层脚本路径仅供审计和本地维护：

```text
priv/skills/avcs-data-prodiver-apod/scripts/fetch_apod.py
```

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
- `DEMO_KEY` 是默认值，可能受限于调用配额；不要把 API key 放入 tool arguments、日志、trace 或文档示例。
- 不支持强行下载 `work/` 以外目录；AvcsAgent `bash` provider 只能把来源图片落入当前项目 `work/`，再由后续 `image_gen` 生成 `output/` 资产。
- `bash` 是 Avcs 受控 provider 工具，不支持 `/bin/sh -c`、管道、重定向或任意命令字符串。
