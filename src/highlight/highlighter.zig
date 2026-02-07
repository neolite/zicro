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
    var spans = std.array_list.Managed(Span).init(allocator);

    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];

        if (isCommentStart(language, line, i)) {
            try spans.append(.{ .start = i, .end = line.len, .token = .comment });
            break;
        }

        if (ch == '"' or ch == '\'') {
            const quote = ch;
            const start = i;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    continue;
                }
                if (line[i] == quote) {
                    i += 1;
                    break;
                }
            }
            try spans.append(.{ .start = start, .end = i, .token = .string });
            continue;
        }

        if (std.ascii.isDigit(ch)) {
            const start = i;
            i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_' or line[i] == '.')) : (i += 1) {}
            try spans.append(.{ .start = start, .end = i, .token = .number });
            continue;
        }

        if (ch == '@' and language == .zig) {
            const start = i;
            i += 1;
            while (i < line.len and isIdent(line[i])) : (i += 1) {}
            try spans.append(.{ .start = start, .end = i, .token = .macro });
            continue;
        }

        if (isIdentStart(ch)) {
            const start = i;
            i += 1;
            while (i < line.len and isIdent(line[i])) : (i += 1) {}
            const ident = line[start..i];

            if (isKeyword(language, ident)) {
                try spans.append(.{ .start = start, .end = i, .token = .keyword });
            } else if (language == .bash and start == 0) {
                try spans.append(.{ .start = start, .end = i, .token = .command });
            }
            continue;
        }

        if (isOperator(ch)) {
            try spans.append(.{ .start = i, .end = i + 1, .token = .operator });
        }

        i += 1;
    }

    return spans.toOwnedSlice();
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

fn isCommentStart(language: Language, line: []const u8, index: usize) bool {
    if (language == .zig or language == .javascript or language == .typescript) {
        return index + 1 < line.len and line[index] == '/' and line[index + 1] == '/';
    }
    if (language == .bash) {
        return line[index] == '#';
    }
    return false;
}

fn isKeyword(language: Language, ident: []const u8) bool {
    return switch (language) {
        .zig => inSet(ident, &[_][]const u8{
            "const", "var", "fn", "pub", "struct", "enum", "union", "if", "else", "switch", "while", "for", "break", "continue", "return", "try", "catch", "defer", "errdefer", "comptime", "opaque", "usingnamespace",
        }),
        .javascript, .typescript => inSet(ident, &[_][]const u8{
            "const", "let", "var", "function", "class", "extends", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "try", "catch", "finally", "throw", "import", "export", "from", "as", "new", "this", "super", "async", "await", "interface", "type", "implements", "public", "private", "protected", "readonly", "enum", "namespace",
        }),
        .bash => inSet(ident, &[_][]const u8{
            "if", "then", "fi", "for", "in", "do", "done", "case", "esac", "while", "until", "function", "select", "time", "coproc",
        }),
        .json => inSet(ident, &[_][]const u8{ "true", "false", "null" }),
        .plain => false,
    };
}

fn inSet(item: []const u8, set: []const []const u8) bool {
    for (set) |entry| {
        if (std.mem.eql(u8, item, entry)) return true;
    }
    return false;
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
