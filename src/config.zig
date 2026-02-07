const std = @import("std");

pub const Config = struct {
    tab_width: u8,
    autosave: bool,
    enable_lsp: bool,
    lsp_change_debounce_ms: u16,
    lsp_did_save_debounce_ms: u16,

    pub fn load(allocator: std.mem.Allocator, config_path_opt: ?[]const u8) !Config {
        var config = Config{
            .tab_width = 4,
            .autosave = false,
            .enable_lsp = true,
            .lsp_change_debounce_ms = 32,
            .lsp_did_save_debounce_ms = 64,
        };

        var path = config_path_opt;
        if (path == null) {
            if (std.fs.cwd().access(".zicro.json", .{})) |_| {
                path = ".zicro.json";
            } else |_| {}
        }

        if (path == null) return config;

        const file_bytes = std.fs.cwd().readFileAlloc(allocator, path.?, 1024 * 1024) catch return config;
        defer allocator.free(file_bytes);

        const RawLsp = struct {
            enabled: ?bool = null,
            change_debounce_ms: ?u16 = null,
            did_save_debounce_ms: ?u16 = null,
        };
        const RawConfig = struct {
            tab_width: ?u8 = null,
            autosave: ?bool = null,
            lsp: ?RawLsp = null,
        };

        const parsed = std.json.parseFromSlice(RawConfig, allocator, file_bytes, .{
            .ignore_unknown_fields = true,
        }) catch return config;
        defer parsed.deinit();

        if (parsed.value.tab_width) |value| {
            if (value > 0 and value <= 16) {
                config.tab_width = value;
            }
        }
        if (parsed.value.autosave) |value| {
            config.autosave = value;
        }
        if (parsed.value.lsp) |lsp| {
            if (lsp.enabled) |value| {
                config.enable_lsp = value;
            }
            if (lsp.change_debounce_ms) |value| {
                if (value >= 1 and value <= 1000) {
                    config.lsp_change_debounce_ms = value;
                }
            }
            if (lsp.did_save_debounce_ms) |value| {
                if (value >= 1 and value <= 1000) {
                    config.lsp_did_save_debounce_ms = value;
                }
            }
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        _ = self;
    }
};
