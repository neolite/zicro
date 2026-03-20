const std = @import("std");
const LspIncrementalChange = @import("../lsp/client.zig").IncrementalChange;
const LspChangePosition = @import("../state/lsp_state.zig").LspChangePosition;

pub fn queueIncrementalChange(self: anytype, start_offset: usize, end_offset: usize, text: []const u8) !void {
    if (!self.lsp_state.client.enabled) return;

    try self.lsp_state.pending_lsp_changes.append(.{
        .start = lspPositionFromOffset(self, start_offset),
        .end = lspPositionFromOffset(self, end_offset),
        .text = try self.allocator.dupe(u8, text),
    });
}

pub fn lspPositionFromOffset(self: anytype, offset: usize) LspChangePosition {
    const aligned = self.editor.buffer.alignToCodepointStart(offset);
    const pos = self.editor.buffer.lineColFromOffset(aligned);
    return .{
        .line = pos.line,
        .character = utf16ColumnForOffset(self, pos.line, aligned),
    };
}

pub fn utf16ColumnForOffset(self: anytype, line: usize, offset: usize) usize {
    const line_start = self.editor.buffer.offsetFromLineCol(line, 0);
    var cursor = line_start;
    var utf16_col: usize = 0;

    while (cursor < offset) {
        const next = self.editor.buffer.nextCodepointEnd(cursor);
        if (next <= cursor) break;
        const step = next - cursor;
        utf16_col += if (step == 4) 2 else 1;
        cursor = next;
    }

    return utf16_col;
}

pub fn offsetFromLspPosition(self: anytype, line: usize, character: usize) usize {
    const line_count = self.editor.buffer.lineCount();
    if (line >= line_count) return self.editor.buffer.len();

    const line_start = self.editor.buffer.offsetFromLineCol(line, 0);
    const line_end = self.editor.buffer.offsetFromLineCol(line, std.math.maxInt(usize));
    var cursor = line_start;
    var utf16_col: usize = 0;

    while (cursor < line_end) {
        if (utf16_col >= character) break;
        const next = self.editor.buffer.nextCodepointEnd(cursor);
        if (next <= cursor) break;
        const step = next - cursor;
        const utf16_step: usize = if (step == 4) 2 else 1;
        if (utf16_col + utf16_step > character) break;
        utf16_col += utf16_step;
        cursor = next;
    }

    return cursor;
}

pub fn clearPendingLspChanges(self: anytype) void {
    for (self.lsp_state.pending_lsp_changes.items) |change| {
        self.allocator.free(change.text);
    }
    self.lsp_state.pending_lsp_changes.clearRetainingCapacity();
}

pub fn queueDidChange(self: anytype) void {
    if (!self.lsp_state.client.enabled) return;
    self.lsp_state.pending_lsp_sync = true;
    self.lsp_state.next_lsp_flush_ns = std.time.nanoTimestamp() + self.lsp_state.change_delay_ns;
}

pub fn flushPendingDidChange(self: anytype, force: bool) !bool {
    if (!self.lsp_state.pending_lsp_sync or !self.lsp_state.client.enabled) return false;
    if (!force and std.time.nanoTimestamp() < self.lsp_state.next_lsp_flush_ns) return false;

    self.lsp_state.pending_lsp_sync = false;
    defer {
        self.lsp_state.force_full_lsp_sync = false;
        clearPendingLspChanges(self);
    }

    const use_incremental = !self.lsp_state.force_full_lsp_sync and
        self.lsp_state.pending_lsp_changes.items.len > 0 and
        self.lsp_state.client.supportsIncrementalSync();

    if (use_incremental) {
        for (self.lsp_state.pending_lsp_changes.items) |change| {
            const incremental: LspIncrementalChange = .{
                .start_line = change.start.line,
                .start_character = change.start.character,
                .end_line = change.end.line,
                .end_character = change.end.character,
                .text = change.text,
            };
            self.lsp_state.client.didChangeIncremental(incremental) catch |err| {
                try handleLspError(self, err);
                return true;
            };
        }
    } else {
        const bytes = try self.editor.buffer.toOwnedBytes(self.allocator);
        defer self.allocator.free(bytes);

        self.lsp_state.client.didChange(bytes) catch |err| {
            try handleLspError(self, err);
            return true;
        };
    }

    if (self.config.autosave) {
        if (self.editor.file_path) |path| {
            try writeBufferToFile(self, path);
            try setStatus(self, "Saved");
            self.lsp_state.client.didSave() catch |err| {
                try handleLspError(self, err);
            };
        }
    }

    return true;
}

pub fn handleLspError(self: anytype, _: anyerror) !void {
    self.lsp_state.pending_lsp_sync = false;
    self.lsp_state.force_full_lsp_sync = false;
    clearPendingLspChanges(self);
    self.lsp_state.client.stop();
    try setStatus(self, "LSP disconnected; disabled");
}

fn writeBufferToFile(self: anytype, path: []const u8) !void {
    const bytes = try self.editor.buffer.toOwnedBytes(self.allocator);
    defer self.allocator.free(bytes);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
    self.editor.dirty = false;
    self.editor.confirm_quit = false;
    self.editor.preferred_visual_col = null;
}

fn setStatus(self: anytype, message: []const u8) !void {
    self.ui.status.clearRetainingCapacity();
    try self.ui.status.appendSlice(message);
    self.ui.needs_render = true;
}
