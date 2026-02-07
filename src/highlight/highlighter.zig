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
    in_jsx_tag: bool = false,
    jsx_attr_quote: ?u8 = null,
    in_heredoc: bool = false,
    heredoc_delim_len: u8 = 0,
    heredoc_delim: [64]u8 = [_]u8{0} ** 64,
    heredoc_strip_tabs: bool = false,
    heredoc_quoted_delim: bool = false,
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
    .{ "declare", {} },
    .{ "module", {} },
    .{ "abstract", {} },
    .{ "static", {} },
    .{ "yield", {} },
    .{ "keyof", {} },
    .{ "infer", {} },
    .{ "is", {} },
    .{ "satisfies", {} },
    .{ "asserts", {} },
    .{ "unknown", {} },
    .{ "never", {} },
    .{ "any", {} },
    .{ "void", {} },
    .{ "string", {} },
    .{ "number", {} },
    .{ "boolean", {} },
    .{ "bigint", {} },
    .{ "symbol", {} },
    .{ "object", {} },
    .{ "undefined", {} },
    .{ "null", {} },
    .{ "true", {} },
    .{ "false", {} },
    .{ "typeof", {} },
    .{ "instanceof", {} },
    .{ "delete", {} },
    .{ "in", {} },
    .{ "of", {} },
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
    const is_bash = language == .bash;

    var i: usize = 0;
    while (i < line.len) {
        if (is_bash and state.in_heredoc) {
            try appendSpan(spans_opt, 0, line.len, .string);
            if (isBashHeredocTerminator(line, &state)) {
                clearHeredocState(&state);
            }
            return state;
        }

        if (is_js_ts and state.in_jsx_tag) {
            i = try scanJsxTag(spans_opt, line, i, &state);
            if (i >= line.len) return state;
            continue;
        }

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
        if (is_js_ts and isPotentialJsxTagStart(line, i)) {
            i = try scanJsxTag(spans_opt, line, i, &state);
            if (i >= line.len) return state;
            continue;
        }

        if (is_js_ts and isRegexLiteralStart(line, i)) {
            const end = scanRegexLiteral(line, i);
            if (end > i + 1) {
                try appendSpan(spans_opt, i, end, .string);
                i = end;
                continue;
            }
        }

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

        if (is_bash and ch == '<' and i + 1 < line.len and line[i + 1] == '<') {
            const heredoc = scanBashHeredocStart(line, i);
            try appendSpan(spans_opt, i, heredoc.operator_end, .operator);
            if (heredoc.word_end > heredoc.word_start) {
                try appendSpan(spans_opt, heredoc.word_start, heredoc.word_end, .string);
            }
            if (heredoc.valid) {
                setBashHeredocState(&state, line, heredoc);
            }
            i = heredoc.next_index;
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
            i = scanNumberLiteral(line, i);
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

const BashHeredocStart = struct {
    operator_end: usize,
    word_start: usize,
    word_end: usize,
    word_unquoted_start: usize,
    word_unquoted_end: usize,
    strip_tabs: bool,
    quoted_delim: bool,
    valid: bool,
    next_index: usize,
};

fn scanBashHeredocStart(line: []const u8, start: usize) BashHeredocStart {
    var out = BashHeredocStart{
        .operator_end = start + 2,
        .word_start = start + 2,
        .word_end = start + 2,
        .word_unquoted_start = start + 2,
        .word_unquoted_end = start + 2,
        .strip_tabs = false,
        .quoted_delim = false,
        .valid = false,
        .next_index = start + 2,
    };

    if (start + 2 < line.len and line[start + 2] == '<') {
        out.operator_end = start + 3;
        out.next_index = start + 3;
        return out;
    }

    var i = start + 2;
    if (i < line.len and line[i] == '-') {
        out.strip_tabs = true;
        i += 1;
        out.operator_end = i;
        out.next_index = i;
    }

    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    out.word_start = i;

    if (i >= line.len) {
        out.next_index = i;
        return out;
    }

    if (line[i] == '\'' or line[i] == '"') {
        const quote = line[i];
        const end = scanQuotedString(line, i, quote);
        out.word_end = end;
        out.word_unquoted_start = i + 1;
        out.word_unquoted_end = if (end > i and end <= line.len and line[end - 1] == quote) end - 1 else i + 1;
        out.quoted_delim = true;
        out.valid = end > i + 1 and end <= line.len and line[end - 1] == quote;
        out.next_index = end;
        return out;
    }

    if (line[i] == '\\') {
        out.quoted_delim = true;
        i += 1;
        out.word_unquoted_start = i;
    } else {
        out.word_unquoted_start = i;
    }

    while (i < line.len and !isBashWordBoundary(line[i])) : (i += 1) {}

    out.word_end = i;
    out.word_unquoted_end = i;
    out.valid = out.word_unquoted_end > out.word_unquoted_start;
    out.next_index = i;
    return out;
}

fn setBashHeredocState(state: *LineState, line: []const u8, heredoc: BashHeredocStart) void {
    if (!heredoc.valid) return;
    const delim_len = heredoc.word_unquoted_end - heredoc.word_unquoted_start;
    if (delim_len == 0 or delim_len > state.heredoc_delim.len) return;

    @memset(state.heredoc_delim[0..], 0);
    std.mem.copyForwards(u8, state.heredoc_delim[0..delim_len], line[heredoc.word_unquoted_start..heredoc.word_unquoted_end]);
    state.in_heredoc = true;
    state.heredoc_delim_len = @as(u8, @intCast(delim_len));
    state.heredoc_strip_tabs = heredoc.strip_tabs;
    state.heredoc_quoted_delim = heredoc.quoted_delim;
}

fn clearHeredocState(state: *LineState) void {
    state.in_heredoc = false;
    state.heredoc_delim_len = 0;
    @memset(state.heredoc_delim[0..], 0);
    state.heredoc_strip_tabs = false;
    state.heredoc_quoted_delim = false;
}

fn isBashHeredocTerminator(line: []const u8, state: *const LineState) bool {
    if (!state.in_heredoc or state.heredoc_delim_len == 0) return false;

    var start: usize = 0;
    if (state.heredoc_strip_tabs) {
        while (start < line.len and line[start] == '\t') : (start += 1) {}
    }

    const delim_len: usize = @as(usize, state.heredoc_delim_len);
    const delim = state.heredoc_delim[0..delim_len];
    return std.mem.eql(u8, line[start..], delim);
}

fn isBashWordBoundary(ch: u8) bool {
    return std.ascii.isWhitespace(ch) or switch (ch) {
        ';', '&', '|', '<', '>', '(', ')' => true,
        else => false,
    };
}

fn scanJsxTag(
    spans_opt: ?*std.array_list.Managed(Span),
    line: []const u8,
    start_index: usize,
    state: *LineState,
) !usize {
    var i = start_index;
    if (!state.in_jsx_tag) {
        state.in_jsx_tag = true;
        try appendSpan(spans_opt, i, i + 1, .operator); // <
        i += 1;
        if (i < line.len and line[i] == '/') {
            try appendSpan(spans_opt, i, i + 1, .operator); // </
            i += 1;
        }
    }

    while (i < line.len) {
        if (state.jsx_attr_quote) |quote| {
            const end = scanQuotedString(line, i, quote);
            try appendSpan(spans_opt, i, end, .string);
            if (end <= line.len and end > i and line[end - 1] == quote) {
                state.jsx_attr_quote = null;
            }
            i = end;
            continue;
        }

        const ch = line[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
            continue;
        }

        if (ch == '"' or ch == '\'') {
            state.jsx_attr_quote = ch;
            continue;
        }

        if (ch == '{' or ch == '}' or ch == '=' or ch == ':') {
            try appendSpan(spans_opt, i, i + 1, .operator);
            i += 1;
            continue;
        }

        if (ch == '/' and i + 1 < line.len and line[i + 1] == '>') {
            try appendSpan(spans_opt, i, i + 2, .operator); // />
            i += 2;
            state.in_jsx_tag = false;
            return i;
        }

        if (ch == '>') {
            try appendSpan(spans_opt, i, i + 1, .operator); // >
            i += 1;
            state.in_jsx_tag = false;
            return i;
        }

        if (isIdentStart(ch)) {
            const ident_start = i;
            i += 1;
            while (i < line.len and isJsxIdent(line[i])) : (i += 1) {}

            var probe = i;
            while (probe < line.len and std.ascii.isWhitespace(line[probe])) : (probe += 1) {}
            const token: TokenType = if (probe < line.len and line[probe] == '=') .keyword else .macro;
            try appendSpan(spans_opt, ident_start, i, token);
            continue;
        }

        try appendSpan(spans_opt, i, i + 1, .operator);
        i += 1;
    }

    return i;
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

fn scanNumberLiteral(line: []const u8, start: usize) usize {
    var i = start;
    if (line[start] == '0' and start + 1 < line.len) {
        const prefix = std.ascii.toLower(line[start + 1]);
        if (prefix == 'x' or prefix == 'b' or prefix == 'o') {
            i = start + 2;
            while (i < line.len and isNumOrSep(line[i])) : (i += 1) {}
            if (i < line.len and line[i] == 'n') i += 1;
            return i;
        }
    }

    i += 1;
    while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) : (i += 1) {}
    if (i < line.len and line[i] == '.') {
        i += 1;
        while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) : (i += 1) {}
    }
    if (i < line.len and (line[i] == 'e' or line[i] == 'E')) {
        i += 1;
        if (i < line.len and (line[i] == '+' or line[i] == '-')) i += 1;
        while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) : (i += 1) {}
    }
    if (i < line.len and line[i] == 'n') i += 1;
    return i;
}

fn isRegexLiteralStart(line: []const u8, index: usize) bool {
    if (index >= line.len or line[index] != '/') return false;
    if (index + 1 >= line.len) return false;
    const next = line[index + 1];
    if (next == '/' or next == '*' or next == '=') return false;

    const prev = prevSignificantChar(line, index);
    if (prev == null) return true;
    return switch (prev.?) {
        '(', '[', '{', ',', ';', ':', '=', '!', '?', '&', '|', '^', '~', '+', '-', '*', '%', '<', '>' => true,
        else => false,
    };
}

fn isPotentialJsxTagStart(line: []const u8, index: usize) bool {
    if (index >= line.len or line[index] != '<') return false;
    if (index + 1 >= line.len) return false;

    const next = line[index + 1];
    const next_ok = next == '/' or next == '>' or std.ascii.isAlphabetic(next);
    if (!next_ok) return false;

    const prev = prevSignificantChar(line, index);
    if (prev == null) return true;
    return switch (prev.?) {
        '(', '[', '{', ',', ';', ':', '=', '!', '?', '&', '|', '^', '~', '+', '-', '*', '%', '<', '>' => true,
        else => false,
    };
}

fn scanRegexLiteral(line: []const u8, start: usize) usize {
    var i = start + 1;
    var escaped = false;
    var in_class = false;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '[') {
            in_class = true;
            continue;
        }
        if (ch == ']') {
            in_class = false;
            continue;
        }
        if (ch == '/' and !in_class) {
            i += 1;
            while (i < line.len and std.ascii.isAlphabetic(line[i])) : (i += 1) {}
            return i;
        }
    }
    return start + 1;
}

fn prevSignificantChar(line: []const u8, index: usize) ?u8 {
    if (index == 0) return null;
    var i = index;
    while (i > 0) {
        i -= 1;
        const ch = line[i];
        if (!std.ascii.isWhitespace(ch)) return ch;
    }
    return null;
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

fn isJsxIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.';
}

fn isNumOrSep(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isOperator(ch: u8) bool {
    return switch (ch) {
        '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?', ':', '.', ',', ';', '(', ')', '[', ']', '{', '}' => true,
        else => false,
    };
}

fn hasTokenSpan(spans: []const Span, token: TokenType, start: usize, end: usize) bool {
    for (spans) |span| {
        if (span.token == token and span.start == start and span.end == end) return true;
    }
    return false;
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

test "typescript regex literal highlighting" {
    const allocator = std.testing.allocator;
    const spans = try highlightLine(allocator, .typescript, "const r = /ab+c\\/d/i; value / 2;");
    defer allocator.free(spans);

    var has_regex = false;
    for (spans) |span| {
        if (span.token == .string and span.start <= 10 and span.end >= 20) {
            has_regex = true;
            break;
        }
    }
    try std.testing.expect(has_regex);
}

test "tsx jsx tag highlighting keeps state across lines" {
    const allocator = std.testing.allocator;

    const first = try highlightLineWithState(allocator, .typescript, "<Button", emptyState());
    defer allocator.free(first.spans);
    try std.testing.expect(first.next_state.in_jsx_tag);

    const second = try highlightLineWithState(allocator, .typescript, "  title=\"hi\">", first.next_state);
    defer allocator.free(second.spans);
    try std.testing.expect(!second.next_state.in_jsx_tag);

    var has_attr = false;
    var has_string = false;
    for (second.spans) |span| {
        if (span.token == .keyword) has_attr = true;
        if (span.token == .string) has_string = true;
    }
    try std.testing.expect(has_attr);
    try std.testing.expect(has_string);
}

test "bash heredoc keeps state until exact terminator" {
    const allocator = std.testing.allocator;

    const first = try highlightLineWithState(allocator, .bash, "cat <<EOF", emptyState());
    defer allocator.free(first.spans);
    try std.testing.expect(first.next_state.in_heredoc);
    try std.testing.expect(hasTokenSpan(first.spans, .operator, 4, 6));
    try std.testing.expect(hasTokenSpan(first.spans, .string, 6, 9));

    const body = try highlightLineWithState(allocator, .bash, "value $USER", first.next_state);
    defer allocator.free(body.spans);
    try std.testing.expect(body.next_state.in_heredoc);
    try std.testing.expect(hasTokenSpan(body.spans, .string, 0, "value $USER".len));

    const end = try highlightLineWithState(allocator, .bash, "EOF", body.next_state);
    defer allocator.free(end.spans);
    try std.testing.expect(!end.next_state.in_heredoc);
    try std.testing.expect(hasTokenSpan(end.spans, .string, 0, 3));
}

test "bash heredoc <<- closes on tab-indented terminator only" {
    const allocator = std.testing.allocator;

    const first = try highlightLineWithState(allocator, .bash, "cat <<-EOF", emptyState());
    defer allocator.free(first.spans);
    try std.testing.expect(first.next_state.in_heredoc);
    try std.testing.expect(first.next_state.heredoc_strip_tabs);

    const not_end = try highlightLineWithState(allocator, .bash, " EOF", first.next_state);
    defer allocator.free(not_end.spans);
    try std.testing.expect(not_end.next_state.in_heredoc);

    const end = try highlightLineWithState(allocator, .bash, "\tEOF", not_end.next_state);
    defer allocator.free(end.spans);
    try std.testing.expect(!end.next_state.in_heredoc);
}

test "bash heredoc quoted delimiter tracks quoted mode and closes" {
    const allocator = std.testing.allocator;

    const first = try highlightLineWithState(allocator, .bash, "cat <<'TAG'", emptyState());
    defer allocator.free(first.spans);
    try std.testing.expect(first.next_state.in_heredoc);
    try std.testing.expect(first.next_state.heredoc_quoted_delim);
    try std.testing.expect(hasTokenSpan(first.spans, .string, 6, 11));

    const not_end = try highlightLineWithState(allocator, .bash, "TAGx", first.next_state);
    defer allocator.free(not_end.spans);
    try std.testing.expect(not_end.next_state.in_heredoc);

    const end = try highlightLineWithState(allocator, .bash, "TAG", not_end.next_state);
    defer allocator.free(end.spans);
    try std.testing.expect(!end.next_state.in_heredoc);
}

test "bash here-string does not enter heredoc mode" {
    const allocator = std.testing.allocator;

    const line = try highlightLineWithState(allocator, .bash, "echo <<< \"$x\"", emptyState());
    defer allocator.free(line.spans);
    try std.testing.expect(!line.next_state.in_heredoc);
    try std.testing.expect(hasTokenSpan(line.spans, .operator, 5, 8));
}
