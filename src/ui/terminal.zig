const std = @import("std");
const vaxis = @import("vaxis");

pub const KeyEvent = union(enum) {
    char: u8,
    text: []const u8,
    ctrl: u8,
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
    resize,
};

const Event = union(enum) {
    key_press: vaxis.Key,
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
