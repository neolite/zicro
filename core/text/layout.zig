const std = @import("std");

pub fn isUtf8ContinuationByte(ch: u8) bool {
    return (ch & 0b1100_0000) == 0b1000_0000;
}

pub fn utf8ExpectedLen(first: u8) usize {
    if ((first & 0b1110_0000) == 0b1100_0000) return 2;
    if ((first & 0b1111_0000) == 0b1110_0000) return 3;
    if ((first & 0b1111_1000) == 0b1111_0000) return 4;
    return 1;
}

pub fn utf8Step(bytes: []const u8, index: usize) usize {
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

pub fn normalizedTabWidth(tab_width_input: usize) usize {
    return if (tab_width_input == 0) 4 else tab_width_input;
}

pub fn tabStop(tab_width: usize, col: usize) usize {
    return tab_width - (col % tab_width);
}

pub fn displayWidth(bytes: []const u8, tab_width_input: usize) usize {
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

pub fn byteLimitForDisplayWidth(bytes: []const u8, max_width: usize, tab_width_input: usize) usize {
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

test "display width and clipping handle tabs and utf8" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("a\xd1\x84", 8));
    try std.testing.expectEqual(@as(usize, 8), displayWidth("a\t", 8));
    try std.testing.expectEqual(@as(usize, 3), byteLimitForDisplayWidth("a\xd1\x84b", 2, 8));
}
