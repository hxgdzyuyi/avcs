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


## Why Avcs

Avcs started from three practical needs.

First, when I ran out of credits on Lovart, I realized I already had a ChatGPT Pro
subscription. I did not want to pay for another dedicated image generation
subscription on top of that, so Avcs is built around `codex app-server` as a
local-first visual content studio.

Second, image generation often depends on accurate reference assets, not just
prompts. If I want to create a poster for a specific Steam game, for example, I
need the correct cover image available in the workflow. Avcs includes data
provider support so projects can quickly load precise image assets from external
sources and use them as references.

Third, local-first workflows can interact with the real contents of my local
project folders. I can ask Avcs to read and understand the code in a project,
then annotate a screenshot with button explanations or other inline help
documentation that stays close to the project files it describes.
