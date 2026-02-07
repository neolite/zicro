const std = @import("std");

pub const PaletteAction = enum {
    save,
    quit,
    undo,
    redo,
    restart_lsp,
    lsp_completion,
    lsp_hover,
    lsp_definition,
    lsp_references,
    lsp_jump_back,
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
    .{ .label = "LSP: Completion", .action = .lsp_completion },
    .{ .label = "LSP: Hover", .action = .lsp_hover },
    .{ .label = "LSP: Go to Definition", .action = .lsp_definition },
    .{ .label = "LSP: References", .action = .lsp_references },
    .{ .label = "LSP: Jump Back", .action = .lsp_jump_back },
};

pub const LspPanelMode = enum {
    none,
    completion,
    references,
    project_search,
};

pub const JumpLocation = struct {
    path: []u8,
    offset: usize,
};

pub const PromptMode = enum {
    goto_line,
    regex_search,
    project_search,
};

pub const ProjectSearchResult = struct {
    path: []u8,
    line: usize,
    column: usize,
    text: []u8,
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
    pub const Mode = enum {
        commands,
        files,
    };

    active: bool,
    mode: Mode,
    query: std.array_list.Managed(u8),
    selected: usize,

    pub fn init(allocator: std.mem.Allocator) PaletteState {
        return .{
            .active = false,
            .mode = .commands,
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
    pub const perf_sample_capacity: usize = 256;

    render_arena: std.heap.ArenaAllocator,
    status: std.array_list.Managed(u8),
    running: bool,
    needs_render: bool,
    lsp_spinner_frame: usize,
    perf_overlay_enabled: bool,
    debug_panel_enabled: bool,
    perf_last_frame_ns: i128,
    perf_frame_samples: [perf_sample_capacity]u16,
    perf_sample_count: usize,
    perf_sample_index: usize,
    perf_fps_ema_tenths: u16,
    perf_fps_avg: u16,
    perf_ft_last_tenths_ms: u16,
    perf_ft_avg_tenths_ms: u16,
    perf_ft_p95_tenths_ms: u16,
    perf_ft_max_tenths_ms: u16,
    file_open_last_ms: u32,
    file_index_last_ms: u32,
    file_index_count: usize,
    lsp_panel_mode: LspPanelMode,
    lsp_panel_selected: usize,
    lsp_completion_pending: bool,
    lsp_hover_pending: bool,
    lsp_definition_pending: bool,
    lsp_references_pending: bool,
    lsp_completion_rev_seen: u64,
    lsp_hover_rev_seen: u64,
    lsp_definition_rev_seen: u64,
    lsp_references_rev_seen: u64,
    lsp_auto_completion_due_ns: i128,
    lsp_auto_hover_due_ns: i128,
    lsp_completion_request_auto: bool,
    lsp_hover_request_auto: bool,
    lsp_completion_request_cursor: usize,
    lsp_hover_request_cursor: usize,
    lsp_hover_tooltip_active: bool,
    lsp_hover_tooltip_text: std.array_list.Managed(u8),
    project_search_results: std.array_list.Managed(ProjectSearchResult),
    project_search_query: std.array_list.Managed(u8),
    jump_stack: std.array_list.Managed(JumpLocation),
    palette: PaletteState,
    prompt: PromptState,

    pub fn init(allocator: std.mem.Allocator, perf_overlay_enabled: bool) UiState {
        return .{
            .render_arena = std.heap.ArenaAllocator.init(allocator),
            .status = std.array_list.Managed(u8).init(allocator),
            .running = true,
            .needs_render = true,
            .lsp_spinner_frame = 0,
            .perf_overlay_enabled = perf_overlay_enabled,
            .debug_panel_enabled = false,
            .perf_last_frame_ns = 0,
            .perf_frame_samples = [_]u16{0} ** perf_sample_capacity,
            .perf_sample_count = 0,
            .perf_sample_index = 0,
            .perf_fps_ema_tenths = 0,
            .perf_fps_avg = 0,
            .perf_ft_last_tenths_ms = 0,
            .perf_ft_avg_tenths_ms = 0,
            .perf_ft_p95_tenths_ms = 0,
            .perf_ft_max_tenths_ms = 0,
            .file_open_last_ms = 0,
            .file_index_last_ms = 0,
            .file_index_count = 0,
            .lsp_panel_mode = .none,
            .lsp_panel_selected = 0,
            .lsp_completion_pending = false,
            .lsp_hover_pending = false,
            .lsp_definition_pending = false,
            .lsp_references_pending = false,
            .lsp_completion_rev_seen = 0,
            .lsp_hover_rev_seen = 0,
            .lsp_definition_rev_seen = 0,
            .lsp_references_rev_seen = 0,
            .lsp_auto_completion_due_ns = 0,
            .lsp_auto_hover_due_ns = 0,
            .lsp_completion_request_auto = false,
            .lsp_hover_request_auto = false,
            .lsp_completion_request_cursor = 0,
            .lsp_hover_request_cursor = 0,
            .lsp_hover_tooltip_active = false,
            .lsp_hover_tooltip_text = std.array_list.Managed(u8).init(allocator),
            .project_search_results = std.array_list.Managed(ProjectSearchResult).init(allocator),
            .project_search_query = std.array_list.Managed(u8).init(allocator),
            .jump_stack = std.array_list.Managed(JumpLocation).init(allocator),
            .palette = PaletteState.init(allocator),
            .prompt = PromptState.init(allocator),
        };
    }

    pub fn deinit(self: *UiState) void {
        self.prompt.deinit();
        self.palette.deinit();
        for (self.project_search_results.items) |item| {
            self.status.allocator.free(item.path);
            self.status.allocator.free(item.text);
        }
        self.project_search_results.deinit();
        self.project_search_query.deinit();
        self.lsp_hover_tooltip_text.deinit();
        self.jump_stack.deinit();
        self.status.deinit();
        self.render_arena.deinit();
    }
};
