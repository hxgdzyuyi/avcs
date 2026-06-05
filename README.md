# Avcs

AI Visual Content Studio → Avcs

![Avcs Codex Image Studio banner](docs/assets/avcs-codex-image-studio-banner-v2.webp)

<p align="center"><b>English</b> · <a href="docs/i18n/README.zh-CN.md">简体中文</a></p>

## Summary

Avcs is a studio tool that uses Codex to generate images.

## Requirements

- Install [Codex CLI](https://developers.openai.com/codex/cli) (required to start `codex app-server` and run local agent workflows).

## Usage

![Usage guide](docs/assets/avcs-usage-guide-v2.webp)


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


## Demo

### 1. NASA APOD Poster

Avcs can load external visual references directly from the composer. Click the
book-shaped icon in the lower-left corner, load the NASA APOD data provider, and
ask Codex to generate a poster for the Astronomy Picture of the Day from a chosen
month and day.

<table>
  <tr>
    <th>Open Data Providers</th>
    <th>Load NASA APOD</th>
    <th>Generate the Poster</th>
  </tr>
  <tr>
    <td><img src="docs/assets/demo-01-01.webp" alt="Open the data provider picker from the composer" /></td>
    <td><img src="docs/assets/demo-01-02.webp" alt="Load NASA APOD images as visual references" /></td>
    <td><img src="docs/assets/demo-01-03.webp" alt="Generate an APOD poster for a chosen date" /></td>
  </tr>
</table>

### 2. Many-Case Output Board

Avcs keeps generated and imported visuals on a freeform Output board. A project
can collect poster drafts, icon explorations, typography tests, annotated
screenshots, and banner variants in one workspace, then select any image for
preview or reuse as a reference in the next Codex turn.

<img src="docs/assets/demo-02-many-case.webp" alt="Output board with many generated visual cases" />
