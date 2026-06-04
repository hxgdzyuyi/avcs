# Steam App Search/Details Notes

- 查询链路：
  1. 按游戏名调用 `storesearch`：`https://store.steampowered.com/api/storesearch/`
  2. 从 `items` 中读取 `id`/`appid`。
  3. 调用 `appdetails`：`https://store.steampowered.com/api/appdetails/?appids=<appid>`。
- 常见封面字段：
  - `header_image`
  - `capsule_image`
  - `capsule_imagev5`
  - `small_capsule`
  - `large_capsule`
  - `screenshots[]` 的 `path_thumbnail` / `path_full`
- 常见元信息字段：
  - `name`, `steam_appid`, `short_description`, `detailed_description`
  - `is_free`, `release_date.date`, `genres`, `categories`, `developers`, `publishers`
- 注意：Steam 非官方接口偶发限流；失败时应返回明确 `reason` 与错误信息，不吞掉错误。
