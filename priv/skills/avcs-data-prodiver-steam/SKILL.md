---
name: avcs-data-prodiver-steam
description: 当用户提及某个游戏封面、游戏信息、Steam 查询等任务时，先按游戏名调用 Steam Store Search 获取 appid，再通过 appdetails 拿到游戏信息与多尺寸封面图，返回可用于 Avcs 的图片本地路径与元信息。
---

# Avcs 数据提供者 Steam Skill

## 触发场景

在以下任一场景优先调用本 Skill：

- 用户提及某个游戏名并要求抓取 Steam 封面与简介。
- 用户要求“找这个游戏的 Steam 信息”或“拿某个游戏的封面”并直接用于聊天引用或画板素材。
- 需要在生成前确认游戏元信息（评分、发行者、分类、商店链接等）时，先使用本 Skill 获取来源。

## 目标

- 获取 Steam 元数据：`name`、`appid`、`steam_appid`、`short_description`、`detailed_description`、`is_free`、`release_date`、`genres`、`categories`、`developers`、`publishers`、`platforms`、`store_url`。
- 下载可用封面到本地文件并返回标准化路径。
- 提供 `appdetails` 中可见的多尺寸封面候选（如 header 与 capsule）供上游逻辑选择。

## 标准执行流程

1. 识别用户意图为 Steam 游戏查询任务。
2. 在 AvcsAgent 中调用受控 `bash` tool，而不是手动执行 shell 命令，至少提供 `args.game`。
3. 读取 `bash` tool result 中的 provider JSON 摘要。
4. 若 `status == success`：
   - 使用 `image_path` 作为图片路径。
   - 使用 `name`、`appid`、`short_description`、`store_url` 做基础文本说明。
4. 将文件先存入 `work/`（临时），确认用途后再转入 `output/`。

## AvcsAgent 调用

```json
{
  "command_kind": "data_provider",
  "provider": "avcs-data-prodiver-steam",
  "args": {
    "game": "Portal 2",
    "lang": "en-us",
    "cc": "US",
    "cover_key": "header_image"
  }
}
```

- `args.game`：必填，游戏名称或关键词。
- `args.lang`：可选，Steam 接口语言，默认 `en-us`。
- `args.cc`：可选，国家/地区码，默认 `US`。
- `args.cover_key`：可选，优先下载封面类型，默认 `header_image`。
- `bash` tool 由 Phoenix 后端运行内置 `scripts/fetch_steam.py`，不是任意 shell。
- `--out-dir` 由 Avcs 后端固定为当前项目 `work/`，模型不要自行传本地路径。

底层脚本路径仅供审计和本地维护：

```text
priv/skills/avcs-data-prodiver-steam/scripts/fetch_steam.py
```

## 返回 JSON 结构

成功返回示例：

```json
{
  "status": "success",
  "data": {
    "game": "Portal 2",
    "appid": 620,
    "cover_key": "header_image",
    "store_url": "https://store.steampowered.com/app/620/Portal_2/",
    "name": "Portal 2",
    "short_description": "...",
    "detailed_description": "...",
    "developers": ["Valve"],
    "publishers": ["Valve"],
    "is_free": false,
    "release_date": "2011-04-18",
    "genres": ["解谜"],
    "categories": ["单人", "多人"],
    "cover_images": {
      "header_image": "https://cdn.akamai.steamstatic.com/steam/apps/620/header.jpg",
      "capsule_image": "https://cdn.akamai.steamstatic.com/steam/apps/620/capsule_231x87.jpg",
      "capsule_imagev5": "https://cdn.akamai.steamstatic.com/steam/apps/620/capsule_184x69.jpg"
    },
    "image_path": "/absolute/path/work/steam-620-portal-2-header_image.jpg",
    "image_url_used": "https://cdn.akamai.steamstatic.com/steam/apps/620/header.jpg"
  },
  "reason": null,
  "error": null
}
```

失败/未找到场景：

```json
{
  "status": "not_available",
  "reason": "no_appid",
  "error": null,
  "data": {
    "game": "unknown game",
    "search_status": "not found",
    "storesearch_url": "https://store.steampowered.com/api/storesearch/?term=..."
  }
}
```

当接口查询或下载都失败时：

```json
{
  "status": "failed",
  "reason": "request_failed",
  "error": "...",
  "data": {
    "storesearch_url": "https://store.steampowered.com/api/storesearch/?term=..."
  }
}
```

## 说明与边界

- `storesearch` 可能返回多个候选时优先第一个结果；如需更精确可将具体名称补全后重试。
- `appdetails` 未返回某些字段时返回空值，不做硬性失败。
- 如果目标尺寸封面不存在，会在返回中说明 `available_cover_keys` 并选择其一兜底下载。
- 不支持强制从用户本地文件系统直接读取图片；AvcsAgent `bash` provider 只能把下载封面落入当前项目 `work/`，再由后续 `image_gen` 生成 `output/` 资产。
- `bash` 是 Avcs 受控 provider 工具，不支持 `/bin/sh -c`、管道、重定向或任意命令字符串。
