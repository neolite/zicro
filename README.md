# zicro

`zicro` is a fast terminal editor written in Zig for macOS and Linux.
Goal: replace `nano`/`micro` for daily coding with VSCode-like keybindings and practical LSP features.


<img width="744" height="575" alt="image" src="https://github.com/user-attachments/assets/8d8c69dc-c31e-4a99-ac7d-856831fad4b1" />


## Features

- Piece-table buffer with undo/redo and UTF-8 safe cursor movement.
- Syntax highlighting for Zig, JavaScript/TypeScript, Bash, JSON.
- VSCode-style editing keys (`Ctrl+S`, `Ctrl+Q`, `Ctrl+Z`, `Ctrl+Y`, etc.).
- Linear selection (`Shift+Arrows`) and block selection (`Option+Arrows`).
- Clipboard copy/cut/paste (`Ctrl+C`, `Ctrl+K`, `Ctrl+V`) without line numbers.
- Regex search prompt (`Ctrl+F`) with realtime preview.
- In search prompt: `Down` = next match, `Up` = previous match.
- Search match is auto-centered in the viewport for better navigation UX.
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

1. defaults
2. `./.zicro.json` (cwd)
3. nearest repo-local `.zicro.json` (from edited file directory upward)
4. `--config <path>` (highest priority)

Example:

```json
{
  "tab_width": 4,
  "autosave": false,
  "lsp": {
    "enabled": true,
    "change_debounce_ms": 32,
    "did_save_debounce_ms": 64,
    "typescript": {
      "mode": "auto",
      "command": "npx",
      "args": ["tsgo", "--lsp", "-stdio"],
      "root_markers": ["package.json", "tsconfig.json", ".git"]
    }
  }
}
```

`lsp.change_debounce_ms`: delay before flushing `didChange` (1..1000, default `32`).
`lsp.did_save_debounce_ms`: debounce for TypeScript `didSave` pulse on typing (1..1000, default `64`).
`lsp.typescript.mode`: `auto | tsls | tsgo` (default `auto`).
`lsp.typescript.command` + `args`: explicit TS LSP command override.
`lsp.typescript.root_markers`: override project root detection markers for TS files.

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
