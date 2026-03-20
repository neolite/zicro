const std = @import("std");

/// Minimal LSP configuration for core library
/// Application-specific config should wrap this
pub const LspConfig = struct {
    enable_lsp: bool,
    typescript_mode: TypescriptMode,
    typescript_command: ?[]const u8,
    typescript_args: []const []const u8,
    typescript_root_markers: []const []const u8,
    zig_enabled: ?bool,
    zig_command: ?[]const u8,
    zig_args: []const []const u8,
    zig_root_markers: []const []const u8,
    adapters: []const LspAdapter,
};

pub const TypescriptMode = enum {
    auto,
    tsls,
    tsgo,
};

pub const LspAdapter = struct {
    name: []const u8,
    language: []const u8,
    enabled: bool,
    priority: i32,
    command: ?[]const u8,
    args: []const []const u8,
    file_extensions: []const []const u8,
    root_markers: []const []const u8,
};

/// Create default LSP config
pub fn defaultConfig(allocator: std.mem.Allocator) LspConfig {
    _ = allocator;
    return .{
        .enable_lsp = true,
        .typescript_mode = .auto,
        .typescript_command = null,
        .typescript_args = &.{},
        .typescript_root_markers = &.{},
        .zig_enabled = null,
        .zig_command = null,
        .zig_args = &.{},
        .zig_root_markers = &.{},
        .adapters = &.{},
    };
}
