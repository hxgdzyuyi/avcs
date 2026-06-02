---
git_commit_message: 'desktop: plan mac silicon tauri packaging'
plan_state: finished
---
# macOS Apple Silicon Tauri 桌面包实施计划

## current_status

Avcs 当前是 Phoenix 承载的本地 Web 应用，前端由 `web/` 下的 React + Vite 构建到 `priv/static/assets/web`，根路径 `/` 会跳转到 `/web/`。

当前桌面打包前置状态：

1. 还没有 `rel/app/`、`src-tauri/` 或桌面 app 入口脚本。
2. `mix.exs` 还没有 `MIX_TARGET=app` 对应的 release 配置。
3. `config/runtime.exs` 的 prod release 默认要求 `DATABASE_PATH` 和 `SECRET_KEY_BASE`，这适合服务器部署，但不适合本地桌面 app。
4. `Avcs.Projects.global_db_path/0` 已默认使用 `~/.avcs/avcs.sqlite3` 保存全局项目索引，项目业务数据仍在 `<project>/.avcs/project.sqlite3`。
5. 当前没有 `.github/workflows/`，需要新增只编译 macOS Apple Silicon 的 workflow。

从 Livebook 参考到的关键做法：

1. `rel/app/tauri.sh` 设置 `MIX_TARGET=app`，先执行 `mix release app --overwrite --path rel/app/src-tauri/rel-${os}`。
2. Tauri build 通过 `--config '{"bundle":{"resources":{"rel-darwin":"rel"}}}'` 把 Elixir release 作为 app resource 打进 `.app`。
3. `.github/workflows/release.yml` 的 macOS Apple Silicon 目标是 `macos-15` + `aarch64-apple-darwin`。
4. Livebook 的 Apple 证书安装步骤只有在 P12 secret 存在时才运行，但正式 release 还会向 Tauri action 传入签名、公证和 updater 相关 secret。
5. Livebook 的 Tauri Rust 代码负责启动打包进 resource 的 Elixir release，并在 app 生命周期结束时退出后台进程。

Avcs 只实现 macOS Apple Silicon 编译，不实现 Windows、Linux、Intel macOS、自动更新、P12 签名、公证或正式发布 release。

实现过程中如果遇到不明确的 Tauri、release 或 workflow 细节，优先参考 `/Users/qingyang/project/collection-elixir/livebook/` 中的代码实现。

## overview

新增一个最小 Tauri 桌面壳，职责只包括：

1. 打包 Avcs 的 Phoenix release。
2. 启动本地 Phoenix 服务。
3. 打开 Tauri WebView 窗口访问 `http://127.0.0.1:<port>/`。
4. app 退出时关闭 Phoenix release 子进程。

核心边界：

1. React 仍然只通过 Phoenix HTTP API 和 WebSocket 与后端通信。
2. React 不直接调用 Tauri、SQLite、Codex app-server 或本地文件系统。
3. Codex app-server 仍由 Avcs 后端按既有 `Avcs.Agent` 封装启动。
4. 桌面 app 不改变项目目录结构，继续使用 `work/`、`output/` 和项目 SQLite。
5. 前端生产构建只在桌面打包脚本和 CI 中运行；日常开发仍使用 Vite dev server。

目标产物：

```text
rel/app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Avcs.app
```

CI 产物可以上传 zip：

```text
Avcs-macos-aarch64.app.zip
```

因为没有 P12，产物是未公证的本地构建包。它可以用于本机开发验证，但不作为面向普通用户的正式分发包。

## release_runtime

新增 `MIX_TARGET=app` 的 release 配置。

`mix.exs` 调整：

1. 增加 `releases/0`，定义 `app` release。
2. `app` release 使用 `include_erts: true`，只面向 `:unix` 可执行脚本，避免依赖用户机器预装 Erlang/Elixir。
3. `rel_templates_path` 指向 `rel/app`。
4. 不引入 Livebook 的 `standalone.exs` 和 `ElixirKit.Release.codesign/1`，先使用 Mix release 自带 ERTS。
5. 不新增 TypeScript、Tailwind 或前端构建体系。

建议 release 配置形态：

```elixir
releases: [
  app: [
    include_erts: true,
    include_executables_for: [:unix],
    rel_templates_path: "rel/app"
  ]
]
```

`rel/app/env.sh.eex` 需要设置桌面运行所需环境：

1. `PHX_SERVER=true`，确保 Phoenix Endpoint 在 release 中启动。
2. `AVCS_DESKTOP=true`，供 `runtime.exs` 区分桌面 release 和服务器 prod release。
3. `RELEASE_DISTRIBUTION=none`，避免本地桌面启动分布式节点。
4. `RELEASE_MODE=interactive`，方便本地日志和退出行为。
5. `RELEASE_COOKIE` 默认生成随机值，避免不同机器共享 cookie。

`config/runtime.exs` 调整：

1. 当 `AVCS_DESKTOP=true` 时，不要求外部传入 `DATABASE_PATH`。
2. 桌面 app 的 Endpoint 只绑定 `127.0.0.1`，端口读取 `PORT`，由 Tauri 启动时注入。
3. 桌面 app 的 `secret_key_base` 从 `~/.avcs/desktop_secret_key_base` 读取；文件不存在时生成并持久化。
4. 桌面 app 的 Repo 数据库不要写入项目业务数据。由于当前 `Avcs.Repo` 没有业务 schema，可指向 `~/.avcs/runtime.sqlite3`，并在 `Avcs.Application.skip_migrations?/0` 中跳过 desktop release 的 Ecto migrator。
5. 服务器 prod release 继续沿用现有 `DATABASE_PATH` 和 `SECRET_KEY_BASE` 约束。

`Avcs.Application` 调整：

1. `AVCS_DESKTOP=true` 时跳过 Ecto migrator，避免桌面启动时向全局项目索引库写入无关迁移元数据。
2. app 退出时不额外清理 `~/.avcs`，保持 local-first 数据。

## tauri_app

新增目录：

```text
rel/app/
  README.md
  env.sh.eex
  tauri.sh
  vm.args.eex
  src-tauri/
    Cargo.toml
    build.rs
    tauri.conf.json
    App.entitlements
    capabilities/default.json
    icons/
    src/
      main.rs
      lib.rs
```

`rel/app/tauri.sh` 借鉴 Livebook，但只支持 macOS Apple Silicon：

1. 设置 `MIX_TARGET=app`。
2. 检查 `uname -s` 必须是 `Darwin`。
3. 默认 target 是 `aarch64-apple-darwin`，如果本机不是 arm64 或传入其它 target，直接报错。
4. 在 `web/` 下执行 `npm ci` 和 `npm run build`，生成 `priv/static/assets/web`。
5. 在项目根目录执行 `mix deps.get` 和 `mix release app --overwrite --path rel/app/src-tauri/rel-darwin`。
6. 执行 `cargo tauri build --target aarch64-apple-darwin --bundles app`。
7. 通过 Tauri config override 把 `rel-darwin` 打包为 resource `rel`。
8. `app` 命令在 build 后打开 `.app` 进行本地验证。

Tauri config：

1. `productName` 使用 `Avcs`。
2. `identifier` 使用稳定 bundle id，例如 `dev.avcs.Avcs`。
3. `bundle.targets` 只保留 `["app"]`。
4. `bundle.createUpdaterArtifacts` 设为 `false`。
5. `bundle.macOS.signingIdentity` 保持 `null`。
6. 不配置 Apple notarization，不读取 `APPLE_CERTIFICATE_*`、`APPLE_ID`、`APPLE_PASSWORD`、`APPLE_TEAM_ID`。
7. `app.windows` 可以为空，由 Rust 在 Phoenix ready 后创建窗口；这样窗口 URL 可以使用动态端口。

Rust 启动逻辑：

1. app setup 时绑定 `127.0.0.1:0` 获取可用端口，释放后把端口写入 `PORT` 环境变量传给 release。
2. 从 `app.path().resource_dir()/rel` 定位 release。
3. 启动 `rel/bin/avcs start`，并设置：
   - `AVCS_DESKTOP=true`
   - `PHX_SERVER=true`
   - `PORT=<selected_port>`
4. 轮询 `GET http://127.0.0.1:<port>/api/health`，ready 后创建主窗口并加载 `http://127.0.0.1:<port>/`。
5. 记录 stdout/stderr 到 Tauri 日志或 `~/Library/Logs/Avcs/avcs.log`。
6. app 退出、窗口关闭或 release 子进程异常退出时，终止另一侧进程，避免残留 `beam.smp`。

Tauri 能力边界：

1. 前端不使用 Tauri IPC，所以 capabilities 保持最小。
2. 如后续要让窗口调用 Tauri API，再按具体功能添加权限。
3. 不在 Tauri 内实现文件导入、打开目录、复制路径等业务能力，这些仍由 Phoenix API 处理。

## api

新增一个轻量健康检查 API，用于 Tauri 等待 Phoenix ready。

路由：

```text
GET /api/health
```

响应遵守现有 JSON API 信封：

```json
{ "success": true, "data": { "status": "ok" } }
```

该 API 不读取项目、不访问 Codex app-server、不触发文件扫描，只确认 Phoenix Endpoint 已经可响应请求。

其它 API 和 WebSocket 事件不变。

## signing

当前没有 P12 签名证书，所以实施边界如下：

1. 不新增 P12 secret。
2. 不做 Apple notarization。
3. 不验证 `spctl -a -t exec -vvv` 作为通过标准，因为未公证 app 会失败。
4. 不上传 GitHub Release 作为正式下载产物。
5. CI 只上传构建 artifact。

本地启动限制：

1. 下载 CI artifact 后，macOS 可能提示 unidentified developer。
2. 这是无 P12 和无 notarization 的预期结果，不是编译失败。
3. 如本机启动需要 ad-hoc signing，可在 `tauri.sh` 中增加可选步骤：

```shell
codesign --force --deep --sign - rel/app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Avcs.app
```

该步骤只用于本地可运行性，不等价于 Developer ID 签名，也不能替代 notarization。

`App.entitlements` 可先保留 Livebook 类似的 BEAM 运行必需项：

1. `com.apple.security.cs.allow-jit`
2. `com.apple.security.cs.allow-unsigned-executable-memory`
3. `com.apple.security.cs.allow-dyld-environment-variables`
4. `com.apple.security.cs.disable-library-validation`

Avcs 当前不需要相机或麦克风权限，不复制 Livebook 的 camera/audio entitlements。

## github_actions

新增 `.github/workflows/desktop-macos.yml`，只做 macOS Apple Silicon 编译。

触发方式：

1. `workflow_dispatch`
2. 可选 `push` 到 `main` 时运行；如果构建耗时太长，先只保留手动触发。

runner 和 target：

```yaml
runs-on: macos-15
target: aarch64-apple-darwin
```

主要步骤：

1. `actions/checkout`
2. `erlef/setup-beam` 安装 Elixir/OTP。Avcs 当前没有 `versions` 文件，实施时需要新增 `versions` 或在 workflow 中固定版本。
3. `actions/setup-node` 安装 Node，用于 `web/npm ci`。
4. `dtolnay/rust-toolchain@stable`，targets 设置为 `aarch64-apple-darwin`。
5. Rust cache，workspace 指向 `rel/app/src-tauri`。
6. 安装 Tauri CLI，版本可先沿用 Livebook 的 `=2.8.0`。
7. 运行 `rel/app/tauri.sh build --target aarch64-apple-darwin`。
8. 用 `ditto -c -k --keepParent` 压缩 `.app`。
9. `actions/upload-artifact` 上传 `Avcs-macos-aarch64.app.zip`。

workflow 中明确删除这些 Livebook release 步骤：

1. `create_release` job。
2. Windows/Linux matrix。
3. Apple certificate import。
4. `tauri-apps/tauri-action` 的 release 上传配置。
5. `APPLE_CERTIFICATE`、`APPLE_ID`、`APPLE_PASSWORD`、`APPLE_TEAM_ID`、`TAURI_SIGNING_PRIVATE_KEY` 等 secret。
6. notarization verification。

## validation

本地验证：

1. `rel/app/tauri.sh app --target aarch64-apple-darwin`
2. Avcs 窗口可以打开，并显示现有 `/web/` React 工作台。
3. Phoenix API 和 WebSocket 可用，项目列表、项目打开、资产列表、画板渲染不退化。
4. 关闭 Tauri app 后，确认没有残留 `beam.smp`、`epmd` 或 `codex app-server` 子进程。
5. `file rel/app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Avcs.app/Contents/MacOS/Avcs` 显示 arm64。

CI 验证：

1. 手动触发 `desktop-macos.yml` 成功。
2. artifact 中包含 `Avcs.app`。
3. artifact 不是正式 signed/notarized release。
4. workflow 日志中不出现 P12、Apple ID、notarization 或 updater secret。

失败边界：

1. 如果 `PORT` 端口冲突，Rust 需要重新选择端口，而不是固定 9500。
2. 如果 Phoenix ready 超时，Tauri 显示错误窗口或写日志后退出，不能停留在空白窗口。
3. 如果 `npm run build` 失败，脚本直接失败，不继续打包旧静态文件。
4. 如果 release 子进程启动失败，Tauri 需要展示日志路径。

## implementation_steps

1. 调整 `mix.exs`，加入 `releases/0` 和 `app` release。
2. 调整 `config/runtime.exs`，支持 `AVCS_DESKTOP=true` 的本地桌面运行配置。
3. 调整 `Avcs.Application.skip_migrations?/0`，desktop release 不运行 Ecto migrator。
4. 新增 `/api/health` controller 和 router 入口。
5. 新增 `rel/app/env.sh.eex`、`rel/app/vm.args.eex`、`rel/app/README.md`。
6. 新增 `rel/app/src-tauri` Rust/Tauri scaffold。
7. 新增 `rel/app/tauri.sh`，封装 Vite build、Mix release 和 Tauri build。
8. 新增 `.github/workflows/desktop-macos.yml`。
9. 本地运行 `rel/app/tauri.sh app --target aarch64-apple-darwin` 验证。
10. 手动触发 GitHub Actions 验证 artifact。

## out_of_scope

本计划不实现：

1. macOS Intel build。
2. Windows 或 Linux build。
3. P12 / Developer ID 签名。
4. Apple notarization。
5. DMG 安装包。
6. 自动更新。
7. Tauri IPC 业务功能。
8. 用 Tauri 绕过 Phoenix 文件 API。

## prds

完成实现后同步补充 PRD：

1. `docs/prds/overview.md`：补充 MVP 可被 Tauri 打包成本地 macOS Apple Silicon app，但业务边界仍是 Phoenix 本地 Web 应用。
2. 新增 `docs/prds/features/web/003-桌面App打包.md`：记录 Tauri 只作为桌面壳、Phoenix 本地服务、无 P12 签名的限制和验收标准。
