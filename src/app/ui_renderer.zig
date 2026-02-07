const std = @import("std");
const highlighter = @import("../highlight/highlighter.zig");
const layout = @import("../text/layout.zig");
const ByteRange = @import("../state/editor_state.zig").ByteRange;
const PromptMode = @import("../state/ui_state.zig").PromptMode;
const palette_entries = @import("../state/ui_state.zig").palette_entries;

pub fn render(
    self: anytype,
    top_bar_rows: usize,
    footer_rows: usize,
    line_gutter_cols: usize,
    terminal_tab_width: usize,
) !void {
    _ = self.ui.render_arena.reset(.retain_capacity);
    const frame_allocator = self.ui.render_arena.allocator();
    var out = std.array_list.Managed(u8).init(frame_allocator);

    const text_rows = self.editorTextRows();
    self.adjustScroll(text_rows);

    try out.appendSlice("\x1b[?25l\x1b[H");
    try renderDiagnosticsBar(self, &out, frame_allocator, terminal_tab_width);
    try out.appendSlice("\x1b[K\r\n");

    var line_state = try self.highlightStateForLine(self.editor.scroll_y, frame_allocator);
    var row: usize = 0;
    while (row < text_rows) : (row += 1) {
        const line_index = self.editor.scroll_y + row;

        if (line_index < self.editor.buffer.lineCount()) {
            line_state = try renderLine(self, &out, line_index, line_state, frame_allocator, line_gutter_cols, terminal_tab_width);
        } else {
            try out.appendSlice("\x1b[90m~\x1b[0m");
        }

        try out.appendSlice("\x1b[K\r\n");
    }

    _ = footer_rows;
    try renderStatusBar(self, &out, frame_allocator, terminal_tab_width);
    try out.appendSlice("\x1b[K\r\n");
    try renderMessageBar(self, &out, terminal_tab_width);
    try out.appendSlice("\x1b[K");

    if (self.ui.prompt.active) {
        try renderPrompt(self, &out);
    }

    if (!self.ui.palette.active and !self.ui.prompt.active and self.ui.lsp_panel_mode != .none) {
        try renderLspPanel(self, &out, frame_allocator, top_bar_rows, line_gutter_cols, terminal_tab_width);
    }

    if (!self.ui.palette.active and !self.ui.prompt.active and self.ui.lsp_hover_tooltip_active) {
        try renderHoverTooltip(self, &out, frame_allocator, top_bar_rows, line_gutter_cols, terminal_tab_width);
    }

    if (self.ui.debug_panel_enabled and !self.ui.palette.active and !self.ui.prompt.active) {
        try renderDebugPanel(self, &out, top_bar_rows, terminal_tab_width);
    }

    if (self.ui.palette.active) {
        try renderPalette(self, &out, frame_allocator);
        const palette_layout = computePaletteLayout(self);
        const label = paletteLabel(self);
        const query_col = displayWidth(self.ui.palette.query.items, terminal_tab_width);
        const label_width = displayWidth(label, terminal_tab_width);
        const cursor_col = @min(palette_layout.col + 1 + label_width + query_col, self.terminal.width);
        try out.writer().print("\x1b[{d};{d}H", .{ palette_layout.row + 1, cursor_col });
    } else if (self.ui.prompt.active) {
        const label = promptLabel(self.ui.prompt.mode);
        const cursor_col = @min(displayWidth(label, terminal_tab_width) + displayWidth(self.ui.prompt.query.items, terminal_tab_width) + 2, self.terminal.width);
        try out.writer().print("\x1b[{d};{d}H", .{ 2, cursor_col });
    } else {
        const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
        const screen_row = top_bar_rows + (pos.line - self.editor.scroll_y) + 1;
        const visual_col = self.editor.buffer.visualColumnFromOffset(self.editor.cursor, terminal_tab_width);
        const screen_col = @min(visual_col + line_gutter_cols + 1, self.terminal.width);
        try out.writer().print("\x1b[{d};{d}H", .{ screen_row, screen_col });
    }

    try out.appendSlice("\x1b[?25h");
    try self.terminal.writeAll(out.items);
    try self.terminal.flush();
}

pub fn renderLine(
    self: anytype,
    out: *std.array_list.Managed(u8),
    line_index: usize,
    line_state: highlighter.LineState,
    frame_allocator: std.mem.Allocator,
    line_gutter_cols: usize,
    terminal_tab_width: usize,
) !highlighter.LineState {
    const line = try self.editor.buffer.lineOwned(frame_allocator, line_index);
    const highlighted = try highlighter.highlightLineWithState(frame_allocator, self.editor.language, line, line_state);
    const spans = highlighted.spans;
    self.cacheHighlightStateForNextLine(line_index + 1, highlighted.next_state);
    const diagnostics = self.lsp_state.client.diagnostics();
    const has_diagnostic = lineHasDiagnostic(diagnostics.lines, line_index + 1);

    const content_width = if (self.terminal.width > line_gutter_cols)
        self.terminal.width - line_gutter_cols
    else
        1;
    const limit = byteLimitForDisplayWidth(line, content_width, terminal_tab_width);
    const clipped = line[0..limit];

    if (self.ui.show_line_numbers) {
        if (has_diagnostic) {
            try out.writer().print("\x1b[31m!{d:3} \x1b[0m", .{line_index + 1});
        } else {
            try out.writer().print("\x1b[90m{d:4} \x1b[0m", .{line_index + 1});
        }
    } else {
        var i: usize = 0;
        while (i < line_gutter_cols) : (i += 1) {
            try out.append(' ');
        }
    }

    const Overlay = struct {
        range: ByteRange,
        ansi: []const u8,
    };
    var overlay: ?Overlay = null;
    if (selectionRangeOnLine(self, line_index, line.len, terminal_tab_width)) |selection_range| {
        overlay = .{
            .range = selection_range,
            .ansi = "\x1b[7m",
        };
    } else if (searchRangeOnLine(self, line_index, line.len)) |search_range| {
        overlay = .{
            .range = search_range,
            .ansi = "\x1b[48;5;24m\x1b[97m",
        };
    } else if (diagnosticSymbolRangeOnLine(self, line_index, line)) |symbol_range| {
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

    return highlighted.next_state;
}

pub fn renderDiagnosticsBar(
    self: anytype,
    out: *std.array_list.Managed(u8),
    frame_allocator: std.mem.Allocator,
    terminal_tab_width: usize,
) !void {
    const diagnostics = self.lsp_state.client.diagnostics();
    const spinner = lspSpinner(self.ui.lsp_spinner_frame);

    var line = std.array_list.Managed(u8).init(frame_allocator);
    if (diagnostics.count > 0) {
        if (diagnostics.first_line) |first_line| {
            try line.writer().print(" ERR {d} | L{d}: ", .{ diagnostics.count, first_line });
        } else {
            try line.writer().print(" ERR {d}: ", .{diagnostics.count});
        }
        try appendSanitizedSingleLine(&line, diagnostics.first_message);
        if (diagnostics.pending_requests > 0) {
            try line.writer().print(" | LSP:{c} {d}ms", .{ spinner, diagnostics.pending_ms });
        }
        try out.appendSlice("\x1b[48;5;52m\x1b[97m");
    } else {
        if (self.lsp_state.client.enabled and !self.lsp_state.client.session_ready) {
            try line.writer().print(" LSP: starting {c} ", .{spinner});
        } else if (self.lsp_state.client.enabled and diagnostics.pending_requests > 0) {
            try line.writer().print(" LSP: waiting {c} {d}ms ", .{ spinner, diagnostics.pending_ms });
        } else if (self.lsp_state.client.enabled) {
            if (diagnostics.last_latency_ms > 0) {
                try line.writer().print(" LSP: no diagnostics ({d}ms) ", .{diagnostics.last_latency_ms});
            } else {
                try line.appendSlice(" LSP: no diagnostics ");
            }
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

pub fn renderStatusBar(
    self: anytype,
    out: *std.array_list.Managed(u8),
    frame_allocator: std.mem.Allocator,
    terminal_tab_width: usize,
) !void {
    const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
    const visual_col = self.editor.buffer.visualColumnFromOffset(self.editor.cursor, terminal_tab_width);
    const file_name = self.editor.file_path orelse "[No Name]";
    const dirty_mark = if (self.editor.dirty) "*" else "";
    const lsp_mark = if (self.lsp_state.client.enabled)
        self.lsp_state.client.server_name
    else
        "off";

    var left = std.array_list.Managed(u8).init(frame_allocator);
    try left.appendSlice(" zicro ");
    try appendSanitizedSingleLine(&left, file_name);
    try left.appendSlice(dirty_mark);
    try left.append(' ');

    var right = std.array_list.Managed(u8).init(frame_allocator);
    const diagnostics = self.lsp_state.client.diagnostics();
    try right.writer().print("Ln {d}, Col {d} | LSP:{s} | RTT:{d}ms | Diag:{d}", .{
        pos.line + 1,
        visual_col + 1,
        lsp_mark,
        diagnostics.last_latency_ms,
        diagnostics.count,
    });
    if (self.ui.file_open_last_ms > 0) {
        try right.writer().print(" | Open:{d}ms", .{self.ui.file_open_last_ms});
    }
    if (self.ui.file_index_last_ms > 0 and self.ui.file_index_count > 0) {
        try right.writer().print(" | Index:{d}ms/{d}", .{ self.ui.file_index_last_ms, self.ui.file_index_count });
    }
    if (self.config.ui_perf_overlay) {
        const ema_whole = self.ui.perf_fps_ema_tenths / 10;
        const ema_frac = self.ui.perf_fps_ema_tenths % 10;
        const ft_avg_whole = self.ui.perf_ft_avg_tenths_ms / 10;
        const ft_avg_frac = self.ui.perf_ft_avg_tenths_ms % 10;
        const ft_p95_whole = self.ui.perf_ft_p95_tenths_ms / 10;
        const ft_p95_frac = self.ui.perf_ft_p95_tenths_ms % 10;
        try right.writer().print(" | FPS:{d}/{d}.{d} | FT:{d}.{d}/{d}.{d}ms", .{
            self.ui.perf_fps_avg,
            ema_whole,
            ema_frac,
            ft_avg_whole,
            ft_avg_frac,
            ft_p95_whole,
            ft_p95_frac,
        });
    }
    try right.append(' ');

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

pub fn renderMessageBar(self: anytype, out: *std.array_list.Managed(u8), terminal_tab_width: usize) !void {
    var line = std.array_list.Managed(u8).init(self.ui.render_arena.allocator());
    try appendSanitizedSingleLine(&line, self.ui.status.items);
    const limit = byteLimitForDisplayWidth(line.items, self.terminal.width, terminal_tab_width);
    try out.appendSlice("\x1b[90m");
    try out.appendSlice(line.items[0..limit]);
    try out.appendSlice("\x1b[0m");
}

pub fn renderPrompt(self: anytype, out: *std.array_list.Managed(u8)) !void {
    const label = promptLabel(self.ui.prompt.mode);
    try out.writer().print("\x1b[2;2H\x1b[48;5;238m\x1b[97m{s}{s}\x1b[0m", .{ label, self.ui.prompt.query.items });
}

pub fn selectionRangeOnLine(self: anytype, line_index: usize, line_len: usize, terminal_tab_width: usize) ?ByteRange {
    if (self.blockSelectionSpec()) |block| {
        if (line_index < block.start_line or line_index > block.end_line) return null;
        const line_start = self.editor.buffer.offsetFromLineCol(line_index, 0);
        const line_end = line_start + line_len;
        const sel_start = self.editor.buffer.offsetFromLineVisualCol(line_index, block.start_col, terminal_tab_width);
        const sel_end = self.editor.buffer.offsetFromLineVisualCol(line_index, block.end_col, terminal_tab_width);
        const range_start = @max(sel_start, line_start);
        const range_end = @min(sel_end, line_end);
        if (range_end <= range_start) return null;
        return .{
            .start = range_start - line_start,
            .end = range_end - line_start,
        };
    }

    const selected = self.selectedRange() orelse return null;
    const line_start = self.editor.buffer.offsetFromLineCol(line_index, 0);
    const line_end = line_start + line_len;
    const range_start = @max(selected.start, line_start);
    const range_end = @min(selected.end, line_end);
    if (range_end <= range_start) return null;
    return .{
        .start = range_start - line_start,
        .end = range_end - line_start,
    };
}

pub fn searchRangeOnLine(self: anytype, line_index: usize, line_len: usize) ?ByteRange {
    const search = self.editor.search_match orelse return null;
    const line_start = self.editor.buffer.offsetFromLineCol(line_index, 0);
    const line_end = line_start + line_len;
    const range_start = @max(search.start, line_start);
    const range_end = @min(search.end, line_end);
    if (range_end <= range_start) return null;
    return .{
        .start = range_start - line_start,
        .end = range_end - line_start,
    };
}

pub fn diagnosticSymbolRangeOnLine(self: anytype, line_index: usize, line: []const u8) ?ByteRange {
    const diagnostics = self.lsp_state.client.diagnostics();
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

pub fn renderPalette(self: anytype, out: *std.array_list.Managed(u8), frame_allocator: std.mem.Allocator) !void {
    const matches = try paletteMatches(self, frame_allocator);
    const label = paletteLabel(self);
    const palette_layout = computePaletteLayout(self);
    const row_top = palette_layout.row;
    const col = palette_layout.col;
    const width = palette_layout.width;
    const content_width = width -| 2;

    // Border top
    try out.writer().print("\x1b[{d};{d}H\x1b[38;5;240m+", .{ row_top, col });
    var x: usize = 0;
    while (x < content_width) : (x += 1) {
        try out.append('-');
    }
    try out.appendSlice("+\x1b[0m");

    // Header
    try out.writer().print("\x1b[{d};{d}H\x1b[38;5;240m|\x1b[48;5;236m\x1b[97m", .{ row_top + 1, col });
    try out.appendSlice(label);
    const label_width = displayWidth(label, 8);
    const suffix = if (self.ui.palette.mode == .files and self.ui.file_open_last_ms > 0)
        try std.fmt.allocPrint(frame_allocator, " | Open:{d}ms", .{self.ui.file_open_last_ms})
    else
        "";
    const suffix_width = displayWidth(suffix, 8);
    const query_width_cap = (content_width -| label_width) -| suffix_width;
    const query_clipped = self.ui.palette.query.items[0..byteLimitForDisplayWidth(self.ui.palette.query.items, query_width_cap, 8)];
    try out.appendSlice(query_clipped);
    try out.appendSlice(suffix);
    var header_pad = label_width + displayWidth(query_clipped, 8) + suffix_width;
    while (header_pad < content_width) : (header_pad += 1) try out.append(' ');
    try out.appendSlice("\x1b[0m\x1b[38;5;240m|\x1b[0m");

    const visible_rows = palette_layout.rows;
    var row: usize = 0;
    while (row < visible_rows) : (row += 1) {
        const has_item = row < matches.items.len;
        const text = if (has_item)
            switch (self.ui.palette.mode) {
                .commands => palette_entries[matches.items[row]].label,
                .files => self.file_index.items[matches.items[row]],
            }
        else
            "";
        const selected = has_item and row == @min(self.ui.palette.selected, matches.items.len - 1);
        const prefix = if (selected) "> " else "  ";
        try out.writer().print("\x1b[{d};{d}H\x1b[38;5;240m|\x1b[0m", .{ row_top + 2 + row, col });
        if (selected) {
            try out.appendSlice("\x1b[48;5;24m\x1b[97m");
        } else {
            try out.appendSlice("\x1b[48;5;235m\x1b[37m");
        }
        try out.appendSlice(prefix);
        const prefix_w = displayWidth(prefix, 8);
        const line_width_cap = content_width -| prefix_w;
        const clipped = text[0..byteLimitForDisplayWidth(text, line_width_cap, 8)];
        try out.appendSlice(clipped);
        var pad = prefix_w + displayWidth(clipped, 8);
        while (pad < content_width) : (pad += 1) try out.append(' ');
        try out.appendSlice("\x1b[0m\x1b[38;5;240m|\x1b[0m");
    }

    const metrics_row = row_top + 2 + visible_rows;
    try out.writer().print("\x1b[{d};{d}H\x1b[38;5;240m|\x1b[48;5;236m\x1b[97m", .{ metrics_row, col });
    if (self.ui.palette.mode == .files) {
        var metrics = std.array_list.Managed(u8).init(frame_allocator);
        try metrics.writer().print(" Open:{d}ms", .{self.ui.file_open_last_ms});
        if (self.ui.file_index_last_ms > 0 and self.ui.file_index_count > 0) {
            try metrics.writer().print(" | Index:{d}ms/{d}", .{ self.ui.file_index_last_ms, self.ui.file_index_count });
        }
        const metric_clipped = metrics.items[0..byteLimitForDisplayWidth(metrics.items, content_width, 8)];
        try out.appendSlice(metric_clipped);
        var metric_pad = displayWidth(metric_clipped, 8);
        while (metric_pad < content_width) : (metric_pad += 1) try out.append(' ');
    } else {
        var metric_pad: usize = 0;
        while (metric_pad < content_width) : (metric_pad += 1) try out.append(' ');
    }
    try out.appendSlice("\x1b[0m\x1b[38;5;240m|\x1b[0m");

    // Border bottom
    const row_bottom = metrics_row + 1;
    try out.writer().print("\x1b[{d};{d}H\x1b[38;5;240m+", .{ row_bottom, col });
    x = 0;
    while (x < content_width) : (x += 1) {
        try out.append('-');
    }
    try out.appendSlice("+\x1b[0m");
}

const PaletteLayout = struct {
    row: usize,
    col: usize,
    width: usize,
    rows: usize,
};

fn computePaletteLayout(self: anytype) PaletteLayout {
    const max_list_rows: usize = 8;
    const rows_total = max_list_rows + 4;
    const width_target = @min(@max(self.terminal.width * 70 / 100, @as(usize, 48)), self.terminal.width -| 2);
    const width = @max(width_target, @as(usize, 20));

    const row = if (self.terminal.height > rows_total)
        @max((self.terminal.height - rows_total) / 2, @as(usize, 2))
    else
        2;
    const col = if (self.terminal.width > width)
        @max((self.terminal.width - width) / 2, @as(usize, 2))
    else
        1;

    return .{
        .row = row,
        .col = col,
        .width = width,
        .rows = max_list_rows,
    };
}

fn paletteLabel(self: anytype) []const u8 {
    return switch (self.ui.palette.mode) {
        .commands => "Command: ",
        .files => "File: ",
    };
}

fn renderLspPanel(
    self: anytype,
    out: *std.array_list.Managed(u8),
    frame_allocator: std.mem.Allocator,
    top_bar_rows: usize,
    line_gutter_cols: usize,
    terminal_tab_width: usize,
) !void {
    _ = frame_allocator;

    const max_rows: usize = 8;
    const panel_width_cap: usize = @max(self.terminal.width -| 2, 1);
    const panel_width: usize = if (panel_width_cap >= 16) @min(panel_width_cap, @as(usize, 72)) else panel_width_cap;
    const anchor = popupAnchor(self, top_bar_rows, line_gutter_cols, terminal_tab_width, max_rows, panel_width);
    const start_row = anchor.row;
    const start_col = anchor.col;

    switch (self.ui.lsp_panel_mode) {
        .none => return,
        .completion => {
            const completion = self.lsp_state.client.completion();
            try out.writer().print("\x1b[{d};{d}H\x1b[48;5;238m\x1b[97m Completion \x1b[0m", .{ start_row - 1, start_col });
            if (completion.pending and completion.items.len == 0) {
                try out.writer().print("\x1b[{d};{d}H\x1b[K\x1b[48;5;240m\x1b[97m loading... \x1b[0m", .{ start_row, start_col });
                return;
            }
            const rows = @min(max_rows, completion.items.len);
            var row: usize = 0;
            while (row < rows) : (row += 1) {
                const selected = row == @min(self.ui.lsp_panel_selected, completion.items.len - 1);
                try out.writer().print("\x1b[{d};{d}H\x1b[K", .{ start_row + row, start_col });
                if (selected) try out.appendSlice("\x1b[48;5;240m\x1b[97m");
                const label = completion.items[row].label;
                const limit = byteLimitForDisplayWidth(label, panel_width, terminal_tab_width);
                try out.appendSlice(label[0..limit]);
                try out.appendSlice("\x1b[0m");
            }
        },
        .references => {
            const references = self.lsp_state.client.references();
            try out.writer().print("\x1b[{d};{d}H\x1b[48;5;238m\x1b[97m References \x1b[0m", .{ start_row - 1, start_col });
            if (references.pending and references.items.len == 0) {
                try out.writer().print("\x1b[{d};{d}H\x1b[K\x1b[48;5;240m\x1b[97m loading... \x1b[0m", .{ start_row, start_col });
                return;
            }
            const rows = @min(max_rows, references.items.len);
            var row: usize = 0;
            while (row < rows) : (row += 1) {
                const selected = row == @min(self.ui.lsp_panel_selected, references.items.len - 1);
                try out.writer().print("\x1b[{d};{d}H\x1b[K", .{ start_row + row, start_col });
                if (selected) try out.appendSlice("\x1b[48;5;240m\x1b[97m");
                const item = references.items[row];
                if (item.same_document) {
                    try out.writer().print("L{d}:{d}", .{ item.line + 1, item.character + 1 });
                } else {
                    try out.writer().print("external L{d}:{d}", .{ item.line + 1, item.character + 1 });
                }
                try out.appendSlice("\x1b[0m");
            }
        },
        .project_search => {
            const results = self.ui.project_search_results.items;
            try out.writer().print("\x1b[{d};{d}H\x1b[48;5;238m\x1b[97m Search \x1b[0m", .{ start_row - 1, start_col });
            const rows = @min(max_rows, results.len);
            var row: usize = 0;
            while (row < rows) : (row += 1) {
                const selected = row == @min(self.ui.lsp_panel_selected, results.len - 1);
                try out.writer().print("\x1b[{d};{d}H\x1b[K", .{ start_row + row, start_col });
                if (selected) {
                    try out.appendSlice("\x1b[48;5;240m\x1b[97m");
                } else {
                    try out.appendSlice("\x1b[48;5;235m\x1b[37m");
                }
                const item = results[row];
                const rel_path = if (self.project_root) |root|
                    if (std.mem.startsWith(u8, item.path, root) and item.path.len > root.len + 1)
                        item.path[root.len + 1 ..]
                    else
                        item.path
                else
                    item.path;
                try out.appendSlice("\x1b[96m");
                const path_limit = byteLimitForDisplayWidth(rel_path, panel_width / 2, terminal_tab_width);
                try out.appendSlice(rel_path[0..path_limit]);
                try out.appendSlice("\x1b[37m");
                try out.writer().print(":{d}:{d} ", .{ item.line, item.column });
                const text_limit = byteLimitForDisplayWidth(item.text, panel_width / 2, terminal_tab_width);
                try out.appendSlice(item.text[0..text_limit]);
                try out.appendSlice("\x1b[0m");
            }
        },
    }
}

fn renderHoverTooltip(
    self: anytype,
    out: *std.array_list.Managed(u8),
    frame_allocator: std.mem.Allocator,
    top_bar_rows: usize,
    line_gutter_cols: usize,
    terminal_tab_width: usize,
) !void {
    _ = frame_allocator;
    if (!self.ui.lsp_hover_tooltip_active) return;
    if (self.ui.lsp_hover_tooltip_text.items.len == 0) return;

    const max_rows_cfg: usize = @max(@as(usize, self.config.lsp_tooltip_max_rows), 1);
    const max_rows: usize = @max(@min(max_rows_cfg, self.terminal.height -| 2), 1);
    const width_cap: usize = @max(self.terminal.width -| 2, 1);
    const width_cfg: usize = @max(@as(usize, self.config.lsp_tooltip_max_width), 16);
    const width: usize = if (width_cap >= 16) @min(width_cfg, width_cap) else width_cap;
    const anchor = popupAnchor(self, top_bar_rows, line_gutter_cols, terminal_tab_width, max_rows, width);
    const start_row = anchor.row;
    const start_col = anchor.col;

    try out.writer().print("\x1b[{d};{d}H\x1b[48;5;238m\x1b[97m Hover \x1b[0m", .{ start_row - 1, start_col });

    const text = self.ui.lsp_hover_tooltip_text.items;
    var text_index: usize = 0;
    var row: usize = 0;
    while (row < max_rows and text_index <= text.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, text, text_index, '\n') orelse text.len;
        var segment_start = text_index;
        const segment_end = next_newline;

        if (segment_start == segment_end) {
            try out.writer().print("\x1b[{d};{d}H\x1b[K\x1b[48;5;240m\x1b[97m", .{ start_row + row, start_col });
            var pad_blank: usize = 0;
            while (pad_blank < width) : (pad_blank += 1) try out.append(' ');
            try out.appendSlice("\x1b[0m");
            row += 1;
        } else {
            while (segment_start < segment_end and row < max_rows) {
                const segment = text[segment_start..segment_end];
                var limit = byteLimitForDisplayWidth(segment, width, terminal_tab_width);
                if (limit == 0 and segment.len > 0) {
                    limit = layout.utf8Step(segment, 0);
                }
                const chunk = segment[0..@min(limit, segment.len)];
                const used = displayWidth(chunk, terminal_tab_width);

                try out.writer().print("\x1b[{d};{d}H\x1b[K\x1b[48;5;240m\x1b[97m", .{ start_row + row, start_col });
                try out.appendSlice(chunk);
                var pad: usize = used;
                while (pad < width) : (pad += 1) try out.append(' ');
                try out.appendSlice("\x1b[0m");

                segment_start += chunk.len;
                row += 1;
            }
        }

        if (next_newline >= text.len) break;
        text_index = next_newline + 1;
    }
}

fn renderDebugPanel(
    self: anytype,
    out: *std.array_list.Managed(u8),
    top_bar_rows: usize,
    terminal_tab_width: usize,
) !void {
    const panel_width: usize = @min(@as(usize, 56), self.terminal.width -| 2);
    const panel_height: usize = 8;
    const row: usize = top_bar_rows + 2;
    const col: usize = if (self.terminal.width > panel_width + 1) self.terminal.width - panel_width else 1;

    const diagnostics = self.lsp_state.client.diagnostics();
    const lsp_state = if (!self.lsp_state.client.enabled)
        "off"
    else if (!self.lsp_state.client.session_ready)
        "starting"
    else if (diagnostics.pending_requests > 0)
        "waiting"
    else
        "ready";
    const file_name = self.editor.file_path orelse "[No Name]";
    const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
    const visual_col = self.editor.buffer.visualColumnFromOffset(self.editor.cursor, terminal_tab_width);

    try out.writer().print("\x1b[{d};{d}H\x1b[38;5;240m+\x1b[0m", .{ row, col });
    var x: usize = 0;
    while (x < panel_width - 2) : (x += 1) try out.append('-');
    try out.appendSlice("+\x1b[0m");

    const rows = [_][]const u8{
        " Debug",
    };
    _ = rows;

    var line_index: usize = 0;
    while (line_index < panel_height - 2) : (line_index += 1) {
        try out.writer().print("\x1b[{d};{d}H\x1b[38;5;240m|\x1b[48;5;235m\x1b[37m", .{ row + 1 + line_index, col });
        var line = std.array_list.Managed(u8).init(self.ui.render_arena.allocator());
        switch (line_index) {
            0 => try line.writer().print(" LSP:{s} pending:{d} rtt:{d}ms", .{ lsp_state, diagnostics.pending_requests, diagnostics.last_latency_ms }),
            1 => try line.writer().print(" Diag:{d} Open:{d}ms Index:{d}ms/{d}", .{ diagnostics.count, self.ui.file_open_last_ms, self.ui.file_index_last_ms, self.ui.file_index_count }),
            2 => try line.writer().print(" FPS avg:{d} ema:{d}.{d}", .{ self.ui.perf_fps_avg, self.ui.perf_fps_ema_tenths / 10, self.ui.perf_fps_ema_tenths % 10 }),
            3 => try line.writer().print(" FT avg:{d}.{d} p95:{d}.{d}ms", .{ self.ui.perf_ft_avg_tenths_ms / 10, self.ui.perf_ft_avg_tenths_ms % 10, self.ui.perf_ft_p95_tenths_ms / 10, self.ui.perf_ft_p95_tenths_ms % 10 }),
            4 => {
                try line.appendSlice(" File: ");
                try appendSanitizedSingleLine(&line, file_name);
            },
            5 => try line.writer().print(" Cursor: Ln {d}, Col {d}", .{ pos.line + 1, visual_col + 1 }),
            else => {},
        }
        const line_clipped = line.items[0..byteLimitForDisplayWidth(line.items, panel_width - 2, terminal_tab_width)];
        try out.appendSlice(line_clipped);
        var pad = displayWidth(line_clipped, terminal_tab_width);
        while (pad < panel_width - 2) : (pad += 1) try out.append(' ');
        try out.appendSlice("\x1b[0m\x1b[38;5;240m|\x1b[0m");
    }

    try out.writer().print("\x1b[{d};{d}H\x1b[38;5;240m+\x1b[0m", .{ row + panel_height - 1, col });
    x = 0;
    while (x < panel_width - 2) : (x += 1) try out.append('-');
    try out.appendSlice("+\x1b[0m");
}

const PopupAnchor = struct {
    row: usize,
    col: usize,
};

fn popupAnchor(
    self: anytype,
    top_bar_rows: usize,
    line_gutter_cols: usize,
    terminal_tab_width: usize,
    desired_rows: usize,
    width: usize,
) PopupAnchor {
    const pos = self.editor.buffer.lineColFromOffset(self.editor.cursor);
    const visible_line = if (pos.line >= self.editor.scroll_y) pos.line - self.editor.scroll_y else 0;
    const cursor_row = top_bar_rows + visible_line + 1;

    var row = cursor_row + 1;
    const min_row: usize = 2;
    const max_row = if (self.terminal.height > desired_rows + 1) self.terminal.height - desired_rows else min_row;
    if (row > max_row) {
        row = if (cursor_row > desired_rows + 1) cursor_row - desired_rows else min_row;
    }
    if (row < min_row) row = min_row;

    const visual_col = self.editor.buffer.visualColumnFromOffset(self.editor.cursor, terminal_tab_width);
    var col = visual_col + line_gutter_cols + 2;
    if (col + width > self.terminal.width) {
        col = if (self.terminal.width > width + 1) self.terminal.width - width else 1;
    }
    if (col < 1) col = 1;

    return .{
        .row = row,
        .col = col,
    };
}

pub fn paletteMatches(self: anytype, allocator: std.mem.Allocator) !std.array_list.Managed(usize) {
    const ScoredMatch = struct {
        index: usize,
        score: i32,
    };

    var matches = std.array_list.Managed(usize).init(allocator);
    var scored = std.array_list.Managed(ScoredMatch).init(allocator);
    defer scored.deinit();

    const query = self.ui.palette.query.items;
    switch (self.ui.palette.mode) {
        .commands => {
            if (query.len == 0) {
                for (palette_entries, 0..) |_, index| {
                    try matches.append(index);
                }
                return matches;
            }

            for (palette_entries, 0..) |entry, index| {
                if (containsIgnoreCase(entry.label, query)) {
                    try scored.append(.{ .index = index, .score = pathMatchScore(entry.label, query) });
                }
            }
        },
        .files => {
            if (query.len == 0) {
                const limit = @min(self.file_index.items.len, @as(usize, 128));
                var i: usize = 0;
                while (i < limit) : (i += 1) {
                    try matches.append(i);
                }
                return matches;
            }

            for (self.file_index.items, 0..) |path, index| {
                if (fuzzyPathQueryScore(path, query)) |score| {
                    var rank = score;
                    if (self.file_frecency.get(path)) |freq| {
                        const visits_bonus = @as(i32, @intCast(@min(freq.visits, @as(u32, 64)))) * 3;
                        rank -= visits_bonus;
                        const age_ticks = if (self.file_access_tick > freq.last_tick)
                            self.file_access_tick - freq.last_tick
                        else
                            0;
                        if (age_ticks <= 2) {
                            rank -= 24;
                        } else if (age_ticks <= 8) {
                            rank -= 16;
                        } else if (age_ticks <= 32) {
                            rank -= 8;
                        }
                    }
                    try scored.append(.{ .index = index, .score = rank });
                }
            }
        },
    }

    std.mem.sort(ScoredMatch, scored.items, {}, struct {
        fn lessThan(_: void, lhs: ScoredMatch, rhs: ScoredMatch) bool {
            if (lhs.score == rhs.score) return lhs.index < rhs.index;
            return lhs.score < rhs.score;
        }
    }.lessThan);

    for (scored.items) |entry| {
        try matches.append(entry.index);
    }

    return matches;
}

fn pathMatchScore(path: []const u8, query: []const u8) i32 {
    var score: i32 = @intCast(path.len);

    if (std.mem.endsWith(u8, path, query)) score -= 12;
    if (std.mem.indexOf(u8, path, query)) |idx| {
        score -= @divTrunc(@as(i32, @intCast(@min(idx, @as(usize, 256)))), 4);
    }
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash + 1 < path.len and std.mem.indexOf(u8, path[slash + 1 ..], query) != null) {
            score -= 16;
        }
    }

    return score;
}

fn fuzzyPathQueryScore(path: []const u8, query: []const u8) ?i32 {
    var score: i32 = @as(i32, @intCast(@min(path.len, @as(usize, 4096))));
    const basename_start = (std.mem.lastIndexOfScalar(u8, path, '/') orelse 0) + @as(usize, 1);

    var token_start: usize = 0;
    var token_count: usize = 0;
    while (true) {
        while (token_start < query.len and std.ascii.isWhitespace(query[token_start])) : (token_start += 1) {}
        if (token_start >= query.len) break;

        var token_end = token_start;
        while (token_end < query.len and !std.ascii.isWhitespace(query[token_end])) : (token_end += 1) {}
        const token = query[token_start..token_end];
        token_count += 1;

        const idx = indexOfIgnoreCase(path, token) orelse return null;
        score += @divTrunc(@as(i32, @intCast(@min(idx, @as(usize, 2048)))), 4);

        if (idx >= basename_start) score -= 18;
        if (idx == basename_start) score -= 12;
        if (startsWithIgnoreCase(path[basename_start..], token)) score -= 10;

        token_start = token_end;
    }

    if (token_count == 0) return null;
    return score;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }
    return null;
}

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

fn promptLabel(mode: PromptMode) []const u8 {
    return switch (mode) {
        .goto_line => " Goto line: ",
        .regex_search => " Regex: ",
        .project_search => " Search: ",
    };
}

fn lspSpinner(frame: usize) u8 {
    const frames = "|/-\\";
    return frames[frame % frames.len];
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

        const step = layout.utf8Step(text, index);
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

fn displayWidth(bytes: []const u8, tab_width_input: usize) usize {
    return layout.displayWidth(bytes, tab_width_input);
}

fn byteLimitForDisplayWidth(bytes: []const u8, max_width: usize, tab_width_input: usize) usize {
    return layout.byteLimitForDisplayWidth(bytes, max_width, tab_width_input);
}
