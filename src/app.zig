const std = @import("std");
const Buffer = @import("editor/buffer.zig").Buffer;
const Terminal = @import("ui/terminal.zig").Terminal;
const KeyEvent = @import("ui/terminal.zig").KeyEvent;
const keymap = @import("keymap/keymap.zig");
const Command = keymap.Command;
const Config = @import("config.zig").Config;
const highlighter = @import("highlight/highlighter.zig");
const LspClient = @import("lsp/client.zig").Client;
const LspIncrementalChange = @import("lsp/client.zig").IncrementalChange;

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

const PaletteAction = enum {
    save,
    quit,
    undo,
    redo,
    restart_lsp,
};

const PaletteEntry = struct {
    label: []const u8,
    action: PaletteAction,
};

const palette_entries = [_]PaletteEntry{
    .{ .label = "File: Save", .action = .save },
    .{ .label = "File: Quit", .action = .quit },
    .{ .label = "Edit: Undo", .action = .undo },
    .{ .label = "Edit: Redo", .action = .redo },
    .{ .label = "LSP: Restart", .action = .restart_lsp },
};

const PaletteState = struct {
    active: bool,
    query: std.array_list.Managed(u8),
    selected: usize,

    fn init(allocator: std.mem.Allocator) PaletteState {
        return .{
            .active = false,
            .query = std.array_list.Managed(u8).init(allocator),
            .selected = 0,
        };
    }

    fn deinit(self: *PaletteState) void {
        self.query.deinit();
    }

    fn clear(self: *PaletteState) void {
        self.query.clearRetainingCapacity();
        self.selected = 0;
    }
};

const LspChangePosition = struct {
    line: usize,
    character: usize,
};

const PendingLspChange = struct {
    start: LspChangePosition,
    end: LspChangePosition,
    text: []u8,
};

const PromptMode = enum {
    goto_line,
    regex_search,
};

const PromptState = struct {
    active: bool,
    mode: PromptMode,
    query: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator) PromptState {
        return .{
            .active = false,
            .mode = .goto_line,
            .query = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *PromptState) void {
        self.query.deinit();
    }

    fn open(self: *PromptState, mode: PromptMode) void {
        self.mode = mode;
        self.active = true;
        self.query.clearRetainingCapacity();
    }

    fn close(self: *PromptState) void {
        self.active = false;
        self.query.clearRetainingCapacity();
    }
};

const ByteRange = struct {
    start: usize,
    end: usize,
};

const SearchMatch = struct {
    start: usize,
    end: usize,
};

const SelectionMode = enum {
    linear,
    block,
};

const BlockSelection = struct {
    start_line: usize,
    end_line: usize,
    start_col: usize,
    end_col: usize,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    terminal: Terminal,
    buffer: Buffer,
    render_arena: std.heap.ArenaAllocator,
    file_path: ?[]u8,
    cursor: usize,
    selection_anchor: ?usize,
    selection_mode: SelectionMode,
    search_match: ?SearchMatch,
    scroll_y: usize,
    status: std.array_list.Managed(u8),
    dirty: bool,
    confirm_quit: bool,
    running: bool,
    needs_render: bool,
    language: highlighter.Language,
    palette: PaletteState,
    lsp: LspClient,
    pending_lsp_sync: bool,
    next_lsp_flush_ns: i128,
    pending_lsp_changes: std.array_list.Managed(PendingLspChange),
    force_full_lsp_sync: bool,
    prompt: PromptState,
    preferred_visual_col: ?usize,
    lsp_change_delay_ns: i128,

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
            .buffer = try Buffer.fromBytes(allocator, file_bytes),
            .render_arena = std.heap.ArenaAllocator.init(allocator),
            .file_path = file_path,
            .cursor = 0,
            .selection_anchor = null,
            .selection_mode = .linear,
            .search_match = null,
            .scroll_y = 0,
            .status = std.array_list.Managed(u8).init(allocator),
            .dirty = false,
            .confirm_quit = false,
            .running = true,
            .needs_render = true,
            .language = highlighter.detectLanguage(file_path_opt),
            .palette = PaletteState.init(allocator),
            .lsp = LspClient.init(allocator),
            .pending_lsp_sync = false,
            .next_lsp_flush_ns = 0,
            .pending_lsp_changes = std.array_list.Managed(PendingLspChange).init(allocator),
            .force_full_lsp_sync = false,
            .prompt = PromptState.init(allocator),
            .preferred_visual_col = null,
            .lsp_change_delay_ns = @as(i128, @intCast(config.lsp_change_debounce_ms)) * std.time.ns_per_ms,
        };

        app.lsp.setDidSavePulseDebounceMs(config.lsp_did_save_debounce_ms);

        try app.setStatus("Ctrl+S save | Ctrl+Q quit | Ctrl+P palette | Ctrl+Z/Ctrl+Y undo/redo");

        if (config.enable_lsp and app.file_path != null) {
            app.lsp.startForFile(app.file_path.?) catch |err| switch (err) {
                error.FileTooBig => try app.setStatus("LSP disabled: file too large for didOpen sync"),
                else => try app.setStatus("LSP disabled: server not found or failed to spawn"),
            };
        }

        return app;
    }

    pub fn deinit(self: *App) void {
        self.clearPendingLspChanges();
        self.pending_lsp_changes.deinit();
        self.prompt.deinit();
        self.lsp.deinit();
        self.palette.deinit();
        self.status.deinit();
        self.buffer.deinit();
        self.render_arena.deinit();
        if (self.file_path) |path| self.allocator.free(path);
        self.terminal.deinit();
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            var handled_events: usize = 0;
            while (handled_events < max_events_per_tick) {
                const event_opt = try self.terminal.readKey();
                if (event_opt) |event| {
                    if (self.palette.active) {
                        try self.handlePaletteInput(event);
                    } else if (self.prompt.active) {
                        try self.handlePromptInput(event);
                    } else {
                        try self.handleEditorInput(event);
                    }
                    self.needs_render = true;
                    handled_events += 1;
                    continue;
                }
                break;
            }

            if (self.lsp.enabled) {
                const diagnostics_changed = self.lsp.poll() catch |err| blk: {
                    try self.handleLspError(err);
                    break :blk true;
                };
                if (diagnostics_changed) {
                    self.needs_render = true;
                }
            }

            if (try self.flushPendingDidChange(false)) {
                self.needs_render = true;
            }

            if (self.needs_render) {
                try self.render();
                self.needs_render = false;
            }

            if (handled_events > 0) continue;

            if (self.pending_lsp_sync) {
                const now = std.time.nanoTimestamp();
                if (self.next_lsp_flush_ns > now) {
                    const remaining = self.next_lsp_flush_ns - now;
                    const wait_ns: u64 = @intCast(@min(remaining, @as(i128, idle_sleep_ns)));
                    std.Thread.sleep(wait_ns);
                    continue;
                }
            }

            std.Thread.sleep(idle_sleep_ns);
        }
    }

    fn handleEditorInput(self: *App, event: KeyEvent) !void {
        if (keymap.mapEditor(event)) |cmd| {
            try self.executeCommand(cmd);
            return;
        }

        switch (event) {
            .char => |ch| {
                if (try self.applyBlockTextInput(&[_]u8{ch})) return;
                _ = try self.deleteSelectionIfAny();
                try self.queueIncrementalChange(self.cursor, self.cursor, &[_]u8{ch});
                try self.buffer.insert(self.cursor, &[_]u8{ch});
                self.cursor += 1;
                self.markBufferEdited();
            },
            .text => |text| {
                if (text.len == 0) return;
                if (try self.applyBlockTextInput(text)) return;
                _ = try self.deleteSelectionIfAny();
                try self.queueIncrementalChange(self.cursor, self.cursor, text);
                try self.buffer.insert(self.cursor, text);
                self.cursor += text.len;
                self.markBufferEdited();
            },
            .tab => {
                var spaces = [_]u8{' '} ** 16;
                const count = @min(@as(usize, self.config.tab_width), spaces.len);
                if (try self.applyBlockTextInput(spaces[0..count])) return;
                _ = try self.deleteSelectionIfAny();
                try self.queueIncrementalChange(self.cursor, self.cursor, spaces[0..count]);
                try self.buffer.insert(self.cursor, spaces[0..count]);
                self.cursor += count;
                self.markBufferEdited();
            },
            else => {},
        }
    }

    fn executeCommand(self: *App, command: Command) !void {
        switch (command) {
            .save => try self.saveFile(),
            .quit => try self.requestQuit(),
            .copy => try self.copySelectionToClipboard(),
            .cut => try self.cutSelectionToClipboard(),
            .paste => try self.pasteFromClipboard(),
            .goto_line => {
                self.prompt.open(.goto_line);
                self.palette.active = false;
            },
            .regex_search => {
                self.prompt.open(.regex_search);
                self.palette.active = false;
            },
            .toggle_comment => try self.toggleCommentSelection(),
            .show_palette => {
                self.palette.active = true;
                self.palette.clear();
                self.prompt.close();
                self.preferred_visual_col = null;
            },
            .move_left => {
                self.clearSelection();
                const next = self.buffer.prevCodepointStart(self.cursor);
                if (next != self.cursor) {
                    self.cursor = next;
                }
                self.preferred_visual_col = null;
            },
            .move_right => {
                self.clearSelection();
                const next = self.buffer.nextCodepointEnd(self.cursor);
                if (next != self.cursor) {
                    self.cursor = next;
                }
                self.preferred_visual_col = null;
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
                const pos = self.buffer.lineColFromOffset(self.cursor);
                self.cursor = self.buffer.offsetFromLineCol(pos.line, 0);
                self.preferred_visual_col = null;
            },
            .move_end => {
                self.clearSelection();
                const pos = self.buffer.lineColFromOffset(self.cursor);
                self.cursor = self.buffer.offsetFromLineCol(pos.line, std.math.maxInt(usize));
                self.preferred_visual_col = null;
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
                const next = self.buffer.prevCodepointStart(self.cursor);
                if (next != self.cursor) self.cursor = next;
                self.preferred_visual_col = null;
            },
            .select_right => {
                self.beginSelection();
                const next = self.buffer.nextCodepointEnd(self.cursor);
                if (next != self.cursor) self.cursor = next;
                self.preferred_visual_col = null;
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
                const pos = self.buffer.lineColFromOffset(self.cursor);
                self.cursor = self.buffer.offsetFromLineCol(pos.line, 0);
                self.preferred_visual_col = null;
            },
            .select_end => {
                self.beginSelection();
                const pos = self.buffer.lineColFromOffset(self.cursor);
                self.cursor = self.buffer.offsetFromLineCol(pos.line, std.math.maxInt(usize));
                self.preferred_visual_col = null;
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
                const next = self.buffer.prevCodepointStart(self.cursor);
                if (next != self.cursor) self.cursor = next;
                self.preferred_visual_col = null;
            },
            .block_select_right => {
                self.beginBlockSelection();
                const next = self.buffer.nextCodepointEnd(self.cursor);
                if (next != self.cursor) self.cursor = next;
                self.preferred_visual_col = null;
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
                self.cursor = self.buffer.moveWordLeft(self.cursor);
                self.preferred_visual_col = null;
            },
            .word_right => {
                self.clearSelection();
                self.cursor = self.buffer.moveWordRight(self.cursor);
                self.preferred_visual_col = null;
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
                if (self.cursor > 0) {
                    const start = self.buffer.prevCodepointStart(self.cursor);
                    if (start < self.cursor) {
                        try self.queueIncrementalChange(start, self.cursor, "");
                        try self.buffer.delete(start, self.cursor - start);
                        self.cursor = start;
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
                if (self.cursor < self.buffer.len()) {
                    const end = self.buffer.nextCodepointEnd(self.cursor);
                    if (end > self.cursor) {
                        try self.queueIncrementalChange(self.cursor, end, "");
                        try self.buffer.delete(self.cursor, end - self.cursor);
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
                try self.queueIncrementalChange(self.cursor, self.cursor, "\n");
                try self.buffer.insert(self.cursor, "\n");
                self.cursor += 1;
                self.markBufferEdited();
            },
            .undo => {
                try self.buffer.undo();
                if (self.cursor > self.buffer.len()) self.cursor = self.buffer.len();
                self.clearSelection();
                self.markBufferEditedForceFullSync();
            },
            .redo => {
                try self.buffer.redo();
                if (self.cursor > self.buffer.len()) self.cursor = self.buffer.len();
                self.clearSelection();
                self.markBufferEditedForceFullSync();
            },
        }
    }

    fn handlePaletteInput(self: *App, event: KeyEvent) !void {
        switch (event) {
            .escape => {
                self.palette.active = false;
            },
            .backspace => {
                if (self.palette.query.items.len > 0) {
                    const prev = utf8PrevBoundary(self.palette.query.items, self.palette.query.items.len);
                    self.palette.query.items.len = prev;
                    self.palette.selected = 0;
                }
            },
            .up => {
                if (self.palette.selected > 0) self.palette.selected -= 1;
            },
            .down => {
                self.palette.selected += 1;
            },
            .enter => {
                const matches = try self.paletteMatches(self.allocator);
                defer matches.deinit();

                if (matches.items.len == 0) {
                    self.palette.active = false;
                    return;
                }

                const index = @min(self.palette.selected, matches.items.len - 1);
                const action = palette_entries[matches.items[index]].action;
                self.palette.active = false;
                try self.executePaletteAction(action);
            },
            .char => |ch| {
                if (std.ascii.isPrint(ch) or ch == ' ') {
                    try self.palette.query.append(ch);
                    self.palette.selected = 0;
                }
            },
            .text => |text| {
                if (text.len > 0) {
                    try self.palette.query.appendSlice(text);
                    self.palette.selected = 0;
                }
            },
            .ctrl => |ch| {
                if (ch == 'p') self.palette.active = false;
            },
            else => {},
        }
    }

    fn handlePromptInput(self: *App, event: KeyEvent) !void {
        switch (event) {
            .escape => self.prompt.close(),
            .backspace => {
                if (self.prompt.query.items.len > 0) {
                    const prev = utf8PrevBoundary(self.prompt.query.items, self.prompt.query.items.len);
                    self.prompt.query.items.len = prev;
                    try self.updateRegexPromptPreview();
                }
            },
            .enter => try self.executePrompt(),
            .up => try self.regexPrevFromPrompt(),
            .down => try self.regexNextFromPrompt(),
            .char => |ch| {
                if (std.ascii.isPrint(ch) or ch == ' ') {
                    try self.prompt.query.append(ch);
                    try self.updateRegexPromptPreview();
                }
            },
            .text => |text| {
                if (text.len > 0) {
                    try self.prompt.query.appendSlice(text);
                    try self.updateRegexPromptPreview();
                }
            },
            .ctrl => |ch| {
                if (ch == 'g' or ch == 'f') self.prompt.close();
            },
            else => {},
        }
    }

    fn executePrompt(self: *App) !void {
        const mode = self.prompt.mode;
        const query = try self.allocator.dupe(u8, self.prompt.query.items);
        defer self.allocator.free(query);
        self.prompt.close();

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

        const line_index = @min(line_1_based - 1, self.buffer.lineCount() - 1);
        self.cursor = self.buffer.offsetFromLineCol(line_index, 0);
        self.clearSelection();
        self.preferred_visual_col = null;
        try self.setStatus("Moved");
    }

    fn executeRegexSearch(self: *App, query: []const u8) !void {
        const trimmed = std.mem.trim(u8, query, " \t");
        if (trimmed.len == 0) {
            self.search_match = null;
            try self.setStatus("Regex search: empty pattern");
            return;
        }

        const start_offset = if (self.cursor < self.buffer.len()) self.cursor + 1 else self.cursor;
        const match = self.findRegexForward(trimmed, start_offset) catch |err| switch (err) {
            error.InvalidRegex => {
                self.search_match = null;
                try self.setStatus("Regex search: invalid pattern");
                return;
            },
            else => return err,
        };

        if (match) |found| {
            self.cursor = found.start;
            self.search_match = found;
            self.clearSelection();
            self.preferred_visual_col = null;
            try self.setStatus("Regex match found");
        } else {
            self.search_match = null;
            try self.setStatus("Regex: no matches");
        }
    }

    fn updateRegexPromptPreview(self: *App) !void {
        if (!self.prompt.active or self.prompt.mode != .regex_search) return;
        const pattern = std.mem.trim(u8, self.prompt.query.items, " \t");
        if (pattern.len == 0) {
            self.search_match = null;
            return;
        }

        const start_offset = if (self.cursor < self.buffer.len()) self.cursor else self.buffer.len();
        const match = self.findRegexForward(pattern, start_offset) catch |err| switch (err) {
            error.InvalidRegex => {
                self.search_match = null;
                return;
            },
            else => return err,
        };

        if (match) |found| {
            self.applySearchMatch(found);
        } else {
            self.search_match = null;
        }
    }

    fn regexNextFromPrompt(self: *App) !void {
        if (!self.prompt.active or self.prompt.mode != .regex_search) return;
        const pattern = std.mem.trim(u8, self.prompt.query.items, " \t");
        if (pattern.len == 0) return;

        const base = if (self.search_match) |found| found.start else self.cursor;
        const start_offset = if (base < self.buffer.len()) base + 1 else base;
        const match = try self.findRegexForward(pattern, start_offset);
        if (match) |found| {
            self.applySearchMatch(found);
            try self.setStatus("Regex: next match");
        } else {
            self.search_match = null;
            try self.setStatus("Regex: no matches");
        }
    }

    fn regexPrevFromPrompt(self: *App) !void {
        if (!self.prompt.active or self.prompt.mode != .regex_search) return;
        const pattern = std.mem.trim(u8, self.prompt.query.items, " \t");
        if (pattern.len == 0) return;

        const start_offset = if (self.search_match) |found| found.start else self.cursor;
        const match = try self.findRegexBackward(pattern, start_offset);
        if (match) |found| {
            self.applySearchMatch(found);
            try self.setStatus("Regex: previous match");
        } else {
            self.search_match = null;
            try self.setStatus("Regex: no matches");
        }
    }

    fn applySearchMatch(self: *App, found: SearchMatch) void {
        self.cursor = found.start;
        self.search_match = found;
        self.centerCursorInViewport();
        self.clearSelection();
        self.preferred_visual_col = null;
    }

    fn centerCursorInViewport(self: *App) void {
        const text_rows = self.editorTextRows();
        const line_count = self.buffer.lineCount();
        if (line_count <= text_rows) {
            self.scroll_y = 0;
            return;
        }

        const line = self.buffer.lineColFromOffset(self.cursor).line;
        const half = text_rows / 2;
        const desired_top = if (line > half) line - half else 0;
        const max_top = line_count - text_rows;
        self.scroll_y = @min(desired_top, max_top);
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

        const start_offset = @min(start_offset_input, self.buffer.len());
        const start_pos = self.buffer.lineColFromOffset(start_offset);
        const line_count = self.buffer.lineCount();

        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            const start_line = if (pass == 0) start_pos.line else 0;
            const end_line = if (pass == 0) line_count else start_pos.line + 1;

            var line = start_line;
            while (line < end_line) : (line += 1) {
                const line_bytes = try self.buffer.lineOwned(self.allocator, line);
                defer self.allocator.free(line_bytes);

                const line_start = self.buffer.offsetFromLineCol(line, 0);
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

        const start_offset = @min(start_offset_input, self.buffer.len());
        const line_count = self.buffer.lineCount();

        var best_before: ?SearchMatch = null;
        var best_any: ?SearchMatch = null;

        var line: usize = 0;
        while (line < line_count) : (line += 1) {
            const line_bytes = try self.buffer.lineOwned(self.allocator, line);
            defer self.allocator.free(line_bytes);
            const line_start = self.buffer.offsetFromLineCol(line, 0);

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
            const line = try self.buffer.lineOwned(self.allocator, scan);
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
            const line = try self.buffer.lineOwned(self.allocator, line_index);
            defer self.allocator.free(line);

            const info = lineCommentInfo(line);
            if (info.empty) continue;

            const line_start = self.buffer.offsetFromLineCol(line_index, 0);
            if (uncomment) {
                if (!info.has_comment) continue;
                const comment_at = line_start + info.comment_col;
                var remove_len: usize = 2;
                if (info.comment_col + 2 < line.len and line[info.comment_col + 2] == ' ') {
                    remove_len = 3;
                }
                try self.buffer.delete(comment_at, remove_len);
            } else {
                const insert_at = line_start + info.indent_col;
                try self.buffer.insert(insert_at, "// ");
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
        try self.queueIncrementalChange(self.cursor, self.cursor, text);
        try self.buffer.insert(self.cursor, text);
        self.cursor += text.len;
        self.markBufferEdited();
    }

    fn selectedTextOwned(self: *App) ![]u8 {
        if (self.selectedRange()) |range| {
            const all = try self.buffer.toOwnedBytes(self.allocator);
            defer self.allocator.free(all);
            return self.allocator.dupe(u8, all[range.start..range.end]);
        }

        if (self.blockSelectionSpec()) |block| {
            const all = try self.buffer.toOwnedBytes(self.allocator);
            defer self.allocator.free(all);

            var out = std.array_list.Managed(u8).init(self.allocator);
            errdefer out.deinit();

            var line = block.start_line;
            while (line <= block.end_line) : (line += 1) {
                const start = self.buffer.offsetFromLineVisualCol(line, block.start_col, terminal_tab_width);
                const end = self.buffer.offsetFromLineVisualCol(line, block.end_col, terminal_tab_width);
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
                if (self.file_path) |path| {
                    self.lsp.startForFile(path) catch {
                        try self.setStatus("LSP restart failed");
                        return;
                    };
                    try self.setStatus("LSP restarted");
                } else {
                    try self.setStatus("LSP restart skipped: no file path");
                }
            },
        }
    }

    fn saveFile(self: *App) !void {
        const path = self.file_path orelse {
            try self.setStatus("Save failed: pass a file path (zicro <file>)");
            return;
        };

        _ = try self.flushPendingDidChange(true);
        try self.writeBufferToFile(path);
        try self.setStatus("Saved");

        self.lsp.didSave() catch |err| {
            try self.handleLspError(err);
        };
    }

    fn requestQuit(self: *App) !void {
        if (self.dirty and !self.confirm_quit) {
            self.confirm_quit = true;
            try self.setStatus("Unsaved changes. Press Ctrl+Q again to quit.");
            return;
        }

        self.running = false;
    }

    fn markBufferEdited(self: *App) void {
        self.dirty = true;
        self.confirm_quit = false;
        self.search_match = null;
        if (self.lsp.enabled) {
            self.lsp.clearDiagnostics();
        }
        self.preferred_visual_col = null;
        self.queueDidChange();
    }

    fn markBufferEditedForceFullSync(self: *App) void {
        self.force_full_lsp_sync = true;
        self.clearPendingLspChanges();
        self.markBufferEdited();
    }

    fn beginSelection(self: *App) void {
        if (self.selection_mode != .linear) {
            self.selection_anchor = self.cursor;
        }
        self.selection_mode = .linear;
        if (self.selection_anchor == null) self.selection_anchor = self.cursor;
    }

    fn beginBlockSelection(self: *App) void {
        if (self.selection_mode != .block) {
            self.selection_anchor = self.cursor;
        }
        self.selection_mode = .block;
        if (self.selection_anchor == null) self.selection_anchor = self.cursor;
    }

    fn clearSelection(self: *App) void {
        self.selection_anchor = null;
        self.selection_mode = .linear;
    }

    fn selectedRange(self: *const App) ?ByteRange {
        if (self.selection_mode != .linear) return null;
        const anchor = self.selection_anchor orelse return null;
        if (anchor == self.cursor) return null;
        const start = @min(anchor, self.cursor);
        const end = @max(anchor, self.cursor);
        return .{ .start = start, .end = end };
    }

    fn selectedLineRange(self: *const App) struct { start: usize, end: usize } {
        const anchor = self.selection_anchor orelse {
            const line = self.buffer.lineColFromOffset(self.cursor).line;
            return .{ .start = line, .end = line };
        };

        if (anchor == self.cursor) {
            const line = self.buffer.lineColFromOffset(self.cursor).line;
            return .{ .start = line, .end = line };
        }

        const start_line = self.buffer.lineColFromOffset(@min(anchor, self.cursor)).line;
        const end_offset = @max(anchor, self.cursor) - 1;
        const end_line = self.buffer.lineColFromOffset(end_offset).line;
        return .{ .start = start_line, .end = end_line };
    }

    fn hasBlockSelection(self: *const App) bool {
        const anchor = self.selection_anchor orelse return false;
        return self.selection_mode == .block and anchor != self.cursor;
    }

    fn blockSelectionSpec(self: *const App) ?BlockSelection {
        if (!self.hasBlockSelection()) return null;
        const anchor = self.selection_anchor.?;

        const anchor_line = self.buffer.lineColFromOffset(anchor).line;
        const cursor_line = self.buffer.lineColFromOffset(self.cursor).line;
        const anchor_col = self.buffer.visualColumnFromOffset(anchor, terminal_tab_width);
        const cursor_col = self.buffer.visualColumnFromOffset(self.cursor, terminal_tab_width);

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
            const start_offset = self.buffer.offsetFromLineVisualCol(line_index, block.start_col, terminal_tab_width);
            const end_offset = self.buffer.offsetFromLineVisualCol(line_index, block.end_col, terminal_tab_width);
            if (end_offset > start_offset) {
                try self.buffer.delete(start_offset, end_offset - start_offset);
            }
            try self.buffer.insert(start_offset, text);
        }

        const target_col = block.start_col + displayWidth(text, terminal_tab_width);
        self.cursor = self.buffer.offsetFromLineVisualCol(block.end_line, target_col, terminal_tab_width);
        self.clearSelection();
        self.markBufferEditedForceFullSync();
        return true;
    }

    fn deleteSelectionIfAny(self: *App) !bool {
        if (self.blockSelectionSpec()) |block| {
            var line_i64: i64 = @intCast(block.end_line);
            while (line_i64 >= @as(i64, @intCast(block.start_line))) : (line_i64 -= 1) {
                const line_index: usize = @intCast(line_i64);
                const start_offset = self.buffer.offsetFromLineVisualCol(line_index, block.start_col, terminal_tab_width);
                const end_offset = self.buffer.offsetFromLineVisualCol(line_index, block.end_col, terminal_tab_width);
                if (end_offset > start_offset) {
                    try self.buffer.delete(start_offset, end_offset - start_offset);
                }
            }
            self.cursor = self.buffer.offsetFromLineVisualCol(block.start_line, block.start_col, terminal_tab_width);
            self.clearSelection();
            return true;
        }

        if (self.selectedRange()) |range| {
            try self.queueIncrementalChange(range.start, range.end, "");
            try self.buffer.delete(range.start, range.end - range.start);
            self.cursor = range.start;
            self.clearSelection();
            return true;
        }
        return false;
    }

    fn queueIncrementalChange(self: *App, start_offset: usize, end_offset: usize, text: []const u8) !void {
        if (!self.lsp.enabled) return;

        try self.pending_lsp_changes.append(.{
            .start = self.lspPositionFromOffset(start_offset),
            .end = self.lspPositionFromOffset(end_offset),
            .text = try self.allocator.dupe(u8, text),
        });
    }

    fn lspPositionFromOffset(self: *const App, offset: usize) LspChangePosition {
        const aligned = self.buffer.alignToCodepointStart(offset);
        const pos = self.buffer.lineColFromOffset(aligned);
        return .{
            .line = pos.line,
            .character = self.utf16ColumnForOffset(pos.line, aligned),
        };
    }

    fn utf16ColumnForOffset(self: *const App, line: usize, offset: usize) usize {
        const line_start = self.buffer.offsetFromLineCol(line, 0);
        var cursor = line_start;
        var utf16_col: usize = 0;

        while (cursor < offset) {
            const next = self.buffer.nextCodepointEnd(cursor);
            if (next <= cursor) break;
            const step = next - cursor;
            utf16_col += if (step == 4) 2 else 1;
            cursor = next;
        }

        return utf16_col;
    }

    fn clearPendingLspChanges(self: *App) void {
        for (self.pending_lsp_changes.items) |change| {
            self.allocator.free(change.text);
        }
        self.pending_lsp_changes.clearRetainingCapacity();
    }

    fn queueDidChange(self: *App) void {
        if (!self.lsp.enabled) return;
        self.pending_lsp_sync = true;
        self.next_lsp_flush_ns = std.time.nanoTimestamp() + self.lsp_change_delay_ns;
    }

    fn flushPendingDidChange(self: *App, force: bool) !bool {
        if (!self.pending_lsp_sync or !self.lsp.enabled) return false;
        if (!force and std.time.nanoTimestamp() < self.next_lsp_flush_ns) return false;

        self.pending_lsp_sync = false;
        defer {
            self.force_full_lsp_sync = false;
            self.clearPendingLspChanges();
        }

        const use_incremental = !self.force_full_lsp_sync and
            self.pending_lsp_changes.items.len > 0 and
            self.lsp.supportsIncrementalSync();

        if (use_incremental) {
            for (self.pending_lsp_changes.items) |change| {
                const incremental: LspIncrementalChange = .{
                    .start_line = change.start.line,
                    .start_character = change.start.character,
                    .end_line = change.end.line,
                    .end_character = change.end.character,
                    .text = change.text,
                };
                self.lsp.didChangeIncremental(incremental) catch |err| {
                    try self.handleLspError(err);
                    return true;
                };
            }
        } else {
            const bytes = try self.buffer.toOwnedBytes(self.allocator);
            defer self.allocator.free(bytes);

            self.lsp.didChange(bytes) catch |err| {
                try self.handleLspError(err);
                return true;
            };
        }

        if (self.config.autosave) {
            if (self.file_path) |path| {
                try self.writeBufferToFile(path);
                try self.setStatus("Saved");
                self.lsp.didSave() catch |err| {
                    try self.handleLspError(err);
                };
            }
        }

        return true;
    }

    fn handleLspError(self: *App, _: anyerror) !void {
        self.pending_lsp_sync = false;
        self.force_full_lsp_sync = false;
        self.clearPendingLspChanges();
        self.lsp.stop();
        try self.setStatus("LSP disconnected; disabled");
    }

    fn writeBufferToFile(self: *App, path: []const u8) !void {
        const bytes = try self.buffer.toOwnedBytes(self.allocator);
        defer self.allocator.free(bytes);

        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
        self.dirty = false;
        self.confirm_quit = false;
        self.preferred_visual_col = null;
    }

    fn moveVertical(self: *App, delta: i32) void {
        const pos = self.buffer.lineColFromOffset(self.cursor);
        const visual_col = self.preferred_visual_col orelse self.buffer.visualColumnFromOffset(self.cursor, terminal_tab_width);
        const line_i64 = @as(i64, @intCast(pos.line));
        const target_line_i64 = std.math.clamp(line_i64 + delta, 0, @as(i64, @intCast(self.buffer.lineCount() - 1)));
        const target_line: usize = @intCast(target_line_i64);
        self.cursor = self.buffer.offsetFromLineVisualCol(target_line, visual_col, terminal_tab_width);
        self.preferred_visual_col = visual_col;
    }

    fn movePage(self: *App, delta: i32) void {
        const page = self.editorTextRows();
        const step: i64 = @as(i64, @intCast(page));
        const signed = if (delta < 0) -step else step;

        const pos = self.buffer.lineColFromOffset(self.cursor);
        const visual_col = self.preferred_visual_col orelse self.buffer.visualColumnFromOffset(self.cursor, terminal_tab_width);
        const line_i64 = @as(i64, @intCast(pos.line));
        const max_line = @as(i64, @intCast(self.buffer.lineCount() - 1));
        const target_line_i64 = std.math.clamp(line_i64 + signed, 0, max_line);
        const target_line: usize = @intCast(target_line_i64);

        self.cursor = self.buffer.offsetFromLineVisualCol(target_line, visual_col, terminal_tab_width);
        self.preferred_visual_col = visual_col;
    }

    fn adjustScroll(self: *App, text_rows: usize) void {
        const pos = self.buffer.lineColFromOffset(self.cursor);

        if (pos.line < self.scroll_y) {
            self.scroll_y = pos.line;
        }

        if (pos.line >= self.scroll_y + text_rows) {
            self.scroll_y = pos.line - text_rows + 1;
        }
    }

    fn editorTextRows(self: *const App) usize {
        const reserved_rows = top_bar_rows + footer_rows;
        return if (self.terminal.height > reserved_rows) self.terminal.height - reserved_rows else 1;
    }

    fn setStatus(self: *App, message: []const u8) !void {
        self.status.clearRetainingCapacity();
        try self.status.appendSlice(message);
        self.needs_render = true;
    }

    fn render(self: *App) !void {
        _ = self.render_arena.reset(.retain_capacity);
        const frame_allocator = self.render_arena.allocator();
        var out = std.array_list.Managed(u8).init(frame_allocator);

        const text_rows = self.editorTextRows();
        self.adjustScroll(text_rows);

        // Hide cursor while frame is being drawn to avoid caret trails.
        try out.appendSlice("\x1b[?25l\x1b[H");
        try self.renderDiagnosticsBar(&out, frame_allocator);
        try out.appendSlice("\x1b[K\r\n");

        var row: usize = 0;
        while (row < text_rows) : (row += 1) {
            const line_index = self.scroll_y + row;

            if (line_index < self.buffer.lineCount()) {
                try self.renderLine(&out, line_index, frame_allocator);
            } else {
                try out.appendSlice("\x1b[90m~\x1b[0m");
            }

            try out.appendSlice("\x1b[K\r\n");
        }

        try self.renderStatusBar(&out, frame_allocator);
        try out.appendSlice("\x1b[K\r\n");
        try self.renderMessageBar(&out);
        try out.appendSlice("\x1b[K");

        if (self.prompt.active) {
            try self.renderPrompt(&out);
        }

        if (self.palette.active) {
            try self.renderPalette(&out, frame_allocator);
            const query_col = displayWidth(self.palette.query.items, terminal_tab_width);
            const cursor_col = @min(query_col + 12, self.terminal.width);
            try out.writer().print("\x1b[{d};{d}H", .{ 2, cursor_col });
        } else if (self.prompt.active) {
            const label = promptLabel(self.prompt.mode);
            const cursor_col = @min(displayWidth(label, terminal_tab_width) + displayWidth(self.prompt.query.items, terminal_tab_width) + 2, self.terminal.width);
            try out.writer().print("\x1b[{d};{d}H", .{ 2, cursor_col });
        } else {
            const pos = self.buffer.lineColFromOffset(self.cursor);
            const screen_row = top_bar_rows + (pos.line - self.scroll_y) + 1;
            const visual_col = self.buffer.visualColumnFromOffset(self.cursor, terminal_tab_width);
            const screen_col = @min(visual_col + line_gutter_cols + 1, self.terminal.width);
            try out.writer().print("\x1b[{d};{d}H", .{ screen_row, screen_col });
        }

        try out.appendSlice("\x1b[?25h");
        try self.terminal.writeAll(out.items);
        try self.terminal.flush();
    }

    fn renderLine(self: *App, out: *std.array_list.Managed(u8), line_index: usize, frame_allocator: std.mem.Allocator) !void {
        const line = try self.buffer.lineOwned(frame_allocator, line_index);
        const spans = try highlighter.highlightLine(frame_allocator, self.language, line);
        const diagnostics = self.lsp.diagnostics();
        const has_diagnostic = lineHasDiagnostic(diagnostics.lines, line_index + 1);

        const content_width = if (self.terminal.width > line_gutter_cols)
            self.terminal.width - line_gutter_cols
        else
            1;
        const limit = byteLimitForDisplayWidth(line, content_width, terminal_tab_width);
        const clipped = line[0..limit];

        if (has_diagnostic) {
            try out.writer().print("\x1b[31m!{d:3} \x1b[0m", .{line_index + 1});
        } else {
            try out.writer().print("\x1b[90m{d:4} \x1b[0m", .{line_index + 1});
        }

        const Overlay = struct {
            range: ByteRange,
            ansi: []const u8,
        };
        var overlay: ?Overlay = null;
        if (self.selectionRangeOnLine(line_index, line.len)) |selection_range| {
            overlay = .{
                .range = selection_range,
                .ansi = "\x1b[7m",
            };
        } else if (self.searchRangeOnLine(line_index, line.len)) |search_range| {
            overlay = .{
                .range = search_range,
                .ansi = "\x1b[48;5;24m\x1b[97m",
            };
        } else if (self.diagnosticSymbolRangeOnLine(line_index, line)) |symbol_range| {
            overlay = .{
                .range = symbol_range,
                .ansi = "\x1b[48;5;88m\x1b[97m",
            };
        }

        if (overlay) |active_overlay| {
            try renderHighlightedWithOverlay(out, clipped, spans, active_overlay.range, active_overlay.ansi);
        } else {
            try renderHighlighted(out, clipped, spans);
        }
    }

    fn renderDiagnosticsBar(self: *App, out: *std.array_list.Managed(u8), frame_allocator: std.mem.Allocator) !void {
        const diagnostics = self.lsp.diagnostics();
        const spinner = lspSpinner();

        var line = std.array_list.Managed(u8).init(frame_allocator);
        if (diagnostics.count > 0) {
            if (diagnostics.first_line) |first_line| {
                try line.writer().print(" ERR {d} | L{d}: ", .{ diagnostics.count, first_line });
            } else {
                try line.writer().print(" ERR {d}: ", .{diagnostics.count});
            }
            try appendSanitizedSingleLine(&line, diagnostics.first_message);
            if (diagnostics.pending_requests > 0) {
                try line.writer().print(" | LSP:{c}", .{spinner});
            }
            try out.appendSlice("\x1b[48;5;52m\x1b[97m");
        } else {
            if (self.lsp.enabled and !self.lsp.session_ready) {
                try line.writer().print(" LSP: starting {c} ", .{spinner});
            } else if (self.lsp.enabled and diagnostics.pending_requests > 0) {
                try line.writer().print(" LSP: waiting {c} ", .{spinner});
            } else if (self.lsp.enabled) {
                try line.appendSlice(" LSP: no diagnostics ");
            } else {
                try line.appendSlice(" LSP: off ");
            }
            try out.appendSlice("\x1b[48;5;236m\x1b[97m");
        }

        const limit = byteLimitForDisplayWidth(line.items, self.terminal.width, terminal_tab_width);
        const visible = line.items[0..limit];
        try out.appendSlice(visible);

        const used = displayWidth(visible, terminal_tab_width);
        var i: usize = used;
        while (i < self.terminal.width) : (i += 1) {
            try out.append(' ');
        }

        try out.appendSlice("\x1b[0m");
    }

    fn renderStatusBar(self: *App, out: *std.array_list.Managed(u8), frame_allocator: std.mem.Allocator) !void {
        const pos = self.buffer.lineColFromOffset(self.cursor);
        const visual_col = self.buffer.visualColumnFromOffset(self.cursor, terminal_tab_width);
        const file_name = self.file_path orelse "[No Name]";
        const dirty_mark = if (self.dirty) "*" else "";
        const lsp_mark = if (self.lsp.enabled)
            self.lsp.server_name
        else
            "off";

        var left = std.array_list.Managed(u8).init(frame_allocator);
        try left.appendSlice(" zicro ");
        try appendSanitizedSingleLine(&left, file_name);
        try left.appendSlice(dirty_mark);
        try left.append(' ');

        var right = std.array_list.Managed(u8).init(frame_allocator);
        const diagnostics = self.lsp.diagnostics();
        try right.writer().print("Ln {d}, Col {d} | LSP:{s} | Diag:{d} ", .{ pos.line + 1, visual_col + 1, lsp_mark, diagnostics.count });

        const total = self.terminal.width;
        const left_len = @min(left.items.len, total);
        const right_len = @min(right.items.len, total);
        const padding = if (left_len + right_len < total) total - left_len - right_len else 1;

        try out.appendSlice("\x1b[7m");
        try out.appendSlice(left.items[0..left_len]);
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            try out.append(' ');
        }
        try out.appendSlice(right.items[0..right_len]);
        try out.appendSlice("\x1b[0m");
    }

    fn renderMessageBar(self: *App, out: *std.array_list.Managed(u8)) !void {
        var line = std.array_list.Managed(u8).init(self.render_arena.allocator());
        try appendSanitizedSingleLine(&line, self.status.items);
        const limit = byteLimitForDisplayWidth(line.items, self.terminal.width, terminal_tab_width);
        try out.appendSlice("\x1b[90m");
        try out.appendSlice(line.items[0..limit]);
        try out.appendSlice("\x1b[0m");
    }

    fn renderPrompt(self: *App, out: *std.array_list.Managed(u8)) !void {
        const label = promptLabel(self.prompt.mode);
        try out.writer().print("\x1b[2;2H\x1b[48;5;238m\x1b[97m{s}{s}\x1b[0m", .{ label, self.prompt.query.items });
    }

    fn selectionRangeOnLine(self: *const App, line_index: usize, line_len: usize) ?ByteRange {
        if (self.blockSelectionSpec()) |block| {
            if (line_index < block.start_line or line_index > block.end_line) return null;
            const line_start = self.buffer.offsetFromLineCol(line_index, 0);
            const line_end = line_start + line_len;
            const sel_start = self.buffer.offsetFromLineVisualCol(line_index, block.start_col, terminal_tab_width);
            const sel_end = self.buffer.offsetFromLineVisualCol(line_index, block.end_col, terminal_tab_width);
            const range_start = @max(sel_start, line_start);
            const range_end = @min(sel_end, line_end);
            if (range_end <= range_start) return null;
            return .{
                .start = range_start - line_start,
                .end = range_end - line_start,
            };
        }

        const selected = self.selectedRange() orelse return null;
        const line_start = self.buffer.offsetFromLineCol(line_index, 0);
        const line_end = line_start + line_len;
        const range_start = @max(selected.start, line_start);
        const range_end = @min(selected.end, line_end);
        if (range_end <= range_start) return null;
        return .{
            .start = range_start - line_start,
            .end = range_end - line_start,
        };
    }

    fn searchRangeOnLine(self: *const App, line_index: usize, line_len: usize) ?ByteRange {
        const search = self.search_match orelse return null;
        const line_start = self.buffer.offsetFromLineCol(line_index, 0);
        const line_end = line_start + line_len;
        const range_start = @max(search.start, line_start);
        const range_end = @min(search.end, line_end);
        if (range_end <= range_start) return null;
        return .{
            .start = range_start - line_start,
            .end = range_end - line_start,
        };
    }

    fn diagnosticSymbolRangeOnLine(self: *const App, line_index: usize, line: []const u8) ?ByteRange {
        const diagnostics = self.lsp.diagnostics();
        const first_line = diagnostics.first_line orelse return null;
        if (first_line != line_index + 1) return null;
        if (diagnostics.first_symbol.len == 0) return null;
        if (std.mem.indexOf(u8, line, diagnostics.first_symbol)) |index| {
            return .{
                .start = index,
                .end = index + diagnostics.first_symbol.len,
            };
        }
        return null;
    }

    fn renderPalette(self: *App, out: *std.array_list.Managed(u8), frame_allocator: std.mem.Allocator) !void {
        const matches = try self.paletteMatches(frame_allocator);

        try out.writer().print("\x1b[2;2H\x1b[48;5;238m\x1b[97m Command: {s}\x1b[0m", .{self.palette.query.items});

        const max_rows = @min(@as(usize, 6), matches.items.len);
        var row: usize = 0;
        while (row < max_rows) : (row += 1) {
            const entry = palette_entries[matches.items[row]];
            const selected = row == @min(self.palette.selected, matches.items.len - 1);
            const prefix = if (selected) "> " else "  ";
            try out.writer().print("\x1b[{d};2H\x1b[K", .{3 + row});
            if (selected) {
                try out.appendSlice("\x1b[48;5;240m\x1b[97m");
            }
            try out.writer().print("{s}{s}\x1b[0m", .{ prefix, entry.label });
        }
    }

    fn paletteMatches(self: *App, allocator: std.mem.Allocator) !std.array_list.Managed(usize) {
        var matches = std.array_list.Managed(usize).init(allocator);

        const query = self.palette.query.items;
        if (query.len == 0) {
            for (palette_entries, 0..) |_, index| {
                try matches.append(index);
            }
            return matches;
        }

        for (palette_entries, 0..) |entry, index| {
            if (containsIgnoreCase(entry.label, query)) {
                try matches.append(index);
            }
        }

        return matches;
    }
};

fn renderHighlighted(out: *std.array_list.Managed(u8), line: []const u8, spans: []const highlighter.Span) !void {
    try renderHighlightedRange(out, line, spans, 0, line.len);
}

fn renderHighlightedWithOverlay(
    out: *std.array_list.Managed(u8),
    line: []const u8,
    spans: []const highlighter.Span,
    overlay: ByteRange,
    ansi: []const u8,
) !void {
    const start = @min(overlay.start, line.len);
    const end = @min(overlay.end, line.len);

    try renderHighlightedRange(out, line, spans, 0, start);
    if (end > start) {
        try out.appendSlice(ansi);
        try out.appendSlice(line[start..end]);
        try out.appendSlice("\x1b[0m");
    }
    try renderHighlightedRange(out, line, spans, end, line.len);
}

fn renderHighlightedRange(
    out: *std.array_list.Managed(u8),
    line: []const u8,
    spans: []const highlighter.Span,
    start_input: usize,
    end_input: usize,
) !void {
    const start = @min(start_input, line.len);
    const end = @min(end_input, line.len);
    if (end <= start) return;

    var pos = start;
    var span_index: usize = 0;
    while (span_index < spans.len and spans[span_index].end <= pos) : (span_index += 1) {}

    while (pos < end) {
        var next = end;
        var token: ?highlighter.TokenType = null;

        if (span_index < spans.len) {
            const span = spans[span_index];
            const span_start = @min(span.start, line.len);
            const span_end = @min(span.end, line.len);
            if (span_start <= pos and pos < span_end) {
                token = span.token;
                next = @min(end, span_end);
            } else if (pos < span_start) {
                next = @min(end, span_start);
            }
        }

        if (next <= pos) break;

        if (token) |active| {
            try out.appendSlice(highlighter.ansiForToken(active));
            try out.appendSlice(line[pos..next]);
            try out.appendSlice("\x1b[0m");
        } else {
            try out.appendSlice(line[pos..next]);
        }
        pos = next;

        while (span_index < spans.len and spans[span_index].end <= pos) : (span_index += 1) {}
    }
}

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

fn promptLabel(mode: PromptMode) []const u8 {
    return switch (mode) {
        .goto_line => " Goto line: ",
        .regex_search => " Regex: ",
    };
}

fn lspSpinner() u8 {
    const frames = "|/-\\";
    const tick = @divTrunc(std.time.nanoTimestamp(), 120 * std.time.ns_per_ms);
    const index: usize = @intCast(@mod(tick, frames.len));
    return frames[index];
}

fn renderPlainWithOverlay(out: *std.array_list.Managed(u8), line: []const u8, overlay: ByteRange, ansi: []const u8) !void {
    const start = @min(overlay.start, line.len);
    const end = @min(overlay.end, line.len);

    if (start > 0) {
        try out.appendSlice(line[0..start]);
    }

    if (end > start) {
        try out.appendSlice(ansi);
        try out.appendSlice(line[start..end]);
        try out.appendSlice("\x1b[0m");
    }

    if (end < line.len) {
        try out.appendSlice(line[end..]);
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return true;
        }
    }

    return false;
}

fn appendSanitizedSingleLine(out: *std.array_list.Managed(u8), text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        const ch = text[index];
        if (ch == '\n' or ch == '\r' or ch == '\t') {
            try out.append(' ');
            index += 1;
            continue;
        }

        if (ch < 0x20 or ch == 0x7f) {
            index += 1;
            continue;
        }

        const step = utf8Step(text, index);
        try out.appendSlice(text[index .. index + step]);
        index += step;
    }
}

fn lineHasDiagnostic(lines: []const usize, line_number: usize) bool {
    for (lines) |line| {
        if (line == line_number) return true;
    }
    return false;
}

fn utf8PrevBoundary(bytes: []const u8, index_input: usize) usize {
    var index = @min(index_input, bytes.len);
    if (index == 0) return 0;

    index -= 1;
    while (index > 0 and isUtf8ContinuationByte(bytes[index])) {
        index -= 1;
    }

    return index;
}

fn displayWidth(bytes: []const u8, tab_width_input: usize) usize {
    const tab_width = normalizedTabWidth(tab_width_input);
    var width: usize = 0;
    var index: usize = 0;

    while (index < bytes.len) {
        const ch = bytes[index];
        if (ch == '\t') {
            width += tabStop(tab_width, width);
            index += 1;
            continue;
        }

        width += 1;
        index += utf8Step(bytes, index);
    }

    return width;
}

fn byteLimitForDisplayWidth(bytes: []const u8, max_width: usize, tab_width_input: usize) usize {
    const tab_width = normalizedTabWidth(tab_width_input);
    var width: usize = 0;
    var index: usize = 0;

    while (index < bytes.len) {
        const ch = bytes[index];
        const step_width = if (ch == '\t') tabStop(tab_width, width) else 1;
        if (width + step_width > max_width) break;

        width += step_width;
        if (ch == '\t') {
            index += 1;
        } else {
            index += utf8Step(bytes, index);
        }
    }

    return index;
}

fn utf8Step(bytes: []const u8, index: usize) usize {
    const first = bytes[index];
    if (first < 0x80) return 1;

    const expected = utf8ExpectedLen(first);
    if (expected <= 1 or index + expected > bytes.len) return 1;

    var i: usize = 1;
    while (i < expected) : (i += 1) {
        if (!isUtf8ContinuationByte(bytes[index + i])) return 1;
    }

    return expected;
}

fn utf8ExpectedLen(first: u8) usize {
    if ((first & 0b1110_0000) == 0b1100_0000) return 2;
    if ((first & 0b1111_0000) == 0b1110_0000) return 3;
    if ((first & 0b1111_1000) == 0b1111_0000) return 4;
    return 1;
}

fn isUtf8ContinuationByte(ch: u8) bool {
    return (ch & 0b1100_0000) == 0b1000_0000;
}

fn normalizedTabWidth(tab_width_input: usize) usize {
    return if (tab_width_input == 0) 4 else tab_width_input;
}

fn tabStop(tab_width: usize, col: usize) usize {
    return tab_width - (col % tab_width);
}
