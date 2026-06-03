# 010 Phoenix 本地文件 API

状态：Draft  
领域：`lib/avcs_web/controllers`

## 1. 目标

所有本地文件系统操作都通过 Phoenix HTTP API 进入后端。React 不直接读写本地文件系统，不依赖 Chromium File System Access API，也不直接拼接本地文件路径读取图片。

## 2. 统一响应信封

新增 JSON API 时，默认使用统一响应信封，字段使用 `snake_case`。

成功响应：

```json
{ "success": true, "data": {} }
```

失败响应：

```json
{ "success": false, "data": null, "error": { "code": "...", "message": "...", "details": "..." } }
```

列表响应的 `data` 使用：

```json
{ "items": [] }
```

单对象响应的 `data` 直接返回对象，不额外包 `{ "item": ... }`。

## 3. API 能力

MVP 建议覆盖：

1. 新建空白项目：`POST /api/project/create_blank` 接收项目名 `{ "name": "Project Name" }`，在全局软件设置 `projects.default_root` 下创建不重名的项目文件夹，初始默认值为 `~/Documents/Avcs`，初始化 `<project>/.avcs/project.sqlite3`、`<project>/work/` 和 `<project>/output/`，并更新 `~/.avcs/avcs.sqlite3`。
2. 打开或初始化现有项目文件夹：`POST /api/project/open` 接收本地绝对路径 `{ "path": "/absolute/project/folder" }`，创建或复用项目目录结构，并更新 `~/.avcs/avcs.sqlite3`。
3. 导入图片：接收用户指定的本地图片路径，将文件复制到 `<project>/work/`，计算 hash 去重并写入项目 SQLite。
4. 聊天区上传图片：接收浏览器 multipart 上传的图片文件，将文件保存到 `<project>/work/`，计算 hash 去重并写入项目 SQLite，返回可加入聊天输入区引用列表的 asset。
5. 扫描项目图片：默认扫描 `<project>/work/` 和 `<project>/output/` 内允许的图片格式，计算 hash 去重，新增缺失的 asset 记录。
6. 读取图片预览：通过受控 HTTP 路由返回项目资产文件。
7. 打开所在文件夹或复制路径：由后端校验 asset 属于当前项目后执行系统操作或返回规范化路径。

## 4. 路径和权限边界

文件 API 需要做路径规范化和权限边界校验。

空白项目创建入口不接收完整本地路径，只接收项目名；后端在全局软件设置 `projects.default_root` 下创建项目目录，初始默认值为 `~/Documents/Avcs`。同名目录自动递增为 `<项目名> 2`、`<项目名> 3`。

除打开项目和导入源文件的入口外，所有文件操作都必须限制在：

1. 当前项目文件夹内。
2. 明确导入的源文件路径范围内。

后端不能接受前端任意本地路径并直接读取或返回。

## 5. 与 WebSocket 的关系

文件 API 完成后，由 Elixir 写入项目 SQLite，并通过 WebSocket 推送状态变更。例如：

1. 导入成功后推送 `asset:created`、`assets:updated`。
2. 上传成功后推送 `asset:referenced`。
3. 扫描成功后推送 `assets:updated`。
4. 生成或导入资产创建画板对象后推送 `board:item:created`。

## 6. 开发代理

Phoenix 作为统一访问入口，开发端口使用 `9500`。Vite dev server 独立运行，开发端口使用 `9501`。

开发环境中，Phoenix 将 `/web/*` 下的前端请求反向代理到 Vite dev server，以保留 Vite HMR。生产或打包环境中，Vite 构建产物输出到 `priv/static/assets/web/`，由 Phoenix 通过 `Plug.Static` 服务静态资源。

Vite 配置使用 `base: "/web/"`，构建开启 manifest，后端通过 manifest 找到入口 JS/CSS。

开发时需要代理 Vite 相关路径，例如 `/web/@vite`、`/web/@react-refresh`、`/web/src`、`/web/node_modules`、`/web/@id`、`/web/@fs`。

## 7. 错误处理

需要覆盖：

1. 空白项目名称为空或包含不允许的路径字符。
2. 使用现有文件夹时路径不是绝对路径。
3. 路径不存在。
4. 路径越界。
5. 文件格式不支持。
6. 文件过大。
7. 读写权限不足。
8. hash 计算失败。
9. 预览读取失败。
10. Vite dev server 未启动时，Phoenix 代理返回明确错误。

## 8. 验收标准

1. React 不依赖 Chromium File System Access API。
2. 所有本地文件操作都通过 Phoenix API 完成。
3. API 响应符合统一响应信封。
4. 图片预览通过受控 HTTP 路由返回。
5. 新建空白项目创建到全局软件设置 `projects.default_root` 下，初始默认值为 `~/Documents/Avcs`，且同名目录自动递增。
6. 除打开项目和导入源文件入口外，文件操作不能越过当前项目边界。
7. 开发环境可以通过 `http://localhost:9500/web` 访问前端。
