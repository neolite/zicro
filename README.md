# zicro

`zicro` is a fast terminal editor written in Zig for macOS and Linux.
Goal: replace `nano`/`micro` for daily coding with VSCode-like keybindings and practical LSP features.

## Features

- Piece-table buffer with undo/redo and UTF-8 safe cursor movement.
- Syntax highlighting for Zig, JavaScript/TypeScript, Bash, JSON.
- VSCode-style editing keys (`Ctrl+S`, `Ctrl+Q`, `Ctrl+Z`, `Ctrl+Y`, etc.).
- Linear selection (`Shift+Arrows`) and block selection (`Option+Arrows`).
- Clipboard copy/cut/paste (`Ctrl+C`, `Ctrl+K`, `Ctrl+V`) without line numbers.
- Regex search prompt (`Ctrl+F`) with realtime preview.
- In search prompt: `Down` = next match, `Up` = previous match.
- LSP integration (`didOpen`, incremental/full `didChange`, `didSave`) for:
  - `zls`
  - `typescript-language-server --stdio`
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

Examples:

```bash
./scripts/build.sh
./scripts/install.sh
PREFIX=/usr/local ./scripts/install.sh
ZIG_BIN=/tmp/zig-aarch64-macos-0.15.2/zig ./scripts/build.sh
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
- Arrows/Home/End/PageUp/PageDown: navigation
- `Shift+Arrows` + `Shift+Home/End/PageUp/PageDown`: linear selection
- `Option+Arrows`: block selection
- `Ctrl+Left/Right`: word navigation (if terminal sends modifier CSI)

## Config

`zicro` reads optional config from:

1. `--config <path>`
2. `./.zicro.json`

Example:

```json
{
  "tab_width": 4,
  "autosave": false,
  "lsp": {
    "enabled": true
  }
}
```

## LSP setup

Install servers:

- Zig: `zls`
- JS/TS: `npm i -g typescript typescript-language-server`
- Bash: `npm i -g bash-language-server`

For JS/TS, `zicro` checks `./node_modules/.bin` first, then `PATH`.
