const std = @import("std");

pub const ServerConfig = struct {
    name: []const u8,
    command: []const []const u8,
    file_extensions: []const []const u8,
    root_markers: []const []const u8,
};

const zig_cmd = [_][]const u8{ "zls" };
const zig_ext = [_][]const u8{ ".zig" };
const zig_roots = [_][]const u8{ "build.zig", "build.zig.zon", ".git" };

const ts_cmd = [_][]const u8{ "typescript-language-server", "--stdio" };
const ts_ext = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts" };
const ts_roots = [_][]const u8{ "package.json", "tsconfig.json", "jsconfig.json", ".git" };

const bash_cmd = [_][]const u8{ "bash-language-server", "start" };
const bash_ext = [_][]const u8{ ".sh", ".bash" };
const bash_roots = [_][]const u8{ ".git" };

const servers = [_]ServerConfig{
    .{
        .name = "zig",
        .command = &zig_cmd,
        .file_extensions = &zig_ext,
        .root_markers = &zig_roots,
    },
    .{
        .name = "typescript",
        .command = &ts_cmd,
        .file_extensions = &ts_ext,
        .root_markers = &ts_roots,
    },
    .{
        .name = "bash",
        .command = &bash_cmd,
        .file_extensions = &bash_ext,
        .root_markers = &bash_roots,
    },
};

pub fn defaults() []const ServerConfig {
    return &servers;
}

pub fn forPath(path: []const u8) ?ServerConfig {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return null;

    for (servers) |server| {
        for (server.file_extensions) |entry| {
            if (std.mem.eql(u8, ext, entry)) return server;
        }
    }

    return null;
}
