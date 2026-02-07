const std = @import("std");

pub const PaletteAction = enum {
    save,
    quit,
    undo,
    redo,
    restart_lsp,
};

pub const PaletteEntry = struct {
    label: []const u8,
    action: PaletteAction,
};

pub const palette_entries = [_]PaletteEntry{
    .{ .label = "File: Save", .action = .save },
    .{ .label = "File: Quit", .action = .quit },
    .{ .label = "Edit: Undo", .action = .undo },
    .{ .label = "Edit: Redo", .action = .redo },
    .{ .label = "LSP: Restart", .action = .restart_lsp },
};

pub const PromptMode = enum {
    goto_line,
    regex_search,
};

pub const PromptState = struct {
    active: bool,
    mode: PromptMode,
    query: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) PromptState {
        return .{
            .active = false,
            .mode = .goto_line,
            .query = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *PromptState) void {
        self.query.deinit();
    }

    pub fn open(self: *PromptState, mode: PromptMode) void {
        self.mode = mode;
        self.active = true;
        self.query.clearRetainingCapacity();
    }

    pub fn close(self: *PromptState) void {
        self.active = false;
        self.query.clearRetainingCapacity();
    }
};

pub const PaletteState = struct {
    active: bool,
    query: std.array_list.Managed(u8),
    selected: usize,

    pub fn init(allocator: std.mem.Allocator) PaletteState {
        return .{
            .active = false,
            .query = std.array_list.Managed(u8).init(allocator),
            .selected = 0,
        };
    }

    pub fn deinit(self: *PaletteState) void {
        self.query.deinit();
    }

    pub fn clear(self: *PaletteState) void {
        self.query.clearRetainingCapacity();
        self.selected = 0;
    }
};

pub const UiState = struct {
    render_arena: std.heap.ArenaAllocator,
    status: std.array_list.Managed(u8),
    running: bool,
    needs_render: bool,
    palette: PaletteState,
    prompt: PromptState,

    pub fn init(allocator: std.mem.Allocator) UiState {
        return .{
            .render_arena = std.heap.ArenaAllocator.init(allocator),
            .status = std.array_list.Managed(u8).init(allocator),
            .running = true,
            .needs_render = true,
            .palette = PaletteState.init(allocator),
            .prompt = PromptState.init(allocator),
        };
    }

    pub fn deinit(self: *UiState) void {
        self.prompt.deinit();
        self.palette.deinit();
        self.status.deinit();
        self.render_arena.deinit();
    }
};
