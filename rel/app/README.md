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

The updater menu is wired to the Tauri updater runtime. A real update flow still
requires release endpoint, public key, signing, and notarization configuration.

The app bundle is written to:

```text
rel/app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Avcs.app
```

The bundle is unsigned and not notarized. macOS may block downloaded artifacts
with an unidentified developer warning; that is expected until Developer ID
signing and notarization are added in a later plan.
