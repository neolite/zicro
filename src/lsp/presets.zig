const std = @import("std");

pub const AdapterPreset = struct {
    name: []const u8,
    language_id: []const u8,
    command: []const u8,
    args: []const []const u8,
    priority: i32,
    file_extensions: []const []const u8,
    root_markers: []const []const u8,
};

const zig_args = [_][]const u8{};
const zig_ext = [_][]const u8{".zig"};
const zig_roots = [_][]const u8{ "build.zig", "build.zig.zon", ".git" };

const tsgo_args = [_][]const u8{ "--lsp", "-stdio" };
const npx_tsgo_args = [_][]const u8{ "tsgo", "--lsp", "-stdio" };
const tsls_args = [_][]const u8{"--stdio"};
const ts_ext = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts" };
const ts_roots = [_][]const u8{ "package.json", "tsconfig.json", "jsconfig.json", ".git" };

const bash_args = [_][]const u8{"start"};
const bash_ext = [_][]const u8{ ".sh", ".bash" };
const bash_roots = [_][]const u8{".git"};

const adapters = [_]AdapterPreset{
    .{
        .name = "zig-zls",
        .language_id = "zig",
        .command = "zls",
        .args = &zig_args,
        .priority = 100,
        .file_extensions = &zig_ext,
        .root_markers = &zig_roots,
    },
    .{
        .name = "typescript-tsgo",
        .language_id = "typescript",
        .command = "tsgo",
        .args = &tsgo_args,
        .priority = 120,
        .file_extensions = &ts_ext,
        .root_markers = &ts_roots,
    },
    .{
        .name = "typescript-npx-tsgo",
        .language_id = "typescript",
        .command = "npx",
        .args = &npx_tsgo_args,
        .priority = 110,
        .file_extensions = &ts_ext,
        .root_markers = &ts_roots,
    },
    .{
        .name = "typescript-tsls",
        .language_id = "typescript",
        .command = "typescript-language-server",
        .args = &tsls_args,
        .priority = 100,
        .file_extensions = &ts_ext,
        .root_markers = &ts_roots,
    },
    .{
        .name = "bash-language-server",
        .language_id = "bash",
        .command = "bash-language-server",
        .args = &bash_args,
        .priority = 100,
        .file_extensions = &bash_ext,
        .root_markers = &bash_roots,
    },
};

pub fn defaults() []const AdapterPreset {
    return &adapters;
}

pub fn matchesPath(candidate: AdapterPreset, path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;

    for (candidate.file_extensions) |entry| {
        if (std.mem.eql(u8, ext, entry)) return true;
    }
    return false;
}

pub fn languageForPath(path: []const u8) ?[]const u8 {
    for (adapters) |candidate| {
        if (matchesPath(candidate, path)) return candidate.language_id;
    }
    return null;
}

pub fn extensionsForLanguage(language_id: []const u8) ?[]const []const u8 {
    for (adapters) |candidate| {
        if (std.mem.eql(u8, candidate.language_id, language_id)) {
            return candidate.file_extensions;
        }
    }
    return null;
}

pub fn rootMarkersForLanguage(language_id: []const u8) ?[]const []const u8 {
    for (adapters) |candidate| {
        if (std.mem.eql(u8, candidate.language_id, language_id)) {
            return candidate.root_markers;
        }
    }
    return null;
}
