# zicro

`zicro` is a fast terminal editor written in Zig for macOS and Linux.
Goal: replace `nano`/`micro` for daily coding with VSCode-like keybindings and practical LSP features.


<img width="744" height="575" alt="image" src="https://github.com/user-attachments/assets/8d8c69dc-c31e-4a99-ac7d-856831fad4b1" />


## Features

- Piece-table buffer with undo/redo and UTF-8 safe cursor movement.
- Syntax highlighting for Zig, JavaScript/TypeScript, Bash, JSON.
- Stateful JS/TS multiline highlighting:
  - block comments (`/* ... */`) across lines
  - template literals with `${...}` across lines
- VSCode-style editing keys (`Ctrl+S`, `Ctrl+Q`, `Ctrl+Z`, `Ctrl+Y`, etc.).
- Linear selection (`Shift+Arrows`) and block selection (`Option+Arrows`).
- Clipboard copy/cut/paste (`Ctrl+C`, `Ctrl+K`, `Ctrl+V`) without line numbers.
- Regex search prompt (`Ctrl+F`) with realtime preview.
- In search prompt: `Down` = next match, `Up` = previous match.
- Search match is auto-centered in the viewport for better navigation UX.
- LSP actions:
  - realtime completion popup while typing (`Tab` accepts selected item)
  - realtime hover tooltip while idle after typing
  - manual completion (`Ctrl+N`)
  - manual hover (`Ctrl+T`)
  - go-to-definition (`Ctrl+D`)
  - references panel (`Ctrl+R`)
  - cross-file jump for definition/references targets
  - jump-back (`Ctrl+O`) with file-aware jump stack
- LSP integration (`didOpen`, incremental/full `didChange`, `didSave`) for:
  - `zls`
  - TypeScript auto mode: `tsgo --lsp -stdio` -> `npx tsgo --lsp -stdio` -> `typescript-language-server --stdio`
  - `bash-language-server start`
- Diagnostics UI:
  - top bar `ERR N | Lx: ...`
  - inline gutter markers `!`
  - first diagnostic symbol highlight
  - loader spinner while LSP initializes or requests are pending

## Requirements

- Zig `0.15.2+`
- Interactive TTY terminal

## Quick start

```bash
git clone https://github.com/<your-user>/zicro.git
cd zicro
./scripts/build.sh
./zig-out/bin/zicro path/to/file.ts
```

## Build scripts

`scripts/build.sh`
- Builds project with sane cache defaults for macOS/Linux.
- Respects `ZIG_BIN` if you want custom Zig path.

`scripts/install.sh`
- Builds and installs `zicro` into `${PREFIX:-$HOME/.local}/bin`.
- Works on both macOS and Linux.

`scripts/large-file-smoke.sh`
- Generates a realistic large file (`100MB+`) for manual smoke/perf tests.
- Can open it immediately with `--open`.

Examples:

```bash
./scripts/build.sh
./scripts/install.sh
PREFIX=/usr/local ./scripts/install.sh
ZIG_BIN=/tmp/zig-aarch64-macos-0.15.2/zig ./scripts/build.sh
./scripts/large-file-smoke.sh 128 /tmp/zicro-large-128mb.ts
```

## Releases (GitHub Actions)

Release pipeline is defined in `.github/workflows/release.yml`.

- Trigger: push a git tag matching `v*` (for example `v0.2.0`).
- Build matrix: `linux/macos` x `x86_64/arm64`.
- Outputs per release:
  - `zicro-<tag>-linux-x86_64.tar.gz`
  - `zicro-<tag>-linux-arm64.tar.gz`
  - `zicro-<tag>-macos-x86_64.tar.gz`
  - `zicro-<tag>-macos-arm64.tar.gz`
  - matching `.sha256` files

Release commands:

```bash
git tag v0.2.0
git push origin v0.2.0
```

## Key bindings

- `Ctrl+S`: save
- `Ctrl+Q` or `Ctrl+X`: quit (press twice if dirty)
- `Ctrl+C`: copy selection
- `Ctrl+K`: cut selection
- `Ctrl+V`: paste
- `Ctrl+P`: command palette
- `Ctrl+G`: goto line
- `Ctrl+F`: regex search prompt
- `Ctrl+/`: toggle comment for line/selection
- `Ctrl+Z`: undo
- `Ctrl+Y`: redo
- `Ctrl+N`: LSP completion popup
- `Ctrl+T`: LSP hover
- `Ctrl+D`: LSP go-to-definition
- `Ctrl+R`: LSP references panel
- `Ctrl+O`: jump back after LSP jump
- `Tab`: accept selected completion item when completion popup is open
- Arrows/Home/End/PageUp/PageDown: navigation
- `Shift+Arrows` + `Shift+Home/End/PageUp/PageDown`: linear selection
- `Option+Arrows`: block selection
- `Ctrl+Left/Right`: word navigation (if terminal sends modifier CSI)

## Config

`zicro` reads optional config from:

1. defaults
2. `./.zicro.json` (cwd)
3. nearest repo-local `.zicro.json` (from edited file directory upward)
4. `--config <path>` (highest priority)

Example:

```json
{
  "tab_width": 4,
  "autosave": false,
  "ui": {
    "perf_overlay": false
  },
  "lsp": {
    "enabled": true,
    "change_debounce_ms": 32,
    "did_save_debounce_ms": 64,
    "completion": {
      "auto": true,
      "debounce_ms": 48,
      "min_prefix_len": 1,
      "trigger_on_dot": true,
      "trigger_on_letters": true
    },
    "hover": {
      "auto": true,
      "debounce_ms": 140,
      "show_mode": "tooltip",
      "hide_on_type": true
    },
    "ui": {
      "tooltip_max_width": 72,
      "tooltip_max_rows": 10
    },
    "zig": {
      "enabled": true,
      "command": "zls",
      "args": [],
      "root_markers": ["build.zig", "build.zig.zon", ".git"]
    },
    "typescript": {
      "mode": "auto",
      "command": "npx",
      "args": ["tsgo", "--lsp", "-stdio"],
      "root_markers": ["package.json", "tsconfig.json", ".git"]
    },
    "adapters": [
      {
        "name": "typescript-tsgo",
        "language": "typescript",
        "enabled": true,
        "priority": 220
      },
      {
        "name": "zig-alt",
        "language": "zig",
        "command": "zls",
        "args": [],
        "file_extensions": [".zig"],
        "root_markers": ["build.zig", ".git"],
        "priority": 90
      }
    ]
  }
}
```

`ui.perf_overlay`: show runtime overlay in status bar (`FPS avg/EMA` + `FT avg/p95`) (default `false`).
`lsp.change_debounce_ms`: delay before flushing `didChange` (1..1000, default `32`).
`lsp.did_save_debounce_ms`: debounce for TypeScript `didSave` pulse on typing (1..1000, default `64`).
`lsp.completion.auto`: enable realtime completion trigger while typing (default `true`).
`lsp.completion.debounce_ms`: delay before auto completion request (1..1000, default `48`).
`lsp.completion.min_prefix_len`: minimum identifier length for letter-triggered completion (0..64, default `1`).
`lsp.completion.trigger_on_dot`: trigger completion after `.` (default `true`).
`lsp.completion.trigger_on_letters`: trigger completion while typing identifiers (default `true`).
`lsp.hover.auto`: enable realtime hover request after idle (default `true`).
`lsp.hover.debounce_ms`: idle delay before hover request (1..2000, default `140`).
`lsp.hover.show_mode`: `tooltip | status` (default `tooltip`).
`lsp.hover.hide_on_type`: hide hover tooltip when editing (default `true`).
`lsp.ui.tooltip_max_width`: max tooltip width in columns (16..240, default `72`).
`lsp.ui.tooltip_max_rows`: max tooltip height in rows (1..40, default `10`).
`lsp.typescript.mode`: `auto | tsls | tsgo` (default `auto`).
`lsp.typescript.command` + `args`: explicit TS LSP command override.
`lsp.typescript.root_markers`: override project root detection markers for TS files.
`lsp.zig.enabled`: optional legacy toggle for Zig LSP adapter (`true | false`).
`lsp.zig.command` + `args`: optional legacy override for builtin Zig adapter command.
`lsp.zig.root_markers`: optional legacy override for Zig root detection.
`lsp.adapters`: ordered custom adapter list. If `name` matches builtin adapter (`zig-zls`, `typescript-tsgo`, `typescript-npx-tsgo`, `typescript-tsls`, `bash-language-server`) it overrides it; otherwise adds a new adapter.
`lsp.adapters[].language`: LSP `languageId` used in `didOpen`.
`lsp.adapters[].priority`: candidate priority (`-1000..1000`), higher starts first.
`lsp.adapters[].enabled`: disable/enable adapter without removing config.
`lsp.adapters[].command` + `args`: server command for custom or overridden adapter.
`lsp.adapters[].file_extensions`: file matching list (e.g. `[".ts",".tsx"]`) for custom adapters.
`lsp.adapters[].root_markers`: optional root markers for custom/overridden adapter.

## LSP setup

Install servers:

- Zig: `zls`
- JS/TS (classic): `npm i -g typescript typescript-language-server`
- JS/TS (native preview): `npm i @typescript/native-preview`
- Bash: `npm i -g bash-language-server`

For JS/TS in `auto` mode, `zicro` tries:

1. `tsgo --lsp -stdio`
2. `npx tsgo --lsp -stdio`
3. `typescript-language-server --stdio`

`zicro` resolves binaries from project-local `node_modules/.bin` first, then `PATH`.

## Large files

- Editor file-open limit is `512MB`.
- LSP `didOpen` sync uses a `32MB` cap; for larger files the editor still opens, but LSP is disabled for that file.
- Recommended large-file smoke flow:

```bash
./scripts/large-file-smoke.sh 128 /tmp/zicro-large-128mb.ts --open
```

For raw editing performance checks, disable LSP in `.zicro.json`.
