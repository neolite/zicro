# AGENTS

Scope: this file applies to the repository root and all subdirectories, except where a deeper `AGENTS.md` overrides it.

## Source of Truth
- Roadmap and task status live in `TASKS.md`.

## Current Focus
- Phase 2: LSP latency loader (`ms`) and optional performance overlay (`FPS` and frametime).
- Poll/sleep tuning to reduce busy-poll overhead without adding input lag.
- Keep compatibility with existing `.zicro.json` keys while adding new schema.

## Work Rules
- Before implementation, read `TASKS.md` and pick tasks from the current phase first.
- After implementation, update checkbox status in `TASKS.md`.
- Do not reorder phases unless the reason is documented in `TASKS.md`.
- Keep changes scoped; avoid unrelated refactors while phase tasks are open.

## Phase Gate (Required)
- After each completed phase, run:
  - `zig fmt` on changed Zig files
  - `zig build` on Zig `0.15.2`
  - `zig build test` on Zig `0.15.2`
- Mark phase completion only after all three commands pass.
- Record phase outcome in `TASKS.md` (status + short note).

## Zig Docs and Contracts
- Use `//!` file-level docs for core modules (`app`, `lsp`, `editor`, `ui`) to describe purpose and boundaries.
- Use `///` doc comments on public structs/functions that are part of module interfaces.
- For hot paths and tricky logic, add short contract blocks:
  - preconditions
  - invariants
  - postconditions
- Types alone are not enough for safety-critical paths; prefer explicit checks (`std.debug.assert`) plus tests.
- Keep comments precise and maintenance-oriented; avoid redundant prose.

## Config Precedence
- `--config` path has highest priority.
- Nearest repo-local `.zicro.json` has next priority.
- CWD `.zicro.json` and defaults are fallbacks.

## Defaults
- TypeScript LSP mode default: `auto`.
- Performance overlay default: `off`.
