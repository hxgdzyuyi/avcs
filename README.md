# Avcs

AI Visual Content Studio → Avcs

## Summary

Avcs is a studio tool that uses Codex to generate images.

## Requirements

- Install [Codex CLI](https://developers.openai.com/codex/cli) (required to start `codex app-server` and run local agent workflows).

## Usage

![Usage guide](docs/assets/avcs-usage-guide.webp)

## Architecture

Avcs is a local-first web app. Elixir/Phoenix is the single local backend boundary for
state, files, SQLite, and Codex agent access; the React frontend never reads the
local filesystem, SQLite, or `codex app-server` directly. Desktop packaging can
use a Tauri shell with an ElixirKit-style bridge to start Phoenix and open the
web UI.

```text
┌────────────────────────── browser / Tauri shell ───────────────────────────┐
│ system tray + local-port web app in browser                                │
└──────────────────────────────────────┬─────────────────────────────────────┘
                                       │
                                       ▼
┌────────────────────────── Elixir/Phoenix + React ──────────────────────────┐
│ UI, WebSocket channels, HTTP APIs, app boundary                            │
└──────────────────────────┬───────────────────────────────────────┬─────────┘
                           │                 stdio:// JSONL        │
                           ▼                                       ▼
┌────────────────────────────────────────────────────┐  ┌────────────────────┐
│ SQLite                                             │  │ codex app-server   │
└────────────┬───────────────────────────┬───────────┘  └──────────┬─────────┘
             │                           │                         │
             ▼                           ▼                         ▼
┌────────────────────────┐  ┌────────────────────────┐  ┌────────────────────┐
│ global DB              │  │ project DB + files     │  │ Codex Agent        │
│ ~/.avcs/avcs.sqlite3   │  │ .avcs/project.sqlite3  │  │ image_gen          │
│                        │  │ work/, output/         │  │ tool events        │
└────────────────────────┘  └────────────────────────┘  └────────────────────┘
```
