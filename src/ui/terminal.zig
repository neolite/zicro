const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

pub const KeyEvent = union(enum) {
    char: u8,
    text: []const u8,
    ctrl: u8,
    ctrl_shift: u8,
    cmd: u8,
    cmd_shift: u8,
    enter,
    tab,
    escape,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    shift_up,
    shift_down,
    shift_left,
    shift_right,
    alt_up,
    alt_down,
    alt_left,
    alt_right,
    home,
    end,
    shift_home,
    shift_end,
    page_up,
    page_down,
    shift_page_up,
    shift_page_down,
    word_left,
    word_right,
    alt_click: struct {
        row: usize,
        col: usize,
    },
    resize,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
};

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    tty_buffer: []u8,
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    loop: *vaxis.Loop(Event),

    pub fn init(allocator: std.mem.Allocator) !Terminal {
        if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
            return error.RequiresTty;
        }

        var terminal = Terminal{
            .allocator = allocator,
            .width = 120,
            .height = 34,
            .tty_buffer = try allocator.alloc(u8, 4096),
            .tty = undefined,
            .vx = undefined,
            .loop = undefined,
        };
        errdefer allocator.free(terminal.tty_buffer);

        terminal.tty = try allocator.create(vaxis.Tty);
        errdefer allocator.destroy(terminal.tty);
        terminal.tty.* = try vaxis.Tty.init(terminal.tty_buffer);

        terminal.vx = try allocator.create(vaxis.Vaxis);
        errdefer allocator.destroy(terminal.vx);
        terminal.vx.* = try vaxis.init(allocator, .{
            .kitty_keyboard_flags = .{ .report_events = true },
        });

        terminal.loop = try allocator.create(vaxis.Loop(Event));
        errdefer allocator.destroy(terminal.loop);
        terminal.loop.* = .{
            .tty = terminal.tty,
            .vaxis = terminal.vx,
        };

        try terminal.loop.init();
        try terminal.loop.start();
        errdefer terminal.loop.stop();

        const tty_writer = terminal.tty.writer();
        try terminal.vx.enterAltScreen(tty_writer);
        try terminal.vx.setMouseMode(tty_writer, true);
        terminal.vx.queryTerminal(tty_writer, 150 * std.time.ns_per_ms) catch {};

        const ws = vaxis.Tty.getWinsize(terminal.tty.fd) catch vaxis.Winsize{
            .rows = 34,
            .cols = 120,
            .x_pixel = 0,
            .y_pixel = 0,
        };
        try terminal.vx.resize(allocator, tty_writer, ws);
        terminal.width = ws.cols;
        terminal.height = ws.rows;

        return terminal;
    }

    pub fn deinit(self: *Terminal) void {
        self.loop.stop();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        vaxis.Tty.resetSignalHandler();
        self.allocator.destroy(self.loop);
        self.allocator.destroy(self.vx);
        self.allocator.destroy(self.tty);
        self.allocator.free(self.tty_buffer);
    }

    pub fn readKey(self: *Terminal) !?KeyEvent {
        while (self.loop.tryEvent()) |event| {
            switch (event) {
                .winsize => |ws| {
                    self.width = @max(@as(usize, ws.cols), 1);
                    self.height = @max(@as(usize, ws.rows), 1);
                    self.vx.resize(self.allocator, self.tty.writer(), ws) catch {};
                    return .resize;
                },
                .key_press => |key| {
                    if (mapKey(key)) |mapped| return mapped;
                },
                .mouse => |mouse| {
                    if (mouse.type == .press and mouse.button == .left and mouse.mods.alt) {
                        const row: usize = if (mouse.row < 0) 0 else @intCast(mouse.row);
                        const col: usize = if (mouse.col < 0) 0 else @intCast(mouse.col);
                        return .{ .alt_click = .{ .row = row, .col = col } };
                    }
                },
            }
        }
        return null;
    }

    pub fn writeAll(self: *Terminal, bytes: []const u8) !void {
        try self.tty.writer().writeAll(bytes);
    }

    pub fn flush(self: *Terminal) !void {
        try self.tty.writer().flush();
    }
};

fn mapKey(key: vaxis.Key) ?KeyEvent {
    if (key.matches(vaxis.Key.enter, .{})) return .enter;
    if (key.matches(vaxis.Key.tab, .{})) return .tab;
    if (key.matches(vaxis.Key.escape, .{})) return .escape;
    if (key.matches(vaxis.Key.backspace, .{})) return .backspace;
    if (key.matches(vaxis.Key.delete, .{})) return .delete;
    if (key.matches(vaxis.Key.up, .{})) return .up;
    if (key.matches(vaxis.Key.down, .{})) return .down;
    if (key.matches(vaxis.Key.left, .{})) return .left;
    if (key.matches(vaxis.Key.right, .{})) return .right;
    if (key.matches(vaxis.Key.up, .{ .shift = true })) return .shift_up;
    if (key.matches(vaxis.Key.down, .{ .shift = true })) return .shift_down;
    if (key.matches(vaxis.Key.left, .{ .shift = true })) return .shift_left;
    if (key.matches(vaxis.Key.right, .{ .shift = true })) return .shift_right;
    if (key.matches(vaxis.Key.up, .{ .alt = true })) return .alt_up;
    if (key.matches(vaxis.Key.down, .{ .alt = true })) return .alt_down;
    if (key.matches(vaxis.Key.left, .{ .alt = true })) return .alt_left;
    if (key.matches(vaxis.Key.right, .{ .alt = true })) return .alt_right;
    if (key.matches(vaxis.Key.home, .{})) return .home;
    if (key.matches(vaxis.Key.end, .{})) return .end;
    if (key.matches(vaxis.Key.home, .{ .shift = true })) return .shift_home;
    if (key.matches(vaxis.Key.end, .{ .shift = true })) return .shift_end;
    if (key.matches(vaxis.Key.page_up, .{})) return .page_up;
    if (key.matches(vaxis.Key.page_down, .{})) return .page_down;
    if (key.matches(vaxis.Key.page_up, .{ .shift = true })) return .shift_page_up;
    if (key.matches(vaxis.Key.page_down, .{ .shift = true })) return .shift_page_down;
    if (key.matches(vaxis.Key.left, .{ .ctrl = true })) return .word_left;
    if (key.matches(vaxis.Key.right, .{ .ctrl = true })) return .word_right;

    if (key.text) |text| {
        if (mapLegacyEscSequence(text)) |mapped| return mapped;
    }

    if (key.mods.ctrl and key.mods.shift and !key.mods.alt and !key.mods.super and !key.mods.meta) {
        if (key.codepoint < 128) {
            const raw: u8 = @intCast(key.codepoint);
            const normalized = if (raw >= 1 and raw <= 26)
                @as(u8, raw + 'a' - 1)
            else if (std.ascii.isAlphabetic(raw))
                std.ascii.toLower(raw)
            else
                raw;
            return KeyEvent{ .ctrl_shift = normalized };
        }
    }

    const is_macos = comptime builtin.target.os.tag == .macos;
    if (is_macos and !key.mods.ctrl and !key.mods.alt and (key.mods.super or key.mods.meta)) {
        if (key.mods.shift) {
            if (key.codepoint < 128) {
                const raw: u8 = @intCast(key.codepoint);
                const normalized = if (raw >= 1 and raw <= 26)
                    @as(u8, raw + 'a' - 1)
                else if (std.ascii.isAlphabetic(raw))
                    std.ascii.toLower(raw)
                else
                    raw;
                return KeyEvent{ .cmd_shift = normalized };
            }
        } else {
            if (key.codepoint < 128) {
                const raw: u8 = @intCast(key.codepoint);
                const normalized = if (std.ascii.isAlphabetic(raw))
                    std.ascii.toLower(raw)
                else
                    raw;
                return KeyEvent{ .cmd = normalized };
            }
        }
    }

    if (key.mods.ctrl and !key.mods.alt and !key.mods.super and !key.mods.meta) {
        if (key.codepoint < 128) {
            const raw: u8 = @intCast(key.codepoint);
            const normalized = if (raw >= 1 and raw <= 26)
                @as(u8, raw + 'a' - 1)
            else if (std.ascii.isAlphabetic(raw))
                std.ascii.toLower(raw)
            else
                raw;
            return KeyEvent{ .ctrl = normalized };
        }
    }

    if (!key.mods.ctrl and !key.mods.alt and !key.mods.super and !key.mods.meta) {
        // Some terminals emit Ctrl+letter as raw ASCII control codes (1..26)
        // without reporting the Ctrl modifier. Normalize those to .ctrl events.
        if (key.codepoint >= 1 and key.codepoint <= 26) {
            const ctrl_char: u8 = @intCast(key.codepoint + ('a' - 1));
            return KeyEvent{ .ctrl = ctrl_char };
        }
        if (key.codepoint == 31) {
            return KeyEvent{ .ctrl = '/' };
        }

        if (key.text) |text| {
            if (text.len > 0) {
                if (isLikelyControlText(text)) return null;
                return KeyEvent{ .text = text };
            }
        }

        if (key.codepoint < 128) {
            const ch: u8 = @intCast(key.codepoint);
            if (std.ascii.isPrint(ch) or ch == ' ') {
                return KeyEvent{ .char = ch };
            }
        }
    }

    return null;
}

fn mapLegacyEscSequence(text: []const u8) ?KeyEvent {
    if (std.mem.eql(u8, text, "\x1b[A")) return .up;
    if (std.mem.eql(u8, text, "\x1b[B")) return .down;
    if (std.mem.eql(u8, text, "\x1b[C")) return .right;
    if (std.mem.eql(u8, text, "\x1b[D")) return .left;

    if (std.mem.eql(u8, text, "\x1b[1;3A")) return .alt_up;
    if (std.mem.eql(u8, text, "\x1b[1;3B")) return .alt_down;
    if (std.mem.eql(u8, text, "\x1b[1;3C")) return .alt_right;
    if (std.mem.eql(u8, text, "\x1b[1;3D")) return .alt_left;

    if (std.mem.eql(u8, text, "\x1b[1;2A")) return .shift_up;
    if (std.mem.eql(u8, text, "\x1b[1;2B")) return .shift_down;
    if (std.mem.eql(u8, text, "\x1b[1;2C")) return .shift_right;
    if (std.mem.eql(u8, text, "\x1b[1;2D")) return .shift_left;

    return null;
}

fn isLikelyControlText(text: []const u8) bool {
    if (text.len == 0) return false;

    var has_esc = false;
    var has_ctl = false;
    for (text) |ch| {
        if (ch == 0x1b) has_esc = true;
        if (ch < 0x20 and ch != '\t' and ch != '\n' and ch != '\r') has_ctl = true;
    }
    if (has_esc or has_ctl) return true;

    if (text.len >= 3 and text[0] == '[' and isCsiTail(text[text.len - 1])) {
        var all_csi = true;
        for (text[1 .. text.len - 1]) |ch| {
            if (!(std.ascii.isDigit(ch) or ch == ';' or ch == ':' or ch == '?' or ch == '>')) {
                all_csi = false;
                break;
            }
        }
        if (all_csi) return true;
    }

    return false;
}

fn isCsiTail(ch: u8) bool {
    return switch (ch) {
        'A', 'B', 'C', 'D', 'H', 'F', 'P', 'Q', 'R', 'S', '~', 'u' => true,
        else => false,
    };
}
