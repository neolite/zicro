# Zicro Roadmap

Updated: 2026-02-07
Current phase: Phase 2
Current focus: LSP latency loader in ms, perf overlay (FPS/frametime), and poll/sleep tuning

## Phase Gate (Required for every phase)
- [ ] Run `zig fmt` on changed Zig files.
- [ ] Run `zig build` on Zig `0.15.2`.
- [ ] Run `zig build test` on Zig `0.15.2`.
- [ ] Add short phase completion note with risks/next actions.

## Documentation and Contract Policy
- [ ] Add/maintain `//!` module docs for core modules touched in a phase.
- [ ] Add/maintain `///` docs for public APIs changed in a phase.
- [ ] Add contract notes (pre/invariants/post) for complex or hot-path logic.
- [ ] Add tests for each new contract assertion in behavior-critical paths.

## Phase 0 - Baseline and Stabilization
- [x] Split monolithic `app.zig` responsibilities into focused modules.
- [x] Keep full-sync and incremental-sync LSP paths with didSave pulse debounce.
- [ ] Remove leftover duplication and enforce clean module boundaries.
- [ ] Add regression checklist for current UX behavior.

## Phase 1 - Config and LSP Provider Selection
- [x] Extend `.zicro.json` with per-language LSP config map.
- [x] Add TypeScript LSP mode: `auto | tsls | tsgo` (default `auto`).
- [x] Add TS command/args override for custom binaries and wrappers.
- [x] Support nearest repo-local `.zicro.json` overrides.
- [x] Define merge precedence: CLI config > nearest repo config > cwd/default.
- [x] Keep backward compatibility with existing `lsp.enabled/change_debounce/did_save_debounce`.
- [x] Improve startup error messages when no TS LSP provider is available.

## Phase 2 - LSP UX and Runtime Metrics
- [x] Add LSP request latency tracking (`ms`) in client state.
- [x] Show LSP latency in diagnostics/top bar loader.
- [ ] Add `ui.perf_overlay` config flag (default `false`).
- [ ] Add FPS and frametime metrics overlay.
- [ ] Add large-file smoke scenario and documented thresholds.
- [x] Tune poll/sleep strategy to reduce busy-poll overhead.

Phase 2 notes:
- 2026-02-07: Added pending/request latency display (`waiting <spinner> <ms>`), deterministic spinner frames, and capped payload processing per `poll()` tick to prevent UI stalls on LSP burst traffic.

## Phase 3 - Core LSP Features
- [ ] Implement completion requests and popup integration.
- [ ] Implement hover requests and inline/panel rendering.
- [ ] Implement go-to-definition navigation flow.
- [ ] Implement references navigation (or queue behind definition if blocked).
- [ ] Add keybindings and fallback behavior for unavailable capabilities.
- [ ] Add protocol tests for request/response parsing and routing.

## Phase 4 - Syntax Highlighting Upgrade
- [ ] Add multiline block comment support (`/* ... */`) for JS/TS.
- [ ] Add template literal handling for JS/TS.
- [ ] Add heredoc handling for shell-like languages where applicable.
- [ ] Replace linear keyword lookup with `ComptimeStringMap` where suitable.
- [ ] Add tokenizer regression tests for multiline edge cases.

## Phase 5 - Editing Model Enhancements
- [ ] Implement true multi-cursor model (multiple carets, not only block selection).
- [ ] Implement multi-cursor insert/delete/comment flows.
- [ ] Define interaction rules between multi-cursor, block selection, and search mode.
- [ ] Remove cursor/selection visual artifacts under fast typing and scrolling.

## Phase 6 - Test Expansion and Release Hardening
- [ ] Add UTF-8 edge tests for buffer operations (insert/delete/move/undo/redo).
- [ ] Add LSP fallback matrix tests (`tsgo` -> `tsls` and failure paths).
- [ ] Add perf smoke tests for large files (including 100MB+ scenarios).
- [ ] Update README with config examples for tsgo/tsls and repo-local overrides.
- [ ] Finalize macOS/Linux build and install verification checklist.

## Definition of Done
- [ ] `zig fmt` passes for changed files.
- [ ] `zig build` passes on Zig `0.15.2`.
- [ ] `zig build test` passes on Zig `0.15.2`.
- [ ] No regressions in existing UX baseline (search centering, block selection, diagnostics rendering).
- [ ] Documentation updated for every new user-facing config key or keybinding.
