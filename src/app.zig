const std = @import("std");
const Buffer = @import("editor/buffer.zig").Buffer;
const Terminal = @import("ui/terminal.zig").Terminal;
const KeyEvent = @import("ui/terminal.zig").KeyEvent;
const LspClient = @import("lsp/client.zig");
const keymap = @import("keymap/keymap.zig");
const Command = keymap.Command;
const Config = @import("config.zig").Config;
const highlighter = @import("highlight/highlighter.zig");
const app_editor_motion = @import("app/editor_motion.zig");
const app_lsp_sync = @import("app/lsp_sync.zig");
const app_ui_renderer = @import("app/ui_renderer.zig");
const layout = @import("text/layout.zig");
const editor_state = @import("state/editor_state.zig");
const ui_state = @import("state/ui_state.zig");
const lsp_state = @import("state/lsp_state.zig");
const EditorState = editor_state.EditorState;
const SelectionMode = editor_state.SelectionMode;
const ByteRange = editor_state.ByteRange;
const SearchMatch = editor_state.SearchMatch;
const BlockSelection = editor_state.BlockSelection;
const UiState = ui_state.UiState;
const PromptMode = ui_state.PromptMode;
const PaletteAction = ui_state.PaletteAction;
const palette_entries = ui_state.palette_entries;
const LspPanelMode = ui_state.LspPanelMode;
const LspState = lsp_state.LspState;
const LspChangePosition = lsp_state.LspChangePosition;
const LspPosition = LspClient.LspPosition;
const CompletionItem = LspClient.CompletionItem;
const LocationItem = LspClient.LocationItem;

const c = @cImport({
    @cInclude("regex.h");
});

const max_open_file_bytes: usize = 512 * 1024 * 1024;
const idle_sleep_ns: u64 = 1 * std.time.ns_per_ms;
const terminal_tab_width: usize = 8;
const line_gutter_cols: usize = 5;
const max_events_per_tick: usize = 128;
const top_bar_rows: usize = 1;
const footer_rows: usize = 2;

pub const App = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    terminal: Terminal,
    editor: EditorState,
    ui: UiState,
    lsp_state: LspState,

    pub fn init(allocator: std.mem.Allocator, config: *const Config, file_path_opt: ?[]const u8) !App {
        const file_bytes = if (file_path_opt) |path|
            std.fs.cwd().readFileAlloc(allocator, path, max_open_file_bytes) catch |err| switch (err) {
                error.FileNotFound => try allocator.alloc(u8, 0),
                else => return err,
            }
        else
            try allocator.alloc(u8, 0);
        defer allocator.free(file_bytes);

        const file_path = if (file_path_opt) |path| try allocator.dupe(u8, path) else null;

        var app = App{
            .allocator = allocator,
            .config = config,
            .terminal = try Terminal.init(allocator),
            .editor = .{
                .buffer = try Buffer.fromBytes(allocator, file_bytes),
                .file_path = file_path,
                .cursor = 0,
                .selection_anchor = null,
                .selection_mode = .linear,
                .search_match = null,
                .scroll_y = 0,
                .dirty = false,
                .confirm_quit = false,
                .preferred_visual_col = null,
                .language = highlighter.detectLanguage(file_path_opt),
            },
            .ui = UiState.init(allocator, config.ui_perf_overlay),
            .lsp_state = LspState.init(
                allocator,
                @as(i128, @intCast(config.lsp_change_debounce_ms)) * std.time.ns_per_ms,
            ),
        };

        app.lsp_state.client.setDidSavePulseDebounceMs(config.lsp_did_save_debounce_ms);

        try app.setStatus("Ctrl+S save | Ctrl+Q quit | Ctrl+P palette | Ctrl+N completion | Ctrl+T hover | Ctrl+D definition");

        if (config.enable_lsp and app.editor.file_path != null) {
            app.lsp_state.client.startForFile(app.editor.file_path.?, config) catch |err| switch (err) {
                error.FileTooBig => try app.setStatus("LSP disabled: file too large for didOpen sync"),
                error.LspServerUnavailable => try app.setStatus("LSP disabled: no matching adapter or server unavailable"),
                else => try app.setStatus("LSP disabled: server not found or failed to spawn"),
            };
        }

        return app;
    }

    pub fn deinit(self: *App) void {
        self.clearPendingLspChanges();
        self.lsp_state.pending_lsp_changes.deinit();
        self.lsp_state.client.deinit();
        self.ui.deinit();
        self.editor.buffer.deinit();
        if (self.editor.file_path) |path| self.allocator.free(path);
        self.terminal.deinit();
    }

    pub fn run(self: *App) !void {
        var next_spinner_frame_ns: i128 = 0;
        var last_pending_requests: usize = 0;
        var last_spinner_active = false;
        while (self.ui.running) {
            var handled_events: usize = 0;
            while (handled_events < max_events_per_tick) {
                const event_opt = try self.terminal.readKey();
                if (event_opt) |event| {
                    if (self.ui.palette.active) {
                        try self.handlePaletteInput(event);
                    } else if (self.ui.prompt.active) {
                        try self.handlePromptInput(event);
                    } else {
                        try self.handleEditorInput(event);
                    }
                    self.ui.needs_render = true;
                    handled_events += 1;
                    continue;
                }
                break;
            }

            if (self.lsp_state.client.enabled) {
                const diagnostics_changed = self.lsp_state.client.poll() catch |err| blk: {
                    try self.handleLspError(err);
                    break :blk true;
                };
                if (diagnostics_changed) {
                    self.ui.needs_render = true;
                }
                if (try self.processLspInteractionUpdates()) {
                    self.ui.needs_render = true;
                }
                if (try self.processAutoLspRequests()) {
                    self.ui.needs_render = true;
                }

                const pending_requests = self.lsp_state.client.diagnostics().pending_requests;
                if (pending_requests != last_pending_requests) {
                    self.ui.needs_render = true;
                    last_pending_requests = pending_requests;
                }

                const spinner_active = !self.lsp_state.client.session_ready or pending_requests > 0;
                if (spinner_active != last_spinner_active) {
                    self.ui.needs_render = true;
                    last_spinner_active = spinner_active;
                    if (!spinner_active) self.ui.lsp_spinner_frame = 0;
                }

                if (spinner_active) {
                    const now = std.time.nanoTimestamp();
                    if (next_spinner_frame_ns == 0) {
                        next_spinner_frame_ns = now + 120 * std.time.ns_per_ms;
                    } else if (now >= next_spinner_frame_ns) {
                        self.ui.lsp_spinner_frame +%= 1;
                        self.ui.needs_render = true;
                        next_spinner_frame_ns = now + 120 * std.time.ns_per_ms;
                    }
                } else {
                    next_spinner_frame_ns = 0;
                }
            } else {
                if (last_pending_requests != 0) {
                    self.ui.needs_render = true;
                    last_pending_requests = 0;
                }
                if (last_spinner_active) {
                    self.ui.needs_render = true;
                    last_spinner_active = false;
                    self.ui.lsp_spinner_frame = 0;
                }
                if (self.ui.lsp_completion_pending or self.ui.lsp_hover_pending or self.ui.lsp_definition_pending or self.ui.lsp_references_pending or self.ui.lsp_panel_mode != .none) {
                    self.resetLspUiState();
                    self.ui.needs_render = true;
                }
                next_spinner_frame_ns = 0;
            }

            if (try self.flushPendingDidChange(false)) {
                self.ui.needs_render = true;
            }

            if (self.ui.needs_render) {
                try self.render();
                self.markFrameRendered();
                self.ui.needs_render = false;
            }

            if (handled_events > 0) continue;

            if (self.lsp_state.pending_lsp_sync) {
                const now = std.time.nanoTimestamp();
                if (self.lsp_state.next_lsp_flush_ns > now) {
                    const remaining = self.lsp_state.next_lsp_flush_ns - now;
                    const wait_ns: u64 = @intCast(@min(remaining, @as(i128, idle_sleep_ns)));
                    std.Thread.sleep(wait_ns);
                    continue;
                }
            }

            std.Thread.sleep(idle_sleep_ns);
        }
    }

    fn markFrameRendered(self: *App) void {
        if (!self.ui.perf_overlay_enabled) return;

        const now = std.time.nanoTimestamp();
        if (self.ui.perf_last_frame_ns != 0 and now > self.ui.perf_last_frame_ns) {
            const delta_ns = now - self.ui.perf_last_frame_ns;
            const frame_tenths = nsToTenthsMs(delta_ns);
            self.ui.perf_ft_last_tenths_ms = frame_tenths;

            const write_at = self.ui.perf_sample_index;
            self.ui.perf_frame_samples[write_at] = frame_tenths;
            self.ui.perf_sample_index = (write_at + 1) % UiState.perf_sample_capacity;
            if (self.ui.perf_sample_count < UiState.perf_sample_capacity) {
                self.ui.perf_sample_count += 1;
            }

            self.refreshPerfStats();
        }
        self.ui.perf_last_frame_ns = now;
    }

    fn refreshPerfStats(self: *App) void {
        const sample_count = self.ui.perf_sample_count;
        if (sample_count == 0) return;

        var sorted: [UiState.perf_sample_capacity]u16 = undefined;
        var total_tenths: u64 = 0;
        var max_tenths: u16 = 0;

        var i: usize = 0;
        while (i < sample_count) : (i += 1) {
            const value = self.ui.perf_frame_samples[i];
            sorted[i] = value;
            total_tenths += value;
            if (value > max_tenths) max_tenths = value;
        }

        std.mem.sort(u16, sorted[0..sample_count], {}, comptime std.sort.asc(u16));

        const avg_tenths_u64 = if (sample_count > 0) total_tenths / sample_count else 0;
        self.ui.perf_ft_avg_tenths_ms = clampU16(avg_tenths_u64);
        self.ui.perf_ft_max_tenths_ms = max_tenths;
        const p95_index = if (sample_count > 1) ((sample_count - 1) * 95) / 100 else 0;
        self.ui.perf_ft_p95_tenths_ms = sorted[p95_index];

        const avg_fps_u64 = if (avg_tenths_u64 > 0)
            @as(u64, @intCast((10000 + avg_tenths_u64 / 2) / avg_tenths_u64))
        else
            0;
        self.ui.perf_fps_avg = clampU16(avg_fps_u64);

        const inst = fpsTenthsFromFrameTenths(self.ui.perf_ft_last_tenths_ms);
        if (self.ui.perf_fps_ema_tenths == 0) {
            self.ui.perf_fps_ema_tenths = inst;
        } else {
            const ema = @as(u32, self.ui.perf_fps_ema_tenths);
            const inst_u32 = @as(u32, inst);
            const blended: u32 = ((ema * 8) + (inst_u32 * 2) + 5) / 10;
            self.ui.perf_fps_ema_tenths = clampU16(blended);
        }
    }

    fn handleEditorInput(self: *App, event: KeyEvent) !void {
        if (try self.handleLspPanelInput(event)) return;

        if (keymap.mapEditor(event)) |cmd| {
            try self.executeCommand(cmd);
            return;
        }

        switch (event) {
            .char => |ch| {
                if (try self.applyBlockTextInput(&[_]u8{ch})) return;
                _ = try self.deleteSelectionIfAny();
                try self.queueIncrementalChange(self.editor.cursor, self.editor.cursor, &[_]u8{ch});
                try self.editor.buffer.insert(self.editor.cursor, &[_]u8{ch});
                self.editor.cursor += 1;
                self.markBufferEdited();
            },
            .text => |text| {
                if (text.len == 0) return;
                if (try self.applyBlockTextInput(text)) return;
                _ = try self.deleteSelectionIfAny();
                try self.queueIncrementalChange(self.editor.cursor, self.editor.cursor, text);
                try self.editor.buffer.insert(self.editor.cursor, text);
                self.editor.cursor += text.len;
                self.markBufferEdited();
            },
            .tab => {
                var spaces = [_]u8{' '} ** 16;
                const count = @min(@as(usize, self.config.tab_width), spaces.len);
                if (try self.applyBlockTextInput(spaces[0..count])) return;
                _ = try self.deleteSelectionIfAny();
                try self.queueIncrementalChange(self.editor.cursor, self.editor.cursor, spaces[0..count]);
                try self.editor.buffer.insert(self.editor.cursor, spaces[0..count]);
                self.editor.cursor += count;
                self.markBufferEdited();
            },
            else => {},
        }
    }

    fn handleLspPanelInput(self: *App, event: KeyEvent) !bool {
        if (self.ui.lsp_panel_mode == .none) return false;

        switch (event) {
            .escape => {
                self.closeLspPanel();
                return true;
            },
            .up => {
                if (self.ui.lsp_panel_selected > 0) self.ui.lsp_panel_selected -= 1;
                return true;
            },
            .down => {
                self.ui.lsp_panel_selected += 1;
                return true;
            },
            .enter => {
                try self.activateLspPanelSelection();
                return true;
            },
            .tab => {
                if (self.ui.lsp_panel_mode == .completion) {
                    try self.activateLspPanelSelection();
                    return true;
                }
                return false;
            },
            .char, .text, .backspace, .delete => {
                self.closeLspPanel();
                return false;
            },
            else => return false,
        }
    }

    fn activateLspPanelSelection(self: *App) !void {
        switch (self.ui.lsp_panel_mode) {
            .none => {},
            .completion => {
                const completion = self.lsp_state.client.completion();
                if (completion.items.len == 0) {
                    if (completion.pending) {
                        try self.setStatus("Completion: waiting for LSP");
                    } else {
                        try self.setStatus("Completion: no items");
                    }
                    self.closeLspPanel();
                    return;
                }

                const index = @min(self.ui.lsp_panel_selected, completion.items.len - 1);
                try self.applyCompletionItem(completion.items[index]);
                self.closeLspPanel();
            },
            .references => {
                const references = self.lsp_state.client.references();
                if (references.items.len == 0) {
                    try self.setStatus("References: no items");
                    self.closeLspPanel();
                    return;
                }

                const index = @min(self.ui.lsp_panel_selected, references.items.len - 1);
                try self.jumpToLocation(references.items[index], true);
                self.closeLspPanel();
            },
        }
    }

    fn closeLspPanel(self: *App) void {
        self.ui.lsp_panel_mode = .none;
        self.ui.lsp_panel_selected = 0;
    }

    fn processLspInteractionUpdates(self: *App) !bool {
        var changed = false;

        const completion = self.lsp_state.client.completion();
        if (completion.rev != self.ui.lsp_completion_rev_seen) {
            self.ui.lsp_completion_rev_seen = completion.rev;
            changed = true;
        }
        if (self.ui.lsp_completion_pending and !completion.pending) {
            const requested_at_cursor = self.ui.lsp_completion_request_cursor;
            const is_auto = self.ui.lsp_completion_request_auto;
            self.ui.lsp_completion_pending = false;
            self.ui.lsp_completion_request_auto = false;
            if (completion.items.len == 0) {
                self.closeLspPanel();
                if (!is_auto) {
                    try self.setStatus("Completion: no items");
                }
            } else if (self.editor.cursor != requested_at_cursor and is_auto) {
                self.closeLspPanel();
            } else {
                self.ui.lsp_panel_mode = .completion;
                self.ui.lsp_panel_selected = 0;
                if (!is_auto) {
                    try self.setStatus("Completion ready");
                }
            }
            changed = true;
        }

        const hover = self.lsp_state.client.hover();
        if (hover.rev != self.ui.lsp_hover_rev_seen) {
            self.ui.lsp_hover_rev_seen = hover.rev;
            changed = true;
        }
        if (self.ui.lsp_hover_pending and !hover.pending) {
            const requested_at_cursor = self.ui.lsp_hover_request_cursor;
            const is_auto = self.ui.lsp_hover_request_auto;
            self.ui.lsp_hover_pending = false;
            self.ui.lsp_hover_request_auto = false;
            if (hover.text.len > 0) {
                if (self.editor.cursor != requested_at_cursor and is_auto) {
                    self.clearHoverTooltip();
                } else if (self.config.lsp_hover_show_mode == .tooltip) {
                    try self.setHoverTooltipFromRaw(hover.text);
                } else {
                    self.clearHoverTooltip();
                    try self.setStatusFromPrefix("Hover: ", hover.text);
                }
            } else {
                self.clearHoverTooltip();
                if (!is_auto) {
                    try self.setStatus("Hover: no info");
                }
            }
            changed = true;
        }

        const definitions = self.lsp_state.client.definitions();
        if (definitions.rev != self.ui.lsp_definition_rev_seen) {
            self.ui.lsp_definition_rev_seen = definitions.rev;
            changed = true;
        }
        if (self.ui.lsp_definition_pending and !definitions.pending) {
            self.ui.lsp_definition_pending = false;
            if (definitions.items.len > 0) {
                try self.jumpToLocation(definitions.items[0], true);
            } else {
                try self.setStatus("Definition: not found");
            }
            changed = true;
        }

        const references = self.lsp_state.client.references();
        if (references.rev != self.ui.lsp_references_rev_seen) {
            self.ui.lsp_references_rev_seen = references.rev;
            changed = true;
        }
        if (self.ui.lsp_references_pending and !references.pending) {
            self.ui.lsp_references_pending = false;
            if (references.items.len > 0) {
                self.ui.lsp_panel_mode = .references;
                self.ui.lsp_panel_selected = 0;
                try self.setStatus("References ready");
            } else {
                self.closeLspPanel();
                try self.setStatus("References: not found");
            }
            changed = true;
        }

        return changed;
    }

    fn processAutoLspRequests(self: *App) !bool {
        if (!self.lsp_state.client.enabled or !self.lsp_state.client.session_ready) return false;
        if (self.ui.prompt.active or self.ui.palette.active) return false;

        var changed = false;
        const now = std.time.nanoTimestamp();

        if (self.ui.lsp_auto_completion_due_ns > 0 and now >= self.ui.lsp_auto_completion_due_ns) {
            if (self.lsp_state.pending_lsp_sync) {
                self.ui.lsp_auto_completion_due_ns = now + 8 * std.time.ns_per_ms;
            } else {
                self.ui.lsp_auto_completion_due_ns = 0;
                if (!self.ui.lsp_completion_pending and self.shouldTriggerAutoCompletion()) {
                    try self.requestCompletion(true);
                    changed = true;
                }
            }
        }

        if (self.ui.lsp_auto_hover_due_ns > 0 and now >= self.ui.lsp_auto_hover_due_ns) {
            if (self.lsp_state.pending_lsp_sync) {
                self.ui.lsp_auto_hover_due_ns = now + 8 * std.time.ns_per_ms;
            } else {
                self.ui.lsp_auto_hover_due_ns = 0;
                if (self.config.lsp_hover_auto and !self.ui.lsp_hover_pending and self.ui.lsp_panel_mode != .completion) {
                    try self.requestHover(true);
                    changed = true;
                }
            }
        }

        return changed;
    }

    fn requestCompletion(self: *App, auto_mode: bool) !void {
        const caps = self.lsp_state.client.capabilities();
        if (!self.lsp_state.client.enabled or !self.lsp_state.client.session_ready) {
            if (!auto_mode) {
                try self.setStatus("Completion unavailable: LSP not ready");
            }
            return;
        }
        if (!caps.completion) {
            if (!auto_mode) {
                try self.setStatus("Completion unavailable: server capability missing");
            }
            return;
        }
        if (self.ui.lsp_completion_pending) {
            if (!auto_mode) {
                try self.setStatus("Completion: waiting for previous request");
            }
            return;
        }

        self.clearHoverTooltip();
        const pos = self.lspPositionFromOffset(self.editor.cursor);
        self.lsp_state.client.requestCompletion(.{
            .line = pos.line,
            .character = pos.character,
        }) catch |err| {
            try self.handleLspError(err);
            return;
        };
        self.ui.lsp_completion_pending = true;
        self.ui.lsp_completion_request_auto = auto_mode;
        self.ui.lsp_completion_request_cursor = self.editor.cursor;
        if (!auto_mode) {
            self.ui.lsp_panel_mode = .completion;
            self.ui.lsp_panel_selected = 0;
            try self.setStatus("Completion: requesting");
        }
    }

    fn requestHover(self: *App, auto_mode: bool) !void {
        const caps = self.lsp_state.client.capabilities();
        if (!self.lsp_state.client.enabled or !self.lsp_state.client.session_ready) {
            if (!auto_mode) {
                try self.setStatus("Hover unavailable: LSP not ready");
            }
            return;
        }
        if (!caps.hover) {
            if (!auto_mode) {
                try self.setStatus("Hover unavailable: server capability missing");
            }
            return;
        }
        if (self.ui.lsp_hover_pending) {
            if (!auto_mode) {
                try self.setStatus("Hover: waiting for previous request");
            }
            return;
        }

        const pos = self.lspPositionFromOffset(self.editor.cursor);
        self.lsp_state.client.requestHover(.{
            .line = pos.line,
            .character = pos.character,
        }) catch |err| {
            try self.handleLspError(err);
            return;
        };
        self.ui.lsp_hover_pending = true;
        self.ui.lsp_hover_request_auto = auto_mode;
        self.ui.lsp_hover_request_cursor = self.editor.cursor;
        if (!auto_mode) {
            try self.setStatus("Hover: requesting");
        }
    }

    fn scheduleAutoRequestsAfterEdit(self: *App) void {
        if (!self.lsp_state.client.enabled) return;

        const now = std.time.nanoTimestamp();

        if (self.config.lsp_hover_hide_on_type) {
            self.clearHoverTooltip();
        }

        if (self.config.lsp_completion_auto and self.shouldTriggerAutoCompletion()) {
            self.ui.lsp_auto_completion_due_ns = now + @as(i128, @intCast(self.config.lsp_completion_debounce_ms)) * std.time.ns_per_ms;
        } else {
            self.ui.lsp_auto_completion_due_ns = 0;
            if (self.ui.lsp_panel_mode == .completion) {
                self.closeLspPanel();
            }
        }

        if (self.config.lsp_hover_auto) {
            self.ui.lsp_auto_hover_due_ns = now + @as(i128, @intCast(self.config.lsp_hover_debounce_ms)) * std.time.ns_per_ms;
        } else {
            self.ui.lsp_auto_hover_due_ns = 0;
        }
    }

    fn shouldTriggerAutoCompletion(self: *App) bool {
        if (!self.config.lsp_completion_auto) return false;
        if (!self.lsp_state.client.enabled or !self.lsp_state.client.session_ready) return false;
        if (self.editor.selection_anchor != null) return false;
        if (self.editor.cursor == 0) return false;
        if (self.ui.prompt.active or self.ui.palette.active) return false;

        const prev = self.editor.buffer.prevCodepointStart(self.editor.cursor);
        if (prev >= self.editor.cursor) return false;
        if (self.editor.cursor - prev != 1) return false;
        const ch = self.editor.buffer.byteAt(prev) orelse return false;

        if (ch == '.' and self.config.lsp_completion_trigger_on_dot) return true;
        if (!self.config.lsp_completion_trigger_on_letters) return false;
        if (!isIdentifierByte(ch)) return false;

        return self.completionIdentifierPrefixLen() >= self.config.lsp_completion_min_prefix_len;
    }

    fn completionIdentifierPrefixLen(self: *const App) u8 {
        const range = self.identifierPrefixRangeForCursor() orelse return 0;
        const len = range.end - range.start;
        return if (len > 255) 255 else @as(u8, @intCast(len));
    }

    fn identifierPrefixRangeForCursor(self: *const App) ?ByteRange {
        if (self.editor.cursor == 0) return null;

        var start = self.editor.cursor;
        while (start > 0) {
            const prev = self.editor.buffer.prevCodepointStart(start);
            if (prev >= start) break;
            if (start - prev != 1) break;
            const ch = self.editor.buffer.byteAt(prev) orelse break;
            if (!isIdentifierByte(ch)) break;
            start = prev;
        }

        if (start == self.editor.cursor) return null;
        return .{
            .start = start,
            .end = self.editor.cursor,
        };
    }

    fn bufferRangeOwned(self: *const App, range: ByteRange) ![]u8 {
        if (range.end <= range.start) return self.allocator.alloc(u8, 0);

        const len = range.end - range.start;
        var out = try self.allocator.alloc(u8, len);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            out[i] = self.editor.buffer.byteAt(range.start + i) orelse 0;
        }
        return out;
    }

    fn clearHoverTooltip(self: *App) void {
        self.ui.lsp_hover_tooltip_active = false;
        self.ui.lsp_hover_tooltip_text.clearRetainingCapacity();
    }

    fn setHoverTooltipFromRaw(self: *App, raw_text: []const u8) !void {
        self.ui.lsp_hover_tooltip_text.clearRetainingCapacity();
        var index: usize = 0;
        while (index < raw_text.len and self.ui.lsp_hover_tooltip_text.items.len < 2048) {
            const ch = raw_text[index];
            if (ch == '\r') {
                index += 1;
                continue;
            }
            if (ch == '\n') {
                try self.ui.lsp_hover_tooltip_text.append('\n');
                index += 1;
                continue;
            }
            if (ch == '\t') {
                try self.ui.lsp_hover_tooltip_text.append(' ');
                index += 1;
                continue;
            }
            if (ch < 0x20 or ch == 0x7f) {
                index += 1;
                continue;
            }
            const step = layout.utf8Step(raw_text, index);
            try self.ui.lsp_hover_tooltip_text.appendSlice(raw_text[index .. index + step]);
            index += step;
        }
        self.ui.lsp_hover_tooltip_active = self.ui.lsp_hover_tooltip_text.items.len > 0;
    }

    fn requestDefinition(self: *App) !void {
        const caps = self.lsp_state.client.capabilities();
        if (!self.lsp_state.client.enabled or !self.lsp_state.client.session_ready) {
            try self.setStatus("Definition unavailable: LSP not ready");
            return;
        }
        if (!caps.definition) {
            try self.setStatus("Definition unavailable: server capability missing");
            return;
        }

        const pos = self.lspPositionFromOffset(self.editor.cursor);
        self.lsp_state.client.requestDefinition(.{
            .line = pos.line,
            .character = pos.character,
        }) catch |err| {
            try self.handleLspError(err);
            return;
        };
        self.ui.lsp_definition_pending = true;
        try self.setStatus("Definition: requesting");
    }

    fn requestReferences(self: *App) !void {
        const caps = self.lsp_state.client.capabilities();
        if (!self.lsp_state.client.enabled or !self.lsp_state.client.session_ready) {
            try self.setStatus("References unavailable: LSP not ready");
            return;
        }
        if (!caps.references) {
            try self.setStatus("References unavailable: server capability missing");
            return;
        }

        const pos = self.lspPositionFromOffset(self.editor.cursor);
        self.lsp_state.client.requestReferences(.{
            .line = pos.line,
            .character = pos.character,
        }) catch |err| {
            try self.handleLspError(err);
            return;
        };
        self.ui.lsp_references_pending = true;
        self.ui.lsp_panel_mode = .references;
        self.ui.lsp_panel_selected = 0;
        try self.setStatus("References: requesting");
    }

    fn jumpBack(self: *App) !void {
        if (self.ui.jump_stack.items.len == 0) {
            try self.setStatus("Jump back: stack empty");
            return;
        }

        const target = self.ui.jump_stack.pop().?;
        self.editor.cursor = @min(target, self.editor.buffer.len());
        self.clearSelection();
        self.centerCursorInViewport();
        self.editor.preferred_visual_col = null;
        try self.setStatus("Jumped back");
    }

    fn applyCompletionItem(self: *App, item: CompletionItem) !void {
        _ = try self.deleteSelectionIfAny();

        if (item.has_text_edit) {
            const start = self.offsetFromLspPosition(item.text_edit_start.line, item.text_edit_start.character);
            const end_raw = self.offsetFromLspPosition(item.text_edit_end.line, item.text_edit_end.character);
            const end = @max(start, end_raw);
            try self.queueIncrementalChange(start, end, item.insert_text);
            if (end > start) {
                try self.editor.buffer.delete(start, end - start);
            }
            try self.editor.buffer.insert(start, item.insert_text);
            self.editor.cursor = start + item.insert_text.len;
            self.markBufferEdited();
            return;
        }

        if (self.identifierPrefixRangeForCursor()) |prefix_range| {
            const prefix = try self.bufferRangeOwned(prefix_range);
            defer self.allocator.free(prefix);

            if (completionSuffix(item.insert_text, prefix)) |suffix| {
                if (suffix.len == 0) return;
                try self.queueIncrementalChange(self.editor.cursor, self.editor.cursor, suffix);
                try self.editor.buffer.insert(self.editor.cursor, suffix);
                self.editor.cursor += suffix.len;
                self.markBufferEdited();
                return;
            }
        }

        try self.queueIncrementalChange(self.editor.cursor, self.editor.cursor, item.insert_text);
        try self.editor.buffer.insert(self.editor.cursor, item.insert_text);
        self.editor.cursor += item.insert_text.len;
        self.markBufferEdited();
    }

    fn jumpToLocation(self: *App, location: LocationItem, push_current: bool) !void {
        if (!location.same_document) {
            try self.setStatus("Cross-file jump not supported yet");
            return;
        }

        if (push_current) {
            try self.pushJumpLocation(self.editor.cursor);
        }

        const offset = self.offsetFromLspPosition(location.line, location.character);
        self.editor.cursor = @min(offset, self.editor.buffer.len());
        self.clearSelection();
        self.centerCursorInViewport();
        self.editor.preferred_visual_col = null;
        try self.setStatus("Jumped");
    }

    fn pushJumpLocation(self: *App, offset: usize) !void {
        const max_jump_stack: usize = 256;
        const clamped = @min(offset, self.editor.buffer.len());
        if (self.ui.jump_stack.items.len > 0) {
            const last = self.ui.jump_stack.items[self.ui.jump_stack.items.len - 1];
            if (last == clamped) return;
        }
        if (self.ui.jump_stack.items.len >= max_jump_stack) {
            _ = self.ui.jump_stack.orderedRemove(0);
        }
        try self.ui.jump_stack.append(clamped);
    }

    fn executeCommand(self: *App, command: Command) !void {
        switch (command) {
            .lsp_hover, .lsp_completion, .lsp_definition, .lsp_references, .lsp_jump_back => {},
            else => self.clearHoverTooltip(),
        }

        switch (command) {
            .save => try self.saveFile(),
            .quit => try self.requestQuit(),
            .copy => try self.copySelectionToClipboard(),
            .cut => try self.cutSelectionToClipboard(),
            .paste => try self.pasteFromClipboard(),
            .goto_line => {
                self.closeLspPanel();
                self.ui.prompt.open(.goto_line);
                self.ui.palette.active = false;
            },
            .regex_search => {
                self.closeLspPanel();
                self.ui.prompt.open(.regex_search);
                self.ui.palette.active = false;
            },
            .toggle_comment => try self.toggleCommentSelection(),
            .show_palette => {
                self.closeLspPanel();
                self.ui.palette.active = true;
                self.ui.palette.clear();
                self.ui.prompt.close();
                self.editor.preferred_visual_col = null;
            },
            .move_left => {
                self.clearSelection();
                const next = self.editor.buffer.prevCodepointStart(self.editor.cursor);
                if (next != self.editor.cursor) {
                    self.editor.cursor = next;
                }
                self.editor.preferred_visual_col = null;
            },
            .move_right => {
                self.clearSelection();
                const next = self.editor.buffer.nextCodepointEnd(self.editor.cursor);
                if (next != self.editor.cursor) {
                    self.editor.cursor = next;
                }
                self.editor.preferred_visual_col = null;
            },
            .move_up => {
                self.clearSelection();
                self.moveVertical(-1);
            },
            .move_down => {
                self.clearSelection();
                self.moveVertical(1);
            },
            .move_home => {
                self.clearSelection();
                const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
                self.editor.cursor = self.editor.buffer.offsetFromLineCol(pos.line, 0);
                self.editor.preferred_visual_col = null;
            },
            .move_end => {
                self.clearSelection();
                const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
                self.editor.cursor = self.editor.buffer.offsetFromLineCol(pos.line, std.math.maxInt(usize));
                self.editor.preferred_visual_col = null;
            },
            .page_up => {
                self.clearSelection();
                self.movePage(-1);
            },
            .page_down => {
                self.clearSelection();
                self.movePage(1);
            },
            .select_left => {
                self.beginSelection();
                const next = self.editor.buffer.prevCodepointStart(self.editor.cursor);
                if (next != self.editor.cursor) self.editor.cursor = next;
                self.editor.preferred_visual_col = null;
            },
            .select_right => {
                self.beginSelection();
                const next = self.editor.buffer.nextCodepointEnd(self.editor.cursor);
                if (next != self.editor.cursor) self.editor.cursor = next;
                self.editor.preferred_visual_col = null;
            },
            .select_up => {
                self.beginSelection();
                self.moveVertical(-1);
            },
            .select_down => {
                self.beginSelection();
                self.moveVertical(1);
            },
            .select_home => {
                self.beginSelection();
                const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
                self.editor.cursor = self.editor.buffer.offsetFromLineCol(pos.line, 0);
                self.editor.preferred_visual_col = null;
            },
            .select_end => {
                self.beginSelection();
                const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
                self.editor.cursor = self.editor.buffer.offsetFromLineCol(pos.line, std.math.maxInt(usize));
                self.editor.preferred_visual_col = null;
            },
            .select_page_up => {
                self.beginSelection();
                self.movePage(-1);
            },
            .select_page_down => {
                self.beginSelection();
                self.movePage(1);
            },
            .block_select_left => {
                self.beginBlockSelection();
                const next = self.editor.buffer.prevCodepointStart(self.editor.cursor);
                if (next != self.editor.cursor) self.editor.cursor = next;
                self.editor.preferred_visual_col = null;
            },
            .block_select_right => {
                self.beginBlockSelection();
                const next = self.editor.buffer.nextCodepointEnd(self.editor.cursor);
                if (next != self.editor.cursor) self.editor.cursor = next;
                self.editor.preferred_visual_col = null;
            },
            .block_select_up => {
                self.beginBlockSelection();
                self.moveVertical(-1);
            },
            .block_select_down => {
                self.beginBlockSelection();
                self.moveVertical(1);
            },
            .word_left => {
                self.clearSelection();
                self.editor.cursor = self.editor.buffer.moveWordLeft(self.editor.cursor);
                self.editor.preferred_visual_col = null;
            },
            .word_right => {
                self.clearSelection();
                self.editor.cursor = self.editor.buffer.moveWordRight(self.editor.cursor);
                self.editor.preferred_visual_col = null;
            },
            .backspace => {
                if (self.hasBlockSelection()) {
                    if (try self.deleteSelectionIfAny()) {
                        self.markBufferEditedForceFullSync();
                        return;
                    }
                }
                if (try self.deleteSelectionIfAny()) {
                    self.markBufferEdited();
                    return;
                }
                if (self.editor.cursor > 0) {
                    const start = self.editor.buffer.prevCodepointStart(self.editor.cursor);
                    if (start < self.editor.cursor) {
                        try self.queueIncrementalChange(start, self.editor.cursor, "");
                        try self.editor.buffer.delete(start, self.editor.cursor - start);
                        self.editor.cursor = start;
                        self.markBufferEdited();
                    }
                }
            },
            .delete_char => {
                if (self.hasBlockSelection()) {
                    if (try self.deleteSelectionIfAny()) {
                        self.markBufferEditedForceFullSync();
                        return;
                    }
                }
                if (try self.deleteSelectionIfAny()) {
                    self.markBufferEdited();
                    return;
                }
                if (self.editor.cursor < self.editor.buffer.len()) {
                    const end = self.editor.buffer.nextCodepointEnd(self.editor.cursor);
                    if (end > self.editor.cursor) {
                        try self.queueIncrementalChange(self.editor.cursor, end, "");
                        try self.editor.buffer.delete(self.editor.cursor, end - self.editor.cursor);
                        self.markBufferEdited();
                    }
                }
            },
            .insert_newline => {
                if (self.hasBlockSelection()) {
                    if (try self.deleteSelectionIfAny()) {
                        self.markBufferEditedForceFullSync();
                        return;
                    }
                }
                _ = try self.deleteSelectionIfAny();
                try self.queueIncrementalChange(self.editor.cursor, self.editor.cursor, "\n");
                try self.editor.buffer.insert(self.editor.cursor, "\n");
                self.editor.cursor += 1;
                self.markBufferEdited();
            },
            .undo => {
                try self.editor.buffer.undo();
                if (self.editor.cursor > self.editor.buffer.len()) self.editor.cursor = self.editor.buffer.len();
                self.clearSelection();
                self.markBufferEditedForceFullSync();
            },
            .redo => {
                try self.editor.buffer.redo();
                if (self.editor.cursor > self.editor.buffer.len()) self.editor.cursor = self.editor.buffer.len();
                self.clearSelection();
                self.markBufferEditedForceFullSync();
            },
            .lsp_completion => try self.requestCompletion(false),
            .lsp_hover => try self.requestHover(false),
            .lsp_definition => try self.requestDefinition(),
            .lsp_references => try self.requestReferences(),
            .lsp_jump_back => try self.jumpBack(),
        }
    }

    fn handlePaletteInput(self: *App, event: KeyEvent) !void {
        switch (event) {
            .escape => {
                self.ui.palette.active = false;
            },
            .backspace => {
                if (self.ui.palette.query.items.len > 0) {
                    const prev = utf8PrevBoundary(self.ui.palette.query.items, self.ui.palette.query.items.len);
                    self.ui.palette.query.items.len = prev;
                    self.ui.palette.selected = 0;
                }
            },
            .up => {
                if (self.ui.palette.selected > 0) self.ui.palette.selected -= 1;
            },
            .down => {
                self.ui.palette.selected += 1;
            },
            .enter => {
                const matches = try self.paletteMatches(self.allocator);
                defer matches.deinit();

                if (matches.items.len == 0) {
                    self.ui.palette.active = false;
                    return;
                }

                const index = @min(self.ui.palette.selected, matches.items.len - 1);
                const action = palette_entries[matches.items[index]].action;
                self.ui.palette.active = false;
                try self.executePaletteAction(action);
            },
            .char => |ch| {
                if (std.ascii.isPrint(ch) or ch == ' ') {
                    try self.ui.palette.query.append(ch);
                    self.ui.palette.selected = 0;
                }
            },
            .text => |text| {
                if (text.len > 0) {
                    try self.ui.palette.query.appendSlice(text);
                    self.ui.palette.selected = 0;
                }
            },
            .ctrl => |ch| {
                if (ch == 'p') self.ui.palette.active = false;
            },
            else => {},
        }
    }

    fn handlePromptInput(self: *App, event: KeyEvent) !void {
        switch (event) {
            .escape => self.ui.prompt.close(),
            .backspace => {
                if (self.ui.prompt.query.items.len > 0) {
                    const prev = utf8PrevBoundary(self.ui.prompt.query.items, self.ui.prompt.query.items.len);
                    self.ui.prompt.query.items.len = prev;
                    try self.updateRegexPromptPreview();
                }
            },
            .enter => try self.executePrompt(),
            .up => try self.regexPrevFromPrompt(),
            .down => try self.regexNextFromPrompt(),
            .char => |ch| {
                if (std.ascii.isPrint(ch) or ch == ' ') {
                    try self.ui.prompt.query.append(ch);
                    try self.updateRegexPromptPreview();
                }
            },
            .text => |text| {
                if (text.len > 0) {
                    try self.ui.prompt.query.appendSlice(text);
                    try self.updateRegexPromptPreview();
                }
            },
            .ctrl => |ch| {
                if (ch == 'g' or ch == 'f') self.ui.prompt.close();
            },
            else => {},
        }
    }

    fn executePrompt(self: *App) !void {
        const mode = self.ui.prompt.mode;
        const query = try self.allocator.dupe(u8, self.ui.prompt.query.items);
        defer self.allocator.free(query);
        self.ui.prompt.close();

        switch (mode) {
            .goto_line => try self.executeGotoLine(query),
            .regex_search => try self.executeRegexSearch(query),
        }
    }

    fn executeGotoLine(self: *App, query: []const u8) !void {
        const trimmed = std.mem.trim(u8, query, " \t");
        if (trimmed.len == 0) {
            try self.setStatus("Goto line: empty input");
            return;
        }

        const line_1_based = std.fmt.parseUnsigned(usize, trimmed, 10) catch {
            try self.setStatus("Goto line: invalid number");
            return;
        };

        if (line_1_based == 0) {
            try self.setStatus("Goto line: line starts at 1");
            return;
        }

        const line_index = @min(line_1_based - 1, self.editor.buffer.lineCount() - 1);
        self.editor.cursor = self.editor.buffer.offsetFromLineCol(line_index, 0);
        self.clearSelection();
        self.editor.preferred_visual_col = null;
        try self.setStatus("Moved");
    }

    fn executeRegexSearch(self: *App, query: []const u8) !void {
        const trimmed = std.mem.trim(u8, query, " \t");
        if (trimmed.len == 0) {
            self.editor.search_match = null;
            try self.setStatus("Regex search: empty pattern");
            return;
        }

        const start_offset = if (self.editor.cursor < self.editor.buffer.len()) self.editor.cursor + 1 else self.editor.cursor;
        const match = self.findRegexForward(trimmed, start_offset) catch |err| switch (err) {
            error.InvalidRegex => {
                self.editor.search_match = null;
                try self.setStatus("Regex search: invalid pattern");
                return;
            },
            else => return err,
        };

        if (match) |found| {
            self.editor.cursor = found.start;
            self.editor.search_match = found;
            self.clearSelection();
            self.editor.preferred_visual_col = null;
            try self.setStatus("Regex match found");
        } else {
            self.editor.search_match = null;
            try self.setStatus("Regex: no matches");
        }
    }

    fn updateRegexPromptPreview(self: *App) !void {
        if (!self.ui.prompt.active or self.ui.prompt.mode != .regex_search) return;
        const pattern = std.mem.trim(u8, self.ui.prompt.query.items, " \t");
        if (pattern.len == 0) {
            self.editor.search_match = null;
            return;
        }

        const start_offset = if (self.editor.cursor < self.editor.buffer.len()) self.editor.cursor else self.editor.buffer.len();
        const match = self.findRegexForward(pattern, start_offset) catch |err| switch (err) {
            error.InvalidRegex => {
                self.editor.search_match = null;
                return;
            },
            else => return err,
        };

        if (match) |found| {
            self.applySearchMatch(found);
        } else {
            self.editor.search_match = null;
        }
    }

    fn regexNextFromPrompt(self: *App) !void {
        if (!self.ui.prompt.active or self.ui.prompt.mode != .regex_search) return;
        const pattern = std.mem.trim(u8, self.ui.prompt.query.items, " \t");
        if (pattern.len == 0) return;

        const base = if (self.editor.search_match) |found| found.start else self.editor.cursor;
        const start_offset = if (base < self.editor.buffer.len()) base + 1 else base;
        const match = try self.findRegexForward(pattern, start_offset);
        if (match) |found| {
            self.applySearchMatch(found);
            try self.setStatus("Regex: next match");
        } else {
            self.editor.search_match = null;
            try self.setStatus("Regex: no matches");
        }
    }

    fn regexPrevFromPrompt(self: *App) !void {
        if (!self.ui.prompt.active or self.ui.prompt.mode != .regex_search) return;
        const pattern = std.mem.trim(u8, self.ui.prompt.query.items, " \t");
        if (pattern.len == 0) return;

        const start_offset = if (self.editor.search_match) |found| found.start else self.editor.cursor;
        const match = try self.findRegexBackward(pattern, start_offset);
        if (match) |found| {
            self.applySearchMatch(found);
            try self.setStatus("Regex: previous match");
        } else {
            self.editor.search_match = null;
            try self.setStatus("Regex: no matches");
        }
    }

    fn applySearchMatch(self: *App, found: SearchMatch) void {
        self.editor.cursor = found.start;
        self.editor.search_match = found;
        self.centerCursorInViewport();
        self.clearSelection();
        self.editor.preferred_visual_col = null;
    }

    fn centerCursorInViewport(self: *App) void {
        const text_rows = self.editorTextRows();
        const line_count = self.editor.buffer.lineCount();
        if (line_count <= text_rows) {
            self.editor.scroll_y = 0;
            return;
        }

        const line = self.editor.buffer.lineColFromOffset(self.editor.cursor).line;
        const half = text_rows / 2;
        const desired_top = if (line > half) line - half else 0;
        const max_top = line_count - text_rows;
        self.editor.scroll_y = @min(desired_top, max_top);
    }

    fn findRegexForward(self: *App, pattern: []const u8, start_offset_input: usize) !?SearchMatch {
        if (pattern.len == 0) return null;

        var pattern_c = try self.allocator.alloc(u8, pattern.len + 1);
        defer self.allocator.free(pattern_c);
        @memcpy(pattern_c[0..pattern.len], pattern);
        pattern_c[pattern.len] = 0;

        var regex: c.regex_t = undefined;
        const compile_rc = c.regcomp(&regex, @ptrCast(pattern_c.ptr), c.REG_EXTENDED);
        if (compile_rc != 0) return error.InvalidRegex;
        defer _ = c.regfree(&regex);

        const start_offset = @min(start_offset_input, self.editor.buffer.len());
        const start_pos = self.editor.buffer.lineColFromOffset(start_offset);
        const line_count = self.editor.buffer.lineCount();

        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            const start_line = if (pass == 0) start_pos.line else 0;
            const end_line = if (pass == 0) line_count else start_pos.line + 1;

            var line = start_line;
            while (line < end_line) : (line += 1) {
                const line_bytes = try self.editor.buffer.lineOwned(self.allocator, line);
                defer self.allocator.free(line_bytes);

                const line_start = self.editor.buffer.offsetFromLineCol(line, 0);
                const min_col = if (pass == 0 and line == start_pos.line) start_offset - line_start else 0;
                const range = try regexMatchInLine(&regex, line_bytes, min_col, self.allocator);
                if (range) |local| {
                    return .{
                        .start = line_start + local.start,
                        .end = line_start + local.end,
                    };
                }
            }
        }

        return null;
    }

    fn findRegexBackward(self: *App, pattern: []const u8, start_offset_input: usize) !?SearchMatch {
        if (pattern.len == 0) return null;

        var pattern_c = try self.allocator.alloc(u8, pattern.len + 1);
        defer self.allocator.free(pattern_c);
        @memcpy(pattern_c[0..pattern.len], pattern);
        pattern_c[pattern.len] = 0;

        var regex: c.regex_t = undefined;
        const compile_rc = c.regcomp(&regex, @ptrCast(pattern_c.ptr), c.REG_EXTENDED);
        if (compile_rc != 0) return error.InvalidRegex;
        defer _ = c.regfree(&regex);

        const start_offset = @min(start_offset_input, self.editor.buffer.len());
        const line_count = self.editor.buffer.lineCount();

        var best_before: ?SearchMatch = null;
        var best_any: ?SearchMatch = null;

        var line: usize = 0;
        while (line < line_count) : (line += 1) {
            const line_bytes = try self.editor.buffer.lineOwned(self.allocator, line);
            defer self.allocator.free(line_bytes);
            const line_start = self.editor.buffer.offsetFromLineCol(line, 0);

            var min_col: usize = 0;
            while (min_col <= line_bytes.len) {
                const range = try regexMatchInLine(&regex, line_bytes, min_col, self.allocator);
                const local = range orelse break;
                const found: SearchMatch = .{
                    .start = line_start + local.start,
                    .end = line_start + local.end,
                };

                best_any = found;
                if (found.start < start_offset) {
                    best_before = found;
                }

                if (local.end <= min_col) break;
                min_col = local.end;
            }
        }

        return best_before orelse best_any;
    }

    fn toggleCommentSelection(self: *App) !void {
        const line_range = self.selectedLineRange();
        var non_empty: usize = 0;
        var commented: usize = 0;

        var scan = line_range.start;
        while (scan <= line_range.end) : (scan += 1) {
            const line = try self.editor.buffer.lineOwned(self.allocator, scan);
            defer self.allocator.free(line);

            const info = lineCommentInfo(line);
            if (!info.empty) {
                non_empty += 1;
                if (info.has_comment) commented += 1;
            }
        }

        const uncomment = non_empty > 0 and commented == non_empty;

        var line_i64: i64 = @intCast(line_range.end);
        while (line_i64 >= @as(i64, @intCast(line_range.start))) : (line_i64 -= 1) {
            const line_index: usize = @intCast(line_i64);
            const line = try self.editor.buffer.lineOwned(self.allocator, line_index);
            defer self.allocator.free(line);

            const info = lineCommentInfo(line);
            if (info.empty) continue;

            const line_start = self.editor.buffer.offsetFromLineCol(line_index, 0);
            if (uncomment) {
                if (!info.has_comment) continue;
                const comment_at = line_start + info.comment_col;
                var remove_len: usize = 2;
                if (info.comment_col + 2 < line.len and line[info.comment_col + 2] == ' ') {
                    remove_len = 3;
                }
                try self.editor.buffer.delete(comment_at, remove_len);
            } else {
                const insert_at = line_start + info.indent_col;
                try self.editor.buffer.insert(insert_at, "// ");
            }
        }

        self.clearSelection();
        self.markBufferEditedForceFullSync();
    }

    fn copySelectionToClipboard(self: *App) !void {
        const text = try self.selectedTextOwned();
        defer self.allocator.free(text);

        if (text.len == 0) {
            try self.setStatus("Copy: no selection");
            return;
        }

        self.writeClipboard(text) catch {
            try self.setStatus("Copy failed: clipboard unavailable");
            return;
        };
        try self.setStatus("Copied");
    }

    fn cutSelectionToClipboard(self: *App) !void {
        const text = try self.selectedTextOwned();
        defer self.allocator.free(text);
        if (text.len == 0) {
            try self.setStatus("Cut: no selection");
            return;
        }

        self.writeClipboard(text) catch {
            try self.setStatus("Cut failed: clipboard unavailable");
            return;
        };

        if (try self.deleteSelectionIfAny()) {
            self.markBufferEditedForceFullSync();
        }
        try self.setStatus("Cut");
    }

    fn pasteFromClipboard(self: *App) !void {
        const text = self.readClipboard() catch {
            try self.setStatus("Paste failed: clipboard unavailable");
            return;
        };
        defer self.allocator.free(text);

        if (text.len == 0) return;
        if (try self.applyBlockTextInput(text)) return;
        _ = try self.deleteSelectionIfAny();
        try self.queueIncrementalChange(self.editor.cursor, self.editor.cursor, text);
        try self.editor.buffer.insert(self.editor.cursor, text);
        self.editor.cursor += text.len;
        self.markBufferEdited();
    }

    fn selectedTextOwned(self: *App) ![]u8 {
        if (self.selectedRange()) |range| {
            const all = try self.editor.buffer.toOwnedBytes(self.allocator);
            defer self.allocator.free(all);
            return self.allocator.dupe(u8, all[range.start..range.end]);
        }

        if (self.blockSelectionSpec()) |block| {
            const all = try self.editor.buffer.toOwnedBytes(self.allocator);
            defer self.allocator.free(all);

            var out = std.array_list.Managed(u8).init(self.allocator);
            errdefer out.deinit();

            var line = block.start_line;
            while (line <= block.end_line) : (line += 1) {
                const start = self.editor.buffer.offsetFromLineVisualCol(line, block.start_col, terminal_tab_width);
                const end = self.editor.buffer.offsetFromLineVisualCol(line, block.end_col, terminal_tab_width);
                if (end > start) {
                    try out.appendSlice(all[start..end]);
                }
                if (line < block.end_line) try out.append('\n');
            }

            return out.toOwnedSlice();
        }

        return self.allocator.alloc(u8, 0);
    }

    fn writeClipboard(self: *App, text: []const u8) !void {
        var child = std.process.Child.init(&.{"pbcopy"}, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        if (child.stdin) |stdin| {
            defer stdin.close();
            try stdin.writeAll(text);
        }

        _ = try child.wait();
    }

    fn readClipboard(self: *App) ![]u8 {
        var child = std.process.Child.init(&.{"pbpaste"}, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        const stdout = child.stdout orelse return error.Unexpected;
        const bytes = try stdout.readToEndAlloc(self.allocator, 8 * 1024 * 1024);
        _ = try child.wait();
        return bytes;
    }

    fn executePaletteAction(self: *App, action: PaletteAction) !void {
        switch (action) {
            .save => try self.saveFile(),
            .quit => try self.requestQuit(),
            .undo => try self.executeCommand(.undo),
            .redo => try self.executeCommand(.redo),
            .restart_lsp => {
                if (self.editor.file_path) |path| {
                    self.lsp_state.client.startForFile(path, self.config) catch |err| switch (err) {
                        error.LspServerUnavailable => {
                            try self.setStatus("LSP restart failed: no matching adapter");
                            return;
                        },
                        else => {
                            try self.setStatus("LSP restart failed");
                            return;
                        },
                    };
                    try self.setStatus("LSP restarted");
                } else {
                    try self.setStatus("LSP restart skipped: no file path");
                }
            },
            .lsp_completion => try self.requestCompletion(false),
            .lsp_hover => try self.requestHover(false),
            .lsp_definition => try self.requestDefinition(),
            .lsp_references => try self.requestReferences(),
            .lsp_jump_back => try self.jumpBack(),
        }
    }

    fn saveFile(self: *App) !void {
        const path = self.editor.file_path orelse {
            try self.setStatus("Save failed: pass a file path (zicro <file>)");
            return;
        };

        _ = try self.flushPendingDidChange(true);
        try self.writeBufferToFile(path);
        try self.setStatus("Saved");

        self.lsp_state.client.didSave() catch |err| {
            try self.handleLspError(err);
        };
    }

    fn requestQuit(self: *App) !void {
        if (self.editor.dirty and !self.editor.confirm_quit) {
            self.editor.confirm_quit = true;
            try self.setStatus("Unsaved changes. Press Ctrl+Q again to quit.");
            return;
        }

        self.ui.running = false;
    }

    fn markBufferEdited(self: *App) void {
        self.editor.dirty = true;
        self.editor.confirm_quit = false;
        self.editor.search_match = null;
        if (self.config.lsp_hover_hide_on_type) {
            self.clearHoverTooltip();
        }
        if (self.ui.lsp_panel_mode == .completion) {
            self.closeLspPanel();
        }
        if (self.lsp_state.client.enabled) {
            self.lsp_state.client.clearDiagnostics();
        }
        self.editor.preferred_visual_col = null;
        self.queueDidChange();
        self.scheduleAutoRequestsAfterEdit();
    }

    fn markBufferEditedForceFullSync(self: *App) void {
        self.lsp_state.force_full_lsp_sync = true;
        self.clearPendingLspChanges();
        self.markBufferEdited();
    }

    fn beginSelection(self: *App) void {
        if (self.editor.selection_mode != .linear) {
            self.editor.selection_anchor = self.editor.cursor;
        }
        self.editor.selection_mode = .linear;
        if (self.editor.selection_anchor == null) self.editor.selection_anchor = self.editor.cursor;
    }

    fn beginBlockSelection(self: *App) void {
        if (self.editor.selection_mode != .block) {
            self.editor.selection_anchor = self.editor.cursor;
        }
        self.editor.selection_mode = .block;
        if (self.editor.selection_anchor == null) self.editor.selection_anchor = self.editor.cursor;
    }

    fn clearSelection(self: *App) void {
        self.editor.selection_anchor = null;
        self.editor.selection_mode = .linear;
    }

    pub fn selectedRange(self: *const App) ?ByteRange {
        if (self.editor.selection_mode != .linear) return null;
        const anchor = self.editor.selection_anchor orelse return null;
        if (anchor == self.editor.cursor) return null;
        const start = @min(anchor, self.editor.cursor);
        const end = @max(anchor, self.editor.cursor);
        return .{ .start = start, .end = end };
    }

    fn selectedLineRange(self: *const App) struct { start: usize, end: usize } {
        const anchor = self.editor.selection_anchor orelse {
            const line = self.editor.buffer.lineColFromOffset(self.editor.cursor).line;
            return .{ .start = line, .end = line };
        };

        if (anchor == self.editor.cursor) {
            const line = self.editor.buffer.lineColFromOffset(self.editor.cursor).line;
            return .{ .start = line, .end = line };
        }

        const start_line = self.editor.buffer.lineColFromOffset(@min(anchor, self.editor.cursor)).line;
        const end_offset = @max(anchor, self.editor.cursor) - 1;
        const end_line = self.editor.buffer.lineColFromOffset(end_offset).line;
        return .{ .start = start_line, .end = end_line };
    }

    fn hasBlockSelection(self: *const App) bool {
        const anchor = self.editor.selection_anchor orelse return false;
        return self.editor.selection_mode == .block and anchor != self.editor.cursor;
    }

    pub fn blockSelectionSpec(self: *const App) ?BlockSelection {
        if (!self.hasBlockSelection()) return null;
        const anchor = self.editor.selection_anchor.?;

        const anchor_line = self.editor.buffer.lineColFromOffset(anchor).line;
        const cursor_line = self.editor.buffer.lineColFromOffset(self.editor.cursor).line;
        const anchor_col = self.editor.buffer.visualColumnFromOffset(anchor, terminal_tab_width);
        const cursor_col = self.editor.buffer.visualColumnFromOffset(self.editor.cursor, terminal_tab_width);

        return .{
            .start_line = @min(anchor_line, cursor_line),
            .end_line = @max(anchor_line, cursor_line),
            .start_col = @min(anchor_col, cursor_col),
            .end_col = @max(anchor_col, cursor_col),
        };
    }

    fn applyBlockTextInput(self: *App, text: []const u8) !bool {
        const block = self.blockSelectionSpec() orelse return false;

        var line_i64: i64 = @intCast(block.end_line);
        while (line_i64 >= @as(i64, @intCast(block.start_line))) : (line_i64 -= 1) {
            const line_index: usize = @intCast(line_i64);
            const start_offset = self.editor.buffer.offsetFromLineVisualCol(line_index, block.start_col, terminal_tab_width);
            const end_offset = self.editor.buffer.offsetFromLineVisualCol(line_index, block.end_col, terminal_tab_width);
            if (end_offset > start_offset) {
                try self.editor.buffer.delete(start_offset, end_offset - start_offset);
            }
            try self.editor.buffer.insert(start_offset, text);
        }

        const target_col = block.start_col + displayWidth(text, terminal_tab_width);
        self.editor.cursor = self.editor.buffer.offsetFromLineVisualCol(block.end_line, target_col, terminal_tab_width);
        self.clearSelection();
        self.markBufferEditedForceFullSync();
        return true;
    }

    fn deleteSelectionIfAny(self: *App) !bool {
        if (self.blockSelectionSpec()) |block| {
            var line_i64: i64 = @intCast(block.end_line);
            while (line_i64 >= @as(i64, @intCast(block.start_line))) : (line_i64 -= 1) {
                const line_index: usize = @intCast(line_i64);
                const start_offset = self.editor.buffer.offsetFromLineVisualCol(line_index, block.start_col, terminal_tab_width);
                const end_offset = self.editor.buffer.offsetFromLineVisualCol(line_index, block.end_col, terminal_tab_width);
                if (end_offset > start_offset) {
                    try self.editor.buffer.delete(start_offset, end_offset - start_offset);
                }
            }
            self.editor.cursor = self.editor.buffer.offsetFromLineVisualCol(block.start_line, block.start_col, terminal_tab_width);
            self.clearSelection();
            return true;
        }

        if (self.selectedRange()) |range| {
            try self.queueIncrementalChange(range.start, range.end, "");
            try self.editor.buffer.delete(range.start, range.end - range.start);
            self.editor.cursor = range.start;
            self.clearSelection();
            return true;
        }
        return false;
    }

    fn queueIncrementalChange(self: *App, start_offset: usize, end_offset: usize, text: []const u8) !void {
        try app_lsp_sync.queueIncrementalChange(self, start_offset, end_offset, text);
    }

    fn lspPositionFromOffset(self: *const App, offset: usize) LspChangePosition {
        return app_lsp_sync.lspPositionFromOffset(self, offset);
    }

    fn utf16ColumnForOffset(self: *const App, line: usize, offset: usize) usize {
        return app_lsp_sync.utf16ColumnForOffset(self, line, offset);
    }

    fn offsetFromLspPosition(self: *const App, line: usize, character: usize) usize {
        return app_lsp_sync.offsetFromLspPosition(self, line, character);
    }

    fn clearPendingLspChanges(self: *App) void {
        app_lsp_sync.clearPendingLspChanges(self);
    }

    fn queueDidChange(self: *App) void {
        app_lsp_sync.queueDidChange(self);
    }

    fn flushPendingDidChange(self: *App, force: bool) !bool {
        return try app_lsp_sync.flushPendingDidChange(self, force);
    }

    fn handleLspError(self: *App, err: anyerror) !void {
        try app_lsp_sync.handleLspError(self, err);
        self.resetLspUiState();
    }

    fn writeBufferToFile(self: *App, path: []const u8) !void {
        const bytes = try self.editor.buffer.toOwnedBytes(self.allocator);
        defer self.allocator.free(bytes);

        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
        self.editor.dirty = false;
        self.editor.confirm_quit = false;
        self.editor.preferred_visual_col = null;
    }

    fn moveVertical(self: *App, delta: i32) void {
        app_editor_motion.moveVertical(self, delta, terminal_tab_width);
    }

    fn movePage(self: *App, delta: i32) void {
        app_editor_motion.movePage(self, delta, terminal_tab_width, top_bar_rows, footer_rows);
    }

    pub fn adjustScroll(self: *App, text_rows: usize) void {
        app_editor_motion.adjustScroll(self, text_rows);
    }

    pub fn editorTextRows(self: *const App) usize {
        return app_editor_motion.editorTextRows(self, top_bar_rows, footer_rows);
    }

    fn setStatus(self: *App, message: []const u8) !void {
        self.ui.status.clearRetainingCapacity();
        try self.ui.status.appendSlice(message);
        self.ui.needs_render = true;
    }

    fn setStatusFromPrefix(self: *App, prefix: []const u8, raw_text: []const u8) !void {
        var status = std.array_list.Managed(u8).init(self.allocator);
        defer status.deinit();

        try status.appendSlice(prefix);
        var index: usize = 0;
        while (index < raw_text.len and status.items.len < 300) {
            const ch = raw_text[index];
            if (ch == '\n' or ch == '\r' or ch == '\t') {
                try status.append(' ');
                index += 1;
                continue;
            }
            if (ch < 0x20 or ch == 0x7f) {
                index += 1;
                continue;
            }
            const step = layout.utf8Step(raw_text, index);
            try status.appendSlice(raw_text[index .. index + step]);
            index += step;
        }

        try self.setStatus(status.items);
    }

    fn resetLspUiState(self: *App) void {
        self.closeLspPanel();
        self.ui.lsp_completion_pending = false;
        self.ui.lsp_hover_pending = false;
        self.ui.lsp_definition_pending = false;
        self.ui.lsp_references_pending = false;
        self.ui.lsp_auto_completion_due_ns = 0;
        self.ui.lsp_auto_hover_due_ns = 0;
        self.ui.lsp_completion_request_auto = false;
        self.ui.lsp_hover_request_auto = false;
        self.clearHoverTooltip();
    }

    fn render(self: *App) !void {
        try app_ui_renderer.render(self, top_bar_rows, footer_rows, line_gutter_cols, terminal_tab_width);
    }

    fn renderLine(self: *App, out: *std.array_list.Managed(u8), line_index: usize, frame_allocator: std.mem.Allocator) !void {
        try app_ui_renderer.renderLine(self, out, line_index, frame_allocator, line_gutter_cols, terminal_tab_width);
    }

    fn renderDiagnosticsBar(self: *App, out: *std.array_list.Managed(u8), frame_allocator: std.mem.Allocator) !void {
        try app_ui_renderer.renderDiagnosticsBar(self, out, frame_allocator, terminal_tab_width);
    }

    fn renderStatusBar(self: *App, out: *std.array_list.Managed(u8), frame_allocator: std.mem.Allocator) !void {
        try app_ui_renderer.renderStatusBar(self, out, frame_allocator, terminal_tab_width);
    }

    fn renderMessageBar(self: *App, out: *std.array_list.Managed(u8)) !void {
        try app_ui_renderer.renderMessageBar(self, out, terminal_tab_width);
    }

    fn renderPrompt(self: *App, out: *std.array_list.Managed(u8)) !void {
        try app_ui_renderer.renderPrompt(self, out);
    }

    fn selectionRangeOnLine(self: *const App, line_index: usize, line_len: usize) ?ByteRange {
        return app_ui_renderer.selectionRangeOnLine(self, line_index, line_len, terminal_tab_width);
    }

    fn searchRangeOnLine(self: *const App, line_index: usize, line_len: usize) ?ByteRange {
        return app_ui_renderer.searchRangeOnLine(self, line_index, line_len);
    }

    fn diagnosticSymbolRangeOnLine(self: *const App, line_index: usize, line: []const u8) ?ByteRange {
        return app_ui_renderer.diagnosticSymbolRangeOnLine(self, line_index, line);
    }

    fn renderPalette(self: *App, out: *std.array_list.Managed(u8), frame_allocator: std.mem.Allocator) !void {
        try app_ui_renderer.renderPalette(self, out, frame_allocator);
    }

    fn paletteMatches(self: *App, allocator: std.mem.Allocator) !std.array_list.Managed(usize) {
        return app_ui_renderer.paletteMatches(self, allocator);
    }
};

const LineCommentInfo = struct {
    empty: bool,
    has_comment: bool,
    indent_col: usize,
    comment_col: usize,
};

fn lineCommentInfo(line: []const u8) LineCommentInfo {
    var idx: usize = 0;
    while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}

    if (idx >= line.len) {
        return .{
            .empty = true,
            .has_comment = false,
            .indent_col = idx,
            .comment_col = idx,
        };
    }

    const has_comment = idx + 1 < line.len and line[idx] == '/' and line[idx + 1] == '/';
    return .{
        .empty = false,
        .has_comment = has_comment,
        .indent_col = idx,
        .comment_col = idx,
    };
}

fn isIdentifierByte(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_';
}

fn completionSuffix(insert_text: []const u8, typed_prefix: []const u8) ?[]const u8 {
    if (typed_prefix.len == 0) return null;
    if (!std.mem.startsWith(u8, insert_text, typed_prefix)) return null;
    return insert_text[typed_prefix.len..];
}

fn regexMatchInLine(regex: *c.regex_t, line: []const u8, min_col: usize, allocator: std.mem.Allocator) !?ByteRange {
    if (min_col > line.len) return null;
    const sub = line[min_col..];

    var input = try allocator.alloc(u8, sub.len + 1);
    defer allocator.free(input);
    @memcpy(input[0..sub.len], sub);
    input[sub.len] = 0;

    var matches: [1]c.regmatch_t = undefined;
    const rc = c.regexec(regex, @ptrCast(input.ptr), 1, &matches, 0);
    if (rc != 0) return null;

    const start_raw = matches[0].rm_so;
    const end_raw = matches[0].rm_eo;
    if (start_raw < 0 or end_raw < 0) return null;

    const start_rel: usize = @intCast(start_raw);
    const end_rel: usize = @intCast(end_raw);
    if (end_rel <= start_rel) return null;

    return .{
        .start = min_col + start_rel,
        .end = min_col + end_rel,
    };
}

fn utf8PrevBoundary(bytes: []const u8, index_input: usize) usize {
    var index = @min(index_input, bytes.len);
    if (index == 0) return 0;

    index -= 1;
    while (index > 0 and layout.isUtf8ContinuationByte(bytes[index])) {
        index -= 1;
    }

    return index;
}

fn displayWidth(bytes: []const u8, tab_width_input: usize) usize {
    return layout.displayWidth(bytes, tab_width_input);
}

fn byteLimitForDisplayWidth(bytes: []const u8, max_width: usize, tab_width_input: usize) usize {
    return layout.byteLimitForDisplayWidth(bytes, max_width, tab_width_input);
}

fn clampU16(value: u64) u16 {
    const max_u16 = std.math.maxInt(u16);
    if (value > max_u16) return max_u16;
    return @intCast(value);
}

fn nsToTenthsMs(value_ns: i128) u16 {
    if (value_ns <= 0) return 0;
    const ns_u128: u128 = @intCast(value_ns);
    const tenths_u128 = ns_u128 / (std.time.ns_per_ms / 10);
    const capped = if (tenths_u128 > std.math.maxInt(u64)) std.math.maxInt(u64) else @as(u64, @intCast(tenths_u128));
    return clampU16(capped);
}

fn fpsTenthsFromFrameTenths(frame_tenths_ms: u16) u16 {
    if (frame_tenths_ms == 0) return 0;
    const numerator: u64 = 100000;
    const denominator: u64 = frame_tenths_ms;
    const fps_tenths = (numerator + denominator / 2) / denominator;
    return clampU16(fps_tenths);
}

test "frame helpers convert timings predictably" {
    try std.testing.expectEqual(@as(u16, 599), fpsTenthsFromFrameTenths(167));
    try std.testing.expectEqual(@as(u16, 301), nsToTenthsMs(30_150_000));
}

test "completion suffix uses typed prefix" {
    const suffix = completionSuffix("console", "con").?;
    try std.testing.expectEqualStrings("sole", suffix);
    try std.testing.expectEqual(@as(?[]const u8, null), completionSuffix("sole", "con"));
    try std.testing.expectEqual(@as(?[]const u8, null), completionSuffix("console", ""));
}
