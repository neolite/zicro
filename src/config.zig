const std = @import("std");

pub const TsLspMode = enum {
    auto,
    tsls,
    tsgo,
};

pub const HoverShowMode = enum {
    status,
    tooltip,
};

pub const TypescriptLspConfig = struct {
    mode: TsLspMode,
    command: ?[]u8,
    args: std.array_list.Managed([]const u8),
    root_markers: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) TypescriptLspConfig {
        return .{
            .mode = .auto,
            .command = null,
            .args = std.array_list.Managed([]const u8).init(allocator),
            .root_markers = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TypescriptLspConfig, allocator: std.mem.Allocator) void {
        if (self.command) |command| allocator.free(command);
        freeStringList(allocator, &self.args);
        freeStringList(allocator, &self.root_markers);
    }
};

pub const BasicLspConfig = struct {
    enabled: ?bool,
    command: ?[]u8,
    args: std.array_list.Managed([]const u8),
    root_markers: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) BasicLspConfig {
        return .{
            .enabled = null,
            .command = null,
            .args = std.array_list.Managed([]const u8).init(allocator),
            .root_markers = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *BasicLspConfig, allocator: std.mem.Allocator) void {
        if (self.command) |command| allocator.free(command);
        freeStringList(allocator, &self.args);
        freeStringList(allocator, &self.root_markers);
    }
};

pub const LspAdapterConfig = struct {
    name: []u8,
    language: []u8,
    enabled: bool,
    priority: i32,
    command: ?[]u8,
    args: std.array_list.Managed([]const u8),
    file_extensions: std.array_list.Managed([]const u8),
    root_markers: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator, name: []const u8, language: []const u8) !LspAdapterConfig {
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);

        const language_owned = try allocator.dupe(u8, language);
        return .{
            .name = name_owned,
            .language = language_owned,
            .enabled = true,
            .priority = 0,
            .command = null,
            .args = std.array_list.Managed([]const u8).init(allocator),
            .file_extensions = std.array_list.Managed([]const u8).init(allocator),
            .root_markers = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *LspAdapterConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.language);
        if (self.command) |command| allocator.free(command);
        freeStringList(allocator, &self.args);
        freeStringList(allocator, &self.file_extensions);
        freeStringList(allocator, &self.root_markers);
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    tab_width: u8,
    autosave: bool,
    ui_perf_overlay: bool,
    enable_lsp: bool,
    lsp_change_debounce_ms: u16,
    lsp_did_save_debounce_ms: u16,
    lsp_completion_auto: bool,
    lsp_completion_debounce_ms: u16,
    lsp_completion_min_prefix_len: u8,
    lsp_completion_trigger_on_dot: bool,
    lsp_completion_trigger_on_letters: bool,
    lsp_hover_auto: bool,
    lsp_hover_debounce_ms: u16,
    lsp_hover_show_mode: HoverShowMode,
    lsp_hover_hide_on_type: bool,
    lsp_tooltip_max_width: u16,
    lsp_tooltip_max_rows: u8,
    lsp_typescript: TypescriptLspConfig,
    lsp_zig: BasicLspConfig,
    lsp_adapters: std.array_list.Managed(LspAdapterConfig),

    pub fn load(allocator: std.mem.Allocator, config_path_opt: ?[]const u8, file_path_opt: ?[]const u8) !Config {
        var config = Config{
            .allocator = allocator,
            .tab_width = 4,
            .autosave = false,
            .ui_perf_overlay = false,
            .enable_lsp = true,
            .lsp_change_debounce_ms = 32,
            .lsp_did_save_debounce_ms = 64,
            .lsp_completion_auto = true,
            .lsp_completion_debounce_ms = 48,
            .lsp_completion_min_prefix_len = 1,
            .lsp_completion_trigger_on_dot = true,
            .lsp_completion_trigger_on_letters = true,
            .lsp_hover_auto = true,
            .lsp_hover_debounce_ms = 140,
            .lsp_hover_show_mode = .tooltip,
            .lsp_hover_hide_on_type = true,
            .lsp_tooltip_max_width = 72,
            .lsp_tooltip_max_rows = 10,
            .lsp_typescript = TypescriptLspConfig.init(allocator),
            .lsp_zig = BasicLspConfig.init(allocator),
            .lsp_adapters = std.array_list.Managed(LspAdapterConfig).init(allocator),
        };
        errdefer config.deinit();

        try config.applyPathIfExists(".zicro.json");

        if (file_path_opt) |file_path| {
            const repo_config = try findNearestRepoConfigPath(allocator, file_path);
            if (repo_config) |path| {
                defer allocator.free(path);
                try config.applyPathIfExists(path);
            }
        }

        if (config_path_opt) |path| {
            try config.applyPathIfExists(path);
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        self.lsp_typescript.deinit(self.allocator);
        self.lsp_zig.deinit(self.allocator);
        self.clearAdapters();
        self.lsp_adapters.deinit();
    }

    fn applyPathIfExists(self: *Config, path: []const u8) !void {
        const file_bytes = readFileAllocAnyPath(self.allocator, path, 1024 * 1024) catch return;
        defer self.allocator.free(file_bytes);
        try self.applyJsonBytes(file_bytes);
    }

    fn applyJsonBytes(self: *Config, file_bytes: []const u8) !void {
        const RawTsLsp = struct {
            mode: ?[]const u8 = null,
            command: ?[]const u8 = null,
            args: ?[]const []const u8 = null,
            root_markers: ?[]const []const u8 = null,
        };
        const RawBasicLsp = struct {
            enabled: ?bool = null,
            command: ?[]const u8 = null,
            args: ?[]const []const u8 = null,
            root_markers: ?[]const []const u8 = null,
        };
        const RawLspAdapter = struct {
            name: ?[]const u8 = null,
            language: ?[]const u8 = null,
            enabled: ?bool = null,
            priority: ?i32 = null,
            command: ?[]const u8 = null,
            args: ?[]const []const u8 = null,
            file_extensions: ?[]const []const u8 = null,
            root_markers: ?[]const []const u8 = null,
        };
        const RawLspServers = struct {
            typescript: ?RawTsLsp = null,
            zig: ?RawBasicLsp = null,
        };
        const RawLspCompletion = struct {
            auto: ?bool = null,
            debounce_ms: ?u16 = null,
            min_prefix_len: ?u8 = null,
            trigger_on_dot: ?bool = null,
            trigger_on_letters: ?bool = null,
        };
        const RawLspHover = struct {
            auto: ?bool = null,
            debounce_ms: ?u16 = null,
            show_mode: ?[]const u8 = null,
            hide_on_type: ?bool = null,
        };
        const RawLspUi = struct {
            tooltip_max_width: ?u16 = null,
            tooltip_max_rows: ?u8 = null,
        };
        const RawLsp = struct {
            enabled: ?bool = null,
            change_debounce_ms: ?u16 = null,
            did_save_debounce_ms: ?u16 = null,
            completion: ?RawLspCompletion = null,
            hover: ?RawLspHover = null,
            ui: ?RawLspUi = null,
            typescript: ?RawTsLsp = null,
            zig: ?RawBasicLsp = null,
            adapters: ?[]const RawLspAdapter = null,
            servers: ?RawLspServers = null,
        };
        const RawConfig = struct {
            tab_width: ?u8 = null,
            autosave: ?bool = null,
            ui: ?struct {
                perf_overlay: ?bool = null,
            } = null,
            lsp: ?RawLsp = null,
        };

        const parsed = std.json.parseFromSlice(RawConfig, self.allocator, file_bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        if (parsed.value.tab_width) |value| {
            if (value > 0 and value <= 16) {
                self.tab_width = value;
            }
        }
        if (parsed.value.autosave) |value| {
            self.autosave = value;
        }
        if (parsed.value.ui) |ui| {
            if (ui.perf_overlay) |value| {
                self.ui_perf_overlay = value;
            }
        }
        if (parsed.value.lsp) |lsp| {
            if (lsp.enabled) |value| {
                self.enable_lsp = value;
            }
            if (lsp.change_debounce_ms) |value| {
                if (value >= 1 and value <= 1000) {
                    self.lsp_change_debounce_ms = value;
                }
            }
            if (lsp.did_save_debounce_ms) |value| {
                if (value >= 1 and value <= 1000) {
                    self.lsp_did_save_debounce_ms = value;
                }
            }
            if (lsp.completion) |completion| {
                if (completion.auto) |value| {
                    self.lsp_completion_auto = value;
                }
                if (completion.debounce_ms) |value| {
                    if (value >= 1 and value <= 1000) {
                        self.lsp_completion_debounce_ms = value;
                    }
                }
                if (completion.min_prefix_len) |value| {
                    if (value <= 64) {
                        self.lsp_completion_min_prefix_len = value;
                    }
                }
                if (completion.trigger_on_dot) |value| {
                    self.lsp_completion_trigger_on_dot = value;
                }
                if (completion.trigger_on_letters) |value| {
                    self.lsp_completion_trigger_on_letters = value;
                }
            }
            if (lsp.hover) |hover| {
                if (hover.auto) |value| {
                    self.lsp_hover_auto = value;
                }
                if (hover.debounce_ms) |value| {
                    if (value >= 1 and value <= 2000) {
                        self.lsp_hover_debounce_ms = value;
                    }
                }
                if (hover.show_mode) |value| {
                    if (parseHoverShowMode(value)) |mode| {
                        self.lsp_hover_show_mode = mode;
                    }
                }
                if (hover.hide_on_type) |value| {
                    self.lsp_hover_hide_on_type = value;
                }
            }
            if (lsp.ui) |lsp_ui| {
                if (lsp_ui.tooltip_max_width) |value| {
                    if (value >= 16 and value <= 240) {
                        self.lsp_tooltip_max_width = value;
                    }
                }
                if (lsp_ui.tooltip_max_rows) |value| {
                    if (value >= 1 and value <= 40) {
                        self.lsp_tooltip_max_rows = value;
                    }
                }
            }

            if (lsp.typescript) |ts| {
                try self.applyTypescriptLsp(ts);
            }
            if (lsp.zig) |zig_cfg| {
                try self.applyBasicLsp(&self.lsp_zig, zig_cfg);
            }
            if (lsp.adapters) |adapters| {
                try self.applyAdapters(adapters);
            }
            if (lsp.servers) |servers| {
                if (servers.typescript) |ts| {
                    try self.applyTypescriptLsp(ts);
                }
                if (servers.zig) |zig_cfg| {
                    try self.applyBasicLsp(&self.lsp_zig, zig_cfg);
                }
            }
        }
    }

    fn applyTypescriptLsp(self: *Config, ts: anytype) !void {
        if (ts.mode) |mode| {
            if (parseTsLspMode(mode)) |parsed| {
                self.lsp_typescript.mode = parsed;
            }
        }

        if (ts.command) |command| {
            if (self.lsp_typescript.command) |existing| self.allocator.free(existing);
            self.lsp_typescript.command = if (command.len > 0) try self.allocator.dupe(u8, command) else null;
        }

        if (ts.args) |args| {
            try replaceStringList(self.allocator, &self.lsp_typescript.args, args);
        }

        if (ts.root_markers) |root_markers| {
            try replaceStringList(self.allocator, &self.lsp_typescript.root_markers, root_markers);
        }
    }

    fn applyBasicLsp(self: *Config, target: *BasicLspConfig, value: anytype) !void {
        if (value.enabled) |enabled| {
            target.enabled = enabled;
        }

        if (value.command) |command| {
            if (target.command) |existing| self.allocator.free(existing);
            target.command = if (command.len > 0) try self.allocator.dupe(u8, command) else null;
        }

        if (value.args) |args| {
            try replaceStringList(self.allocator, &target.args, args);
        }

        if (value.root_markers) |root_markers| {
            try replaceStringList(self.allocator, &target.root_markers, root_markers);
        }
    }

    fn applyAdapters(self: *Config, adapters: anytype) !void {
        self.clearAdapters();

        for (adapters) |entry| {
            const name = entry.name orelse continue;
            const language = entry.language orelse continue;
            if (name.len == 0 or language.len == 0) continue;

            var adapter = try LspAdapterConfig.init(self.allocator, name, language);
            errdefer adapter.deinit(self.allocator);

            if (entry.enabled) |enabled| {
                adapter.enabled = enabled;
            }
            if (entry.priority) |priority| {
                if (priority >= -1000 and priority <= 1000) {
                    adapter.priority = priority;
                }
            }
            if (entry.command) |command| {
                if (command.len > 0) {
                    adapter.command = try self.allocator.dupe(u8, command);
                }
            }
            if (entry.args) |args| {
                try replaceStringList(self.allocator, &adapter.args, args);
            }
            if (entry.file_extensions) |file_extensions| {
                try replaceStringList(self.allocator, &adapter.file_extensions, file_extensions);
            }
            if (entry.root_markers) |root_markers| {
                try replaceStringList(self.allocator, &adapter.root_markers, root_markers);
            }

            try self.lsp_adapters.append(adapter);
        }
    }

    fn clearAdapters(self: *Config) void {
        for (self.lsp_adapters.items) |*adapter| {
            adapter.deinit(self.allocator);
        }
        self.lsp_adapters.clearRetainingCapacity();
    }
};

fn parseTsLspMode(raw: []const u8) ?TsLspMode {
    if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(raw, "tsls")) return .tsls;
    if (std.ascii.eqlIgnoreCase(raw, "tsgo")) return .tsgo;
    return null;
}

fn parseHoverShowMode(raw: []const u8) ?HoverShowMode {
    if (std.ascii.eqlIgnoreCase(raw, "status")) return .status;
    if (std.ascii.eqlIgnoreCase(raw, "tooltip")) return .tooltip;
    return null;
}

fn replaceStringList(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed([]const u8),
    values: []const []const u8,
) !void {
    clearStringList(allocator, list);
    var i: usize = 0;
    while (i < values.len) : (i += 1) {
        try list.append(try allocator.dupe(u8, values[i]));
    }
}

fn clearStringList(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8)) void {
    for (list.items) |entry| {
        allocator.free(entry);
    }
    list.clearRetainingCapacity();
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8)) void {
    clearStringList(allocator, list);
    list.deinit();
}

fn readFileAllocAnyPath(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

fn fileExistsAnyPath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        const file = std.fs.openFileAbsolute(path, .{}) catch return false;
        file.close();
        return true;
    }

    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn findNearestRepoConfigPath(allocator: std.mem.Allocator, file_path: []const u8) !?[]u8 {
    const abs_file = std.fs.cwd().realpathAlloc(allocator, file_path) catch return null;
    defer allocator.free(abs_file);

    const start_dir = std.fs.path.dirname(abs_file) orelse return null;
    var current = try allocator.dupe(u8, start_dir);
    defer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, ".zicro.json" });
        if (fileExistsAnyPath(candidate)) return candidate;
        allocator.free(candidate);

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

test "parses typescript lsp mode and command override" {
    const allocator = std.testing.allocator;
    var config = try Config.load(allocator, null, null);
    defer config.deinit();

    try config.applyJsonBytes(
        \\{
        \\  "lsp": {
        \\    "typescript": {
        \\      "mode": "tsgo",
        \\      "command": "npx",
        \\      "args": ["tsgo", "--lsp", "-stdio"],
        \\      "root_markers": ["package.json", ".git"]
        \\    }
        \\  }
        \\}
    );

    try std.testing.expectEqual(TsLspMode.tsgo, config.lsp_typescript.mode);
    try std.testing.expect(config.lsp_typescript.command != null);
    try std.testing.expectEqualStrings("npx", config.lsp_typescript.command.?);
    try std.testing.expectEqual(@as(usize, 3), config.lsp_typescript.args.items.len);
    try std.testing.expectEqualStrings("tsgo", config.lsp_typescript.args.items[0]);
    try std.testing.expectEqual(@as(usize, 2), config.lsp_typescript.root_markers.items.len);
}

test "lsp servers.typescript overrides lsp.typescript values" {
    const allocator = std.testing.allocator;
    var config = try Config.load(allocator, null, null);
    defer config.deinit();

    try config.applyJsonBytes(
        \\{
        \\  "lsp": {
        \\    "typescript": { "mode": "tsls" },
        \\    "servers": {
        \\      "typescript": { "mode": "auto" }
        \\    }
        \\  }
        \\}
    );

    try std.testing.expectEqual(TsLspMode.auto, config.lsp_typescript.mode);
}

test "parses ui perf overlay flag" {
    const allocator = std.testing.allocator;
    var config = try Config.load(allocator, null, null);
    defer config.deinit();

    try std.testing.expectEqual(false, config.ui_perf_overlay);

    try config.applyJsonBytes(
        \\{
        \\  "ui": {
        \\    "perf_overlay": true
        \\  }
        \\}
    );

    try std.testing.expectEqual(true, config.ui_perf_overlay);
}

test "parses realtime lsp completion and hover config" {
    const allocator = std.testing.allocator;
    var config = try Config.load(allocator, null, null);
    defer config.deinit();

    try config.applyJsonBytes(
        \\{
        \\  "lsp": {
        \\    "completion": {
        \\      "auto": false,
        \\      "debounce_ms": 64,
        \\      "min_prefix_len": 2,
        \\      "trigger_on_dot": true,
        \\      "trigger_on_letters": false
        \\    },
        \\    "hover": {
        \\      "auto": true,
        \\      "debounce_ms": 180,
        \\      "show_mode": "status",
        \\      "hide_on_type": false
        \\    },
        \\    "ui": {
        \\      "tooltip_max_width": 90,
        \\      "tooltip_max_rows": 12
        \\    }
        \\  }
        \\}
    );

    try std.testing.expectEqual(false, config.lsp_completion_auto);
    try std.testing.expectEqual(@as(u16, 64), config.lsp_completion_debounce_ms);
    try std.testing.expectEqual(@as(u8, 2), config.lsp_completion_min_prefix_len);
    try std.testing.expectEqual(true, config.lsp_completion_trigger_on_dot);
    try std.testing.expectEqual(false, config.lsp_completion_trigger_on_letters);
    try std.testing.expectEqual(true, config.lsp_hover_auto);
    try std.testing.expectEqual(@as(u16, 180), config.lsp_hover_debounce_ms);
    try std.testing.expectEqual(HoverShowMode.status, config.lsp_hover_show_mode);
    try std.testing.expectEqual(false, config.lsp_hover_hide_on_type);
    try std.testing.expectEqual(@as(u16, 90), config.lsp_tooltip_max_width);
    try std.testing.expectEqual(@as(u8, 12), config.lsp_tooltip_max_rows);
}

test "parses zig lsp config including lsp.servers.zig override" {
    const allocator = std.testing.allocator;
    var config = try Config.load(allocator, null, null);
    defer config.deinit();

    try config.applyJsonBytes(
        \\{
        \\  "lsp": {
        \\    "zig": {
        \\      "enabled": false,
        \\      "command": "zls-custom",
        \\      "args": ["--stdio"],
        \\      "root_markers": ["build.zig", ".git"]
        \\    },
        \\    "servers": {
        \\      "zig": {
        \\        "enabled": true,
        \\        "command": "zls",
        \\        "args": [],
        \\        "root_markers": [".git"]
        \\      }
        \\    }
        \\  }
        \\}
    );

    try std.testing.expect(config.lsp_zig.enabled != null);
    try std.testing.expectEqual(true, config.lsp_zig.enabled.?);
    try std.testing.expect(config.lsp_zig.command != null);
    try std.testing.expectEqualStrings("zls", config.lsp_zig.command.?);
    try std.testing.expectEqual(@as(usize, 0), config.lsp_zig.args.items.len);
    try std.testing.expectEqual(@as(usize, 1), config.lsp_zig.root_markers.items.len);
    try std.testing.expectEqualStrings(".git", config.lsp_zig.root_markers.items[0]);
}

test "parses lsp adapters list and replaces previous entries" {
    const allocator = std.testing.allocator;
    var config = try Config.load(allocator, null, null);
    defer config.deinit();

    try config.applyJsonBytes(
        \\{
        \\  "lsp": {
        \\    "adapters": [
        \\      {
        \\        "name": "typescript-tsgo",
        \\        "language": "typescript",
        \\        "enabled": true,
        \\        "priority": 220
        \\      },
        \\      {
        \\        "name": "typescript-custom",
        \\        "language": "typescript",
        \\        "command": "npx",
        \\        "args": ["tsgo", "--lsp", "-stdio"],
        \\        "file_extensions": [".ts", ".tsx"],
        \\        "root_markers": ["package.json", ".git"]
        \\      }
        \\    ]
        \\  }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 2), config.lsp_adapters.items.len);
    try std.testing.expectEqualStrings("typescript-tsgo", config.lsp_adapters.items[0].name);
    try std.testing.expectEqual(@as(i32, 220), config.lsp_adapters.items[0].priority);
    try std.testing.expectEqualStrings("typescript-custom", config.lsp_adapters.items[1].name);
    try std.testing.expect(config.lsp_adapters.items[1].command != null);
    try std.testing.expectEqualStrings("npx", config.lsp_adapters.items[1].command.?);
    try std.testing.expectEqual(@as(usize, 3), config.lsp_adapters.items[1].args.items.len);

    try config.applyJsonBytes(
        \\{
        \\  "lsp": {
        \\    "adapters": [
        \\      {
        \\        "name": "zig-zls",
        \\        "language": "zig",
        \\        "enabled": false
        \\      }
        \\    ]
        \\  }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), config.lsp_adapters.items.len);
    try std.testing.expectEqualStrings("zig-zls", config.lsp_adapters.items[0].name);
    try std.testing.expectEqual(false, config.lsp_adapters.items[0].enabled);
}
