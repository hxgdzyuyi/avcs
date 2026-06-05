# Avcs Desktop App

This directory contains the Tauri launcher used to package Avcs as a local
macOS Apple Silicon desktop app.

The desktop app runs the Phoenix release locally, opens Avcs in the system
browser, and keeps a tray menu for opening the app, copying the local URL,
viewing logs, and checking updates. React continues to talk only to Phoenix HTTP
APIs and WebSocket channels.

## Build

```bash
rel/app/tauri.sh build --target aarch64-apple-darwin
```

For local smoke testing on Apple Silicon macOS:

```bash
rel/app/tauri.sh app --target aarch64-apple-darwin
```

Deep links use the `avcs://` scheme. The launcher maps `avcs://settings` to
the settings page and `avcs://open?path=/absolute/project/folder` to
`/web/?project_path=...`, where the browser app opens the project through the
existing Phoenix API.

The macOS Apple Silicon updater is enabled through Tauri's updater plugin. It
checks this GitHub release endpoint:

```text
https://github.com/hxgdzyuyi/avcs/releases/latest/download/latest.json
```

The updater public key committed in `src-tauri/tauri.conf.json` is:

```text
dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEQ5NzEwRUJDOUVDNDc0RUEKUldUcWRNU2V2QTV4MlNDQUc0UXJiTUNWemtBNFNwVFZuNzZ0YkJHUkRraXJ1TTY2NlMwbnpDTG0K
```

GitHub Actions release builds require these repository secrets:

```text
TAURI_SIGNING_PRIVATE_KEY
TAURI_SIGNING_PRIVATE_KEY_PASSWORD
```

The `Generate Tauri updater key` workflow is only a helper for one-time key
generation or rotation. Once the secrets are configured, release publishing is
handled by `.github/workflows/desktop-macos.yml`.

The app bundle is written to:

```text
rel/app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Avcs.app
```

The release workflow uploads updater artifacts (`latest.json`, `.app.tar.gz`,
and `.sig`) plus the manual `Avcs-macos-aarch64.app.zip` download. The app is
not notarized, so macOS may still show an unidentified developer warning for
downloaded artifacts.
