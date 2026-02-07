# Maintainability Guide

This file defines how to keep long-term project context inside the codebase.

## 1) Module Documentation
- Use `//!` at file top for core modules.
- Keep it short and practical:
  - purpose
  - major responsibilities
  - non-goals

Example:

```zig
//! LSP client transport and protocol orchestration.
//! Owns process lifecycle, JSON-RPC framing, and diagnostics snapshot state.
//! Does not own editor buffer mutations.
```

## 2) Public API Documentation
- Use `///` on public functions/types.
- Include parameter meaning, side effects, and error behavior.

Example:

```zig
/// Starts LSP for a file using resolved config and server fallback rules.
/// Returns `error.LspServerUnavailable` if no candidate server can be started.
pub fn startForFile(self: *Client, file_path: []const u8, config: *const Config) !void { ... }
```

## 3) Contract Blocks for Complex Paths
- For hot or fragile logic, add a compact contract block in comments:
  - preconditions
  - invariants
  - postconditions
- Back contracts with assertions/tests.

Example:

```zig
// Contract:
// - pre: offset is aligned or will be aligned before conversion.
// - invariant: UTF-16 column never decreases while scanning forward.
// - post: returned position is valid for LSP range updates.
```

## 4) Phase Completion Log Template
Use this at the end of each phase in `TASKS.md` notes.

```text
Phase: <N>
Date: <YYYY-MM-DD>
Build:
- zig fmt: pass
- zig build: pass
- zig build test: pass
Changed Areas:
- <module/file list>
Known Risks:
- <risk 1>
Next Focus:
- <next phase item>
```
