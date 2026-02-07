const std = @import("std");

pub fn moveVertical(self: anytype, delta: i32, terminal_tab_width: usize) void {
    const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
    const visual_col = self.editor.preferred_visual_col orelse self.editor.buffer.visualColumnFromOffset(self.editor.cursor, terminal_tab_width);
    const line_i64 = @as(i64, @intCast(pos.line));
    const target_line_i64 = std.math.clamp(line_i64 + delta, 0, @as(i64, @intCast(self.editor.buffer.lineCount() - 1)));
    const target_line: usize = @intCast(target_line_i64);
    self.editor.cursor = self.editor.buffer.offsetFromLineVisualCol(target_line, visual_col, terminal_tab_width);
    self.editor.preferred_visual_col = visual_col;
}

pub fn movePage(
    self: anytype,
    delta: i32,
    terminal_tab_width: usize,
    top_bar_rows: usize,
    footer_rows: usize,
) void {
    const page = editorTextRows(self, top_bar_rows, footer_rows);
    const step: i64 = @as(i64, @intCast(page));
    const signed = if (delta < 0) -step else step;

    const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
    const visual_col = self.editor.preferred_visual_col orelse self.editor.buffer.visualColumnFromOffset(self.editor.cursor, terminal_tab_width);
    const line_i64 = @as(i64, @intCast(pos.line));
    const max_line = @as(i64, @intCast(self.editor.buffer.lineCount() - 1));
    const target_line_i64 = std.math.clamp(line_i64 + signed, 0, max_line);
    const target_line: usize = @intCast(target_line_i64);

    self.editor.cursor = self.editor.buffer.offsetFromLineVisualCol(target_line, visual_col, terminal_tab_width);
    self.editor.preferred_visual_col = visual_col;
}

pub fn adjustScroll(self: anytype, text_rows: usize) void {
    const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);

    if (pos.line < self.editor.scroll_y) {
        self.editor.scroll_y = pos.line;
    }

    if (pos.line >= self.editor.scroll_y + text_rows) {
        self.editor.scroll_y = pos.line - text_rows + 1;
    }
}

pub fn editorTextRows(self: anytype, top_bar_rows: usize, footer_rows: usize) usize {
    const reserved_rows = top_bar_rows + footer_rows;
    return if (self.terminal.height > reserved_rows) self.terminal.height - reserved_rows else 1;
}
