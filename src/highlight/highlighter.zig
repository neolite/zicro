const std = @import("std");

pub const Language = enum {
    plain,
    zig,
    javascript,
    typescript,
    bash,
    json,
};

pub const TokenType = enum {
    comment,
    string,
    number,
    keyword,
    operator,
    macro,
    command,
};

pub const Span = struct {
    start: usize,
    end: usize,
    token: TokenType,
};

pub const LineState = struct {
    in_block_comment: bool = false,
    in_template_string: bool = false,
    template_expr_depth: u32 = 0,
};

pub const LineHighlight = struct {
    spans: []Span,
    next_state: LineState,
};

const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "const", {} },
    .{ "var", {} },
    .{ "fn", {} },
    .{ "pub", {} },
    .{ "struct", {} },
    .{ "enum", {} },
    .{ "union", {} },
    .{ "if", {} },
    .{ "else", {} },
    .{ "switch", {} },
    .{ "while", {} },
    .{ "for", {} },
    .{ "break", {} },
    .{ "continue", {} },
    .{ "return", {} },
    .{ "try", {} },
    .{ "catch", {} },
    .{ "defer", {} },
    .{ "errdefer", {} },
    .{ "comptime", {} },
    .{ "opaque", {} },
    .{ "usingnamespace", {} },
});

const ts_js_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "const", {} },
    .{ "let", {} },
    .{ "var", {} },
    .{ "function", {} },
    .{ "class", {} },
    .{ "extends", {} },
    .{ "return", {} },
    .{ "if", {} },
    .{ "else", {} },
    .{ "for", {} },
    .{ "while", {} },
    .{ "switch", {} },
    .{ "case", {} },
    .{ "break", {} },
    .{ "continue", {} },
    .{ "try", {} },
    .{ "catch", {} },
    .{ "finally", {} },
    .{ "throw", {} },
    .{ "import", {} },
    .{ "export", {} },
    .{ "from", {} },
    .{ "as", {} },
    .{ "new", {} },
    .{ "this", {} },
    .{ "super", {} },
    .{ "async", {} },
    .{ "await", {} },
    .{ "interface", {} },
    .{ "type", {} },
    .{ "implements", {} },
    .{ "public", {} },
    .{ "private", {} },
    .{ "protected", {} },
    .{ "readonly", {} },
    .{ "enum", {} },
    .{ "namespace", {} },
});

const bash_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "if", {} },
    .{ "then", {} },
    .{ "fi", {} },
    .{ "for", {} },
    .{ "in", {} },
    .{ "do", {} },
    .{ "done", {} },
    .{ "case", {} },
    .{ "esac", {} },
    .{ "while", {} },
    .{ "until", {} },
    .{ "function", {} },
    .{ "select", {} },
    .{ "time", {} },
    .{ "coproc", {} },
});

const json_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "true", {} },
    .{ "false", {} },
    .{ "null", {} },
});

pub fn emptyState() LineState {
    return .{};
}

pub fn detectLanguage(path_opt: ?[]const u8) Language {
    const path = path_opt orelse return .plain;
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return .javascript;
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or std.mem.eql(u8, ext, ".mts") or std.mem.eql(u8, ext, ".cts")) return .typescript;
    if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash")) return .bash;
    if (std.mem.eql(u8, ext, ".json")) return .json;
    return .plain;
}

pub fn highlightLine(allocator: std.mem.Allocator, language: Language, line: []const u8) ![]Span {
    const highlighted = try highlightLineWithState(allocator, language, line, emptyState());
    return highlighted.spans;
}

pub fn highlightLineWithState(
    allocator: std.mem.Allocator,
    language: Language,
    line: []const u8,
    state_in: LineState,
) !LineHighlight {
    var spans = std.array_list.Managed(Span).init(allocator);
    const next_state = try scanLine(&spans, language, line, state_in);
    return .{
        .spans = try spans.toOwnedSlice(),
        .next_state = next_state,
    };
}

pub fn advanceState(language: Language, line: []const u8, state_in: LineState) LineState {
    return scanLine(null, language, line, state_in) catch state_in;
}

pub fn ansiForToken(token: TokenType) []const u8 {
    return switch (token) {
        .comment => "\x1b[90m",
        .string => "\x1b[32m",
        .number => "\x1b[36m",
        .keyword => "\x1b[35m",
        .operator => "\x1b[33m",
        .macro => "\x1b[34m",
        .command => "\x1b[96m",
    };
}

fn scanLine(
    spans_opt: ?*std.array_list.Managed(Span),
    language: Language,
    line: []const u8,
    state_in: LineState,
) !LineState {
    var state = state_in;
    const is_js_ts = language == .javascript or language == .typescript;

    var i: usize = 0;
    while (i < line.len) {
        if (is_js_ts and state.in_block_comment) {
            const start = i;
            if (indexOfBlockCommentEnd(line, i)) |end_index| {
                i = end_index + 2;
                try appendSpan(spans_opt, start, i, .comment);
                state.in_block_comment = false;
                continue;
            }
            try appendSpan(spans_opt, start, line.len, .comment);
            return state;
        }

        if (is_js_ts and state.in_template_string and state.template_expr_depth == 0) {
            i = try scanTemplateText(spans_opt, line, i, i, &state);
            if (i >= line.len) return state;
            continue;
        }

        if (isSingleLineCommentStart(language, line, i)) {
            try appendSpan(spans_opt, i, line.len, .comment);
            break;
        }

        if (isBlockCommentStart(language, line, i)) {
            const start = i;
            i += 2;
            if (indexOfBlockCommentEnd(line, i)) |end_index| {
                i = end_index + 2;
                try appendSpan(spans_opt, start, i, .comment);
            } else {
                try appendSpan(spans_opt, start, line.len, .comment);
                state.in_block_comment = true;
                break;
            }
            continue;
        }

        const ch = line[i];
        if (is_js_ts and ch == '`') {
            state.in_template_string = true;
            state.template_expr_depth = 0;
            i = try scanTemplateText(spans_opt, line, i + 1, i, &state);
            if (i >= line.len) return state;
            continue;
        }

        if (ch == '"' or ch == '\'') {
            const end = scanQuotedString(line, i, ch);
            try appendSpan(spans_opt, i, end, .string);
            i = end;
            continue;
        }

        if (is_js_ts and state.in_template_string and state.template_expr_depth > 0) {
            if (ch == '{') {
                state.template_expr_depth += 1;
                try appendSpan(spans_opt, i, i + 1, .operator);
                i += 1;
                continue;
            }
            if (ch == '}') {
                if (state.template_expr_depth > 0) state.template_expr_depth -= 1;
                try appendSpan(spans_opt, i, i + 1, .operator);
                i += 1;
                continue;
            }
        }

        if (std.ascii.isDigit(ch)) {
            const start = i;
            i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_' or line[i] == '.')) : (i += 1) {}
            try appendSpan(spans_opt, start, i, .number);
            continue;
        }

        if (ch == '@' and language == .zig) {
            const start = i;
            i += 1;
            while (i < line.len and isIdent(line[i])) : (i += 1) {}
            try appendSpan(spans_opt, start, i, .macro);
            continue;
        }

        if (isIdentStart(ch)) {
            const start = i;
            i += 1;
            while (i < line.len and isIdent(line[i])) : (i += 1) {}
            const ident = line[start..i];

            if (isKeyword(language, ident)) {
                try appendSpan(spans_opt, start, i, .keyword);
            } else if (language == .bash and start == 0) {
                try appendSpan(spans_opt, start, i, .command);
            }
            continue;
        }

        if (isOperator(ch)) {
            try appendSpan(spans_opt, i, i + 1, .operator);
        }

        i += 1;
    }

    return state;
}

fn scanTemplateText(
    spans_opt: ?*std.array_list.Managed(Span),
    line: []const u8,
    cursor_index: usize,
    segment_start_input: usize,
    state: *LineState,
) !usize {
    var i = cursor_index;
    const segment_start = segment_start_input;

    while (i < line.len) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 2;
            continue;
        }

        if (line[i] == '`') {
            i += 1;
            try appendSpan(spans_opt, segment_start, i, .string);
            state.in_template_string = false;
            state.template_expr_depth = 0;
            return i;
        }

        if (line[i] == '$' and i + 1 < line.len and line[i + 1] == '{') {
            try appendSpan(spans_opt, segment_start, i, .string);
            try appendSpan(spans_opt, i, i + 2, .operator);
            i += 2;
            state.in_template_string = true;
            state.template_expr_depth = 1;
            return i;
        }

        i += 1;
    }

    try appendSpan(spans_opt, segment_start, line.len, .string);
    state.in_template_string = true;
    return line.len;
}

fn scanQuotedString(line: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (line[i] == quote) {
            return i + 1;
        }
    }
    return line.len;
}

fn appendSpan(
    spans_opt: ?*std.array_list.Managed(Span),
    start: usize,
    end: usize,
    token: TokenType,
) !void {
    if (end <= start) return;
    const spans = spans_opt orelse return;
    try spans.append(.{
        .start = start,
        .end = end,
        .token = token,
    });
}

fn indexOfBlockCommentEnd(line: []const u8, index: usize) ?usize {
    if (index >= line.len) return null;
    var i = index;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == '*' and line[i + 1] == '/') return i;
    }
    return null;
}

fn isSingleLineCommentStart(language: Language, line: []const u8, index: usize) bool {
    if (language == .zig or language == .javascript or language == .typescript) {
        return index + 1 < line.len and line[index] == '/' and line[index + 1] == '/';
    }
    if (language == .bash) {
        return line[index] == '#';
    }
    return false;
}

fn isBlockCommentStart(language: Language, line: []const u8, index: usize) bool {
    if (language != .javascript and language != .typescript) return false;
    return index + 1 < line.len and line[index] == '/' and line[index + 1] == '*';
}

fn isKeyword(language: Language, ident: []const u8) bool {
    return switch (language) {
        .zig => zig_keywords.has(ident),
        .javascript, .typescript => ts_js_keywords.has(ident),
        .bash => bash_keywords.has(ident),
        .json => json_keywords.has(ident),
        .plain => false,
    };
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isOperator(ch: u8) bool {
    return switch (ch) {
        '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?', ':', '.', ',', ';', '(', ')', '[', ']', '{', '}' => true,
        else => false,
    };
}

test "zig keyword highlighting" {
    const allocator = std.testing.allocator;
    const spans = try highlightLine(allocator, .zig, "const x = @import(\"std\"); // hi");
    defer allocator.free(spans);

    try std.testing.expect(spans.len >= 3);
}

test "javascript multiline block comment keeps state" {
    const allocator = std.testing.allocator;

    const first = try highlightLineWithState(allocator, .javascript, "const x = 1; /* hello", emptyState());
    defer allocator.free(first.spans);
    try std.testing.expect(first.next_state.in_block_comment);

    const second = try highlightLineWithState(allocator, .javascript, "world */ const y = 2;", first.next_state);
    defer allocator.free(second.spans);
    try std.testing.expect(!second.next_state.in_block_comment);
}

test "template literals carry expression state across lines" {
    const allocator = std.testing.allocator;

    const first = try highlightLineWithState(allocator, .typescript, "const x = `hello ${name", emptyState());
    defer allocator.free(first.spans);
    try std.testing.expect(first.next_state.in_template_string);
    try std.testing.expectEqual(@as(u32, 1), first.next_state.template_expr_depth);

    const second = try highlightLineWithState(allocator, .typescript, " + suffix}`;", first.next_state);
    defer allocator.free(second.spans);
    try std.testing.expect(!second.next_state.in_template_string);
    try std.testing.expectEqual(@as(u32, 0), second.next_state.template_expr_depth);
}
