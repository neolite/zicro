const std = @import("std");
const layout = @import("../text/layout.zig");

const Source = enum {
    original,
    add,
};

const Piece = struct {
    source: Source,
    start: usize,
    len: usize,
};

const EditKind = enum {
    insert,
    delete,
};

const EditRecord = struct {
    kind: EditKind,
    offset: usize,
    bytes: []u8,
};

pub const CursorPos = struct {
    line: usize,
    col: usize,
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    original: []u8,
    add: std.array_list.Managed(u8),
    pieces: std.array_list.Managed(Piece),
    line_starts: std.array_list.Managed(usize),
    undo_stack: std.array_list.Managed(EditRecord),
    redo_stack: std.array_list.Managed(EditRecord),
    total_len: usize,

    pub fn initEmpty(allocator: std.mem.Allocator) !Buffer {
        var self = Buffer{
            .allocator = allocator,
            .original = try allocator.alloc(u8, 0),
            .add = std.array_list.Managed(u8).init(allocator),
            .pieces = std.array_list.Managed(Piece).init(allocator),
            .line_starts = std.array_list.Managed(usize).init(allocator),
            .undo_stack = std.array_list.Managed(EditRecord).init(allocator),
            .redo_stack = std.array_list.Managed(EditRecord).init(allocator),
            .total_len = 0,
        };
        try self.line_starts.append(0);
        return self;
    }

    pub fn fromBytes(allocator: std.mem.Allocator, data: []const u8) !Buffer {
        var self = Buffer{
            .allocator = allocator,
            .original = try allocator.dupe(u8, data),
            .add = std.array_list.Managed(u8).init(allocator),
            .pieces = std.array_list.Managed(Piece).init(allocator),
            .line_starts = std.array_list.Managed(usize).init(allocator),
            .undo_stack = std.array_list.Managed(EditRecord).init(allocator),
            .redo_stack = std.array_list.Managed(EditRecord).init(allocator),
            .total_len = data.len,
        };

        if (data.len > 0) {
            try self.pieces.append(.{
                .source = .original,
                .start = 0,
                .len = data.len,
            });
        }

        try self.rebuildLineIndex();
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.original);
        self.add.deinit();
        self.pieces.deinit();
        self.line_starts.deinit();
        freeEditStack(self.allocator, &self.undo_stack);
        freeEditStack(self.allocator, &self.redo_stack);
        self.undo_stack.deinit();
        self.redo_stack.deinit();
    }

    pub fn len(self: *const Buffer) usize {
        return self.total_len;
    }

    pub fn lineCount(self: *const Buffer) usize {
        return if (self.line_starts.items.len == 0) 1 else self.line_starts.items.len;
    }

    pub fn lineColFromOffset(self: *const Buffer, offset_input: usize) CursorPos {
        const offset = @min(offset_input, self.total_len);
        if (self.line_starts.items.len == 0) {
            return .{ .line = 0, .col = offset };
        }

        var lo: usize = 0;
        var hi: usize = self.line_starts.items.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts.items[mid] <= offset) {
                lo = mid;
            } else {
                hi = mid;
            }
        }

        return .{
            .line = lo,
            .col = offset - self.line_starts.items[lo],
        };
    }

    pub fn alignToCodepointStart(self: *const Buffer, offset_input: usize) usize {
        var offset = @min(offset_input, self.total_len);
        while (offset > 0) {
            const ch = self.byteAt(offset) orelse break;
            if (!layout.isUtf8ContinuationByte(ch)) break;
            offset -= 1;
        }
        return offset;
    }

    pub fn prevCodepointStart(self: *const Buffer, offset_input: usize) usize {
        const offset = @min(offset_input, self.total_len);
        if (offset == 0) return 0;

        var pos = offset - 1;
        while (pos > 0) {
            const ch = self.byteAt(pos) orelse break;
            if (!layout.isUtf8ContinuationByte(ch)) break;
            pos -= 1;
        }

        return pos;
    }

    pub fn nextCodepointEnd(self: *const Buffer, offset_input: usize) usize {
        const offset = self.alignToCodepointStart(offset_input);
        if (offset >= self.total_len) return self.total_len;

        var pos = offset + 1;
        while (pos < self.total_len) {
            const ch = self.byteAt(pos) orelse break;
            if (!layout.isUtf8ContinuationByte(ch)) break;
            pos += 1;
        }

        return pos;
    }

    pub fn visualColumnFromOffset(self: *const Buffer, offset_input: usize, tab_width_input: usize) usize {
        const offset = @min(offset_input, self.total_len);
        const pos = self.lineColFromOffset(offset);
        const line_start = self.line_starts.items[pos.line];
        const tab_width = layout.normalizedTabWidth(tab_width_input);

        var cursor = line_start;
        var visual_col: usize = 0;
        while (cursor < offset) {
            const ch = self.byteAt(cursor) orelse break;
            if (ch == '\t') {
                visual_col += layout.tabStop(tab_width, visual_col);
                cursor += 1;
                continue;
            }

            const next = self.nextCodepointEnd(cursor);
            if (next <= cursor) break;
            visual_col += 1;
            cursor = @min(next, offset);
        }

        return visual_col;
    }

    pub fn offsetFromLineVisualCol(self: *const Buffer, line_input: usize, visual_col_input: usize, tab_width_input: usize) usize {
        const lines = self.lineCount();
        if (line_input >= lines) return self.total_len;

        const start = self.line_starts.items[line_input];
        const line_end = if (line_input + 1 < lines)
            self.line_starts.items[line_input + 1] - 1
        else
            self.total_len;
        const tab_width = layout.normalizedTabWidth(tab_width_input);

        var cursor = start;
        var visual_col: usize = 0;
        while (cursor < line_end) {
            const ch = self.byteAt(cursor) orelse break;
            const width = if (ch == '\t') layout.tabStop(tab_width, visual_col) else 1;
            if (visual_col + width > visual_col_input) break;

            visual_col += width;
            if (ch == '\t') {
                cursor += 1;
            } else {
                const next = self.nextCodepointEnd(cursor);
                if (next <= cursor) break;
                cursor = @min(next, line_end);
            }
        }

        return cursor;
    }

    pub fn offsetFromLineCol(self: *const Buffer, line_input: usize, col_input: usize) usize {
        const lines = self.lineCount();
        if (line_input >= lines) return self.total_len;

        const start = self.line_starts.items[line_input];
        const line_end = if (line_input + 1 < lines)
            self.line_starts.items[line_input + 1] - 1
        else
            self.total_len;

        const width = line_end - start;
        return start + @min(col_input, width);
    }

    pub fn insert(self: *Buffer, offset: usize, text: []const u8) !void {
        try self.insertImpl(offset, text, true);
    }

    pub fn delete(self: *Buffer, offset: usize, count: usize) !void {
        try self.deleteImpl(offset, count, true);
    }

    pub fn undo(self: *Buffer) !void {
        const record = self.undo_stack.pop() orelse return;

        switch (record.kind) {
            .insert => try self.deleteImpl(record.offset, record.bytes.len, false),
            .delete => try self.insertImpl(record.offset, record.bytes, false),
        }

        try self.redo_stack.append(record);
    }

    pub fn redo(self: *Buffer) !void {
        const record = self.redo_stack.pop() orelse return;

        switch (record.kind) {
            .insert => try self.insertImpl(record.offset, record.bytes, false),
            .delete => try self.deleteImpl(record.offset, record.bytes.len, false),
        }

        try self.undo_stack.append(record);
    }

    pub fn toOwnedBytes(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        var out = try allocator.alloc(u8, self.total_len);
        var write_at: usize = 0;

        for (self.pieces.items) |piece| {
            const segment = self.pieceBytes(piece);
            @memcpy(out[write_at .. write_at + segment.len], segment);
            write_at += segment.len;
        }

        return out;
    }

    pub fn lineOwned(self: *const Buffer, allocator: std.mem.Allocator, line_input: usize) ![]u8 {
        if (self.line_starts.items.len == 0) {
            return allocator.alloc(u8, 0);
        }

        const line = @min(line_input, self.lineCount() - 1);
        const start = self.line_starts.items[line];
        const line_end = if (line + 1 < self.lineCount())
            self.line_starts.items[line + 1] - 1
        else
            self.total_len;

        return self.sliceOwned(allocator, start, line_end - start);
    }

    pub fn byteAt(self: *const Buffer, offset_input: usize) ?u8 {
        const offset = @min(offset_input, self.total_len);
        if (offset >= self.total_len) return null;

        var cursor: usize = 0;
        for (self.pieces.items) |piece| {
            const next = cursor + piece.len;
            if (offset < next) {
                return self.pieceBytes(piece)[offset - cursor];
            }
            cursor = next;
        }

        return null;
    }

    pub fn moveWordLeft(self: *const Buffer, offset_input: usize) usize {
        if (self.total_len == 0) return 0;

        var pos = self.prevCodepointStart(offset_input);

        while (pos > 0) {
            const ch = self.byteAt(pos) orelse break;
            if (isWordByte(ch)) break;
            const prev = self.prevCodepointStart(pos);
            if (prev == pos) break;
            pos = prev;
        }

        while (pos > 0) {
            const prev = self.prevCodepointStart(pos);
            const ch = self.byteAt(prev) orelse break;
            if (!isWordByte(ch)) break;
            pos = prev;
        }

        return pos;
    }

    pub fn moveWordRight(self: *const Buffer, offset_input: usize) usize {
        var pos = self.alignToCodepointStart(offset_input);

        while (pos < self.total_len) {
            const ch = self.byteAt(pos) orelse break;
            if (isWordByte(ch)) break;
            const next = self.nextCodepointEnd(pos);
            if (next <= pos) break;
            pos = next;
        }

        while (pos < self.total_len) {
            const ch = self.byteAt(pos) orelse break;
            if (!isWordByte(ch)) break;
            const next = self.nextCodepointEnd(pos);
            if (next <= pos) break;
            pos = next;
        }

        return pos;
    }

    fn insertImpl(self: *Buffer, offset_input: usize, text: []const u8, track_undo: bool) !void {
        if (text.len == 0) return;

        const offset = @min(offset_input, self.total_len);
        if (track_undo) {
            try self.clearRedo();
            try self.undo_stack.append(.{
                .kind = .insert,
                .offset = offset,
                .bytes = try self.allocator.dupe(u8, text),
            });
        }

        const add_start = self.add.items.len;
        try self.add.appendSlice(text);

        const piece = Piece{
            .source = .add,
            .start = add_start,
            .len = text.len,
        };

        try self.insertPieceAt(offset, piece);
        self.total_len += text.len;
        try self.rebuildLineIndex();
    }

    fn deleteImpl(self: *Buffer, offset_input: usize, count_input: usize, track_undo: bool) !void {
        const offset = @min(offset_input, self.total_len);
        const max_count = self.total_len - offset;
        const count = @min(count_input, max_count);
        if (count == 0) return;

        if (track_undo) {
            try self.clearRedo();
            try self.undo_stack.append(.{
                .kind = .delete,
                .offset = offset,
                .bytes = try self.sliceOwned(self.allocator, offset, count),
            });
        }

        const start = offset;
        const end = offset + count;

        var new_pieces = std.array_list.Managed(Piece).init(self.allocator);
        var cursor: usize = 0;
        for (self.pieces.items) |piece| {
            const piece_start = cursor;
            const piece_end = cursor + piece.len;

            if (piece_end <= start or piece_start >= end) {
                try new_pieces.append(piece);
            } else {
                if (start > piece_start) {
                    try new_pieces.append(.{
                        .source = piece.source,
                        .start = piece.start,
                        .len = start - piece_start,
                    });
                }
                if (end < piece_end) {
                    const right_skip = end - piece_start;
                    try new_pieces.append(.{
                        .source = piece.source,
                        .start = piece.start + right_skip,
                        .len = piece_end - end,
                    });
                }
            }

            cursor = piece_end;
        }

        self.pieces.deinit();
        self.pieces = new_pieces;
        self.total_len -= count;

        self.coalescePieces();
        try self.rebuildLineIndex();
    }

    fn insertPieceAt(self: *Buffer, offset: usize, piece: Piece) !void {
        if (self.pieces.items.len == 0 or offset == self.total_len) {
            try self.pieces.append(piece);
            self.coalescePieces();
            return;
        }

        const loc = self.locateOffset(offset);
        if (loc.index >= self.pieces.items.len) {
            try self.pieces.append(piece);
            self.coalescePieces();
            return;
        }

        const target = self.pieces.items[loc.index];
        if (loc.inner == 0) {
            try self.pieces.insert(loc.index, piece);
        } else if (loc.inner == target.len) {
            try self.pieces.insert(loc.index + 1, piece);
        } else {
            self.pieces.items[loc.index].len = loc.inner;

            const right_piece = Piece{
                .source = target.source,
                .start = target.start + loc.inner,
                .len = target.len - loc.inner,
            };

            try self.pieces.insert(loc.index + 1, piece);
            try self.pieces.insert(loc.index + 2, right_piece);
        }

        self.coalescePieces();
    }

    fn locateOffset(self: *const Buffer, offset: usize) struct { index: usize, inner: usize } {
        if (self.pieces.items.len == 0) {
            return .{ .index = 0, .inner = 0 };
        }

        var cursor: usize = 0;
        for (self.pieces.items, 0..) |piece, index| {
            const next = cursor + piece.len;
            if (offset <= next) {
                return .{ .index = index, .inner = offset - cursor };
            }
            cursor = next;
        }

        return .{ .index = self.pieces.items.len, .inner = 0 };
    }

    fn pieceBytes(self: *const Buffer, piece: Piece) []const u8 {
        return switch (piece.source) {
            .original => self.original[piece.start .. piece.start + piece.len],
            .add => self.add.items[piece.start .. piece.start + piece.len],
        };
    }

    fn sliceOwned(self: *const Buffer, allocator: std.mem.Allocator, offset: usize, count: usize) ![]u8 {
        if (count == 0) return allocator.alloc(u8, 0);

        const start = @min(offset, self.total_len);
        const end = @min(start + count, self.total_len);
        const out_len = end - start;

        var out = try allocator.alloc(u8, out_len);
        var write_at: usize = 0;
        var cursor: usize = 0;

        for (self.pieces.items) |piece| {
            const piece_start = cursor;
            const piece_end = cursor + piece.len;

            if (piece_end <= start or piece_start >= end) {
                cursor = piece_end;
                continue;
            }

            const overlap_start = @max(piece_start, start);
            const overlap_end = @min(piece_end, end);
            const in_piece_offset = overlap_start - piece_start;
            const overlap_len = overlap_end - overlap_start;

            const src = self.pieceBytes(piece)[in_piece_offset .. in_piece_offset + overlap_len];
            @memcpy(out[write_at .. write_at + overlap_len], src);
            write_at += overlap_len;
            cursor = piece_end;
        }

        return out;
    }

    fn rebuildLineIndex(self: *Buffer) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(0);

        var cursor: usize = 0;
        for (self.pieces.items) |piece| {
            const bytes = self.pieceBytes(piece);
            for (bytes) |ch| {
                cursor += 1;
                if (ch == '\n' and cursor <= self.total_len) {
                    try self.line_starts.append(cursor);
                }
            }
        }

        if (self.line_starts.items.len == 0) {
            try self.line_starts.append(0);
        }
    }

    fn clearRedo(self: *Buffer) !void {
        for (self.redo_stack.items) |entry| {
            self.allocator.free(entry.bytes);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn coalescePieces(self: *Buffer) void {
        if (self.pieces.items.len < 2) return;

        var write_index: usize = 0;
        var read_index: usize = 1;

        while (read_index < self.pieces.items.len) : (read_index += 1) {
            var current = &self.pieces.items[write_index];
            const next = self.pieces.items[read_index];

            if (current.source == next.source and current.start + current.len == next.start) {
                current.len += next.len;
            } else {
                write_index += 1;
                self.pieces.items[write_index] = next;
            }
        }

        self.pieces.items.len = write_index + 1;
    }
};

fn freeEditStack(allocator: std.mem.Allocator, stack: *std.array_list.Managed(EditRecord)) void {
    for (stack.items) |item| {
        allocator.free(item.bytes);
    }
}

fn isWordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "piece table insert delete" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "hello world");
    defer buffer.deinit();

    try buffer.insert(5, ",");
    try buffer.delete(6, 1);

    const bytes = try buffer.toOwnedBytes(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqualStrings("hello,world", bytes);
}

test "line index updates" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\nb\n");
    defer buffer.deinit();

    try std.testing.expectEqual(@as(usize, 3), buffer.lineCount());

    try buffer.insert(buffer.len(), "c");
    try std.testing.expectEqual(@as(usize, 3), buffer.lineCount());

    const pos = buffer.lineColFromOffset(buffer.len());
    try std.testing.expectEqual(@as(usize, 2), pos.line);
}

test "utf8 cursor boundaries stay on codepoint starts" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\xd1\x84b");
    defer buffer.deinit();

    try std.testing.expectEqual(@as(usize, 3), buffer.nextCodepointEnd(1));
    try std.testing.expectEqual(@as(usize, 1), buffer.prevCodepointStart(3));
    try std.testing.expectEqual(@as(usize, 1), buffer.alignToCodepointStart(2));
}

test "visual columns respect utf8 and tabs" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\xd1\x84\tb");
    defer buffer.deinit();

    try std.testing.expectEqual(@as(usize, 2), buffer.visualColumnFromOffset(3, 8));
    try std.testing.expectEqual(@as(usize, 3), buffer.offsetFromLineVisualCol(0, 2, 8));
    try std.testing.expectEqual(@as(usize, 4), buffer.offsetFromLineVisualCol(0, 8, 8));
}
