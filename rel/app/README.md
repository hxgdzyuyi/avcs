# Avcs Desktop App

This directory contains the minimal Tauri shell used to package Avcs as a local
macOS Apple Silicon desktop app.

The desktop app still runs the Phoenix release locally and opens a Tauri WebView
against `http://127.0.0.1:<port>/`. React continues to talk only to Phoenix HTTP
APIs and WebSocket channels.

## Build

```bash
rel/app/tauri.sh build --target aarch64-apple-darwin
```

For local smoke testing on Apple Silicon macOS:

```bash
rel/app/tauri.sh app --target aarch64-apple-darwin
```

The app bundle is written to:

```text
rel/app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Avcs.app
```

The bundle is unsigned and not notarized. macOS may block downloaded artifacts
with an unidentified developer warning; that is expected until Developer ID
signing and notarization are added in a later plan.
