const std = @import("std");

pub const TsLspMode = enum {
    auto,
    tsls,
    tsgo,
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

pub const Config = struct {
    allocator: std.mem.Allocator,
    tab_width: u8,
    autosave: bool,
    enable_lsp: bool,
    lsp_change_debounce_ms: u16,
    lsp_did_save_debounce_ms: u16,
    lsp_typescript: TypescriptLspConfig,

    pub fn load(allocator: std.mem.Allocator, config_path_opt: ?[]const u8, file_path_opt: ?[]const u8) !Config {
        var config = Config{
            .allocator = allocator,
            .tab_width = 4,
            .autosave = false,
            .enable_lsp = true,
            .lsp_change_debounce_ms = 32,
            .lsp_did_save_debounce_ms = 64,
            .lsp_typescript = TypescriptLspConfig.init(allocator),
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
        const RawLspServers = struct {
            typescript: ?RawTsLsp = null,
        };
        const RawLsp = struct {
            enabled: ?bool = null,
            change_debounce_ms: ?u16 = null,
            did_save_debounce_ms: ?u16 = null,
            typescript: ?RawTsLsp = null,
            servers: ?RawLspServers = null,
        };
        const RawConfig = struct {
            tab_width: ?u8 = null,
            autosave: ?bool = null,
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

            if (lsp.typescript) |ts| {
                try self.applyTypescriptLsp(ts);
            }
            if (lsp.servers) |servers| {
                if (servers.typescript) |ts| {
                    try self.applyTypescriptLsp(ts);
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
};

fn parseTsLspMode(raw: []const u8) ?TsLspMode {
    if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(raw, "tsls")) return .tsls;
    if (std.ascii.eqlIgnoreCase(raw, "tsgo")) return .tsgo;
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
