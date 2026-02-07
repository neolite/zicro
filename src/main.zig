const std = @import("std");
const App = @import("app.zig").App;
const Config = @import("config.zig").Config;

const CliArgs = struct {
    file_path: ?[]const u8,
    config_path: ?[]const u8,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa_state.deinit();
        if (status == .leak) {
            std.log.err("memory leaks detected", .{});
        }
    }
    const allocator = gpa_state.allocator();

    const args = try parseArgs(allocator);
    defer {
        if (args.file_path) |p| allocator.free(p);
        if (args.config_path) |p| allocator.free(p);
    }

    var config = try Config.load(allocator, args.config_path);
    defer config.deinit();

    var app = App.init(allocator, &config, args.file_path) catch |err| switch (err) {
        error.RequiresTty => {
            try std.fs.File.stderr().writeAll(
                "zicro requires an interactive TTY (run it directly in a terminal).\n",
            );
            std.process.exit(1);
        },
        else => return err,
    };
    defer app.deinit();

    try app.run();
}

fn parseArgs(allocator: std.mem.Allocator) !CliArgs {
    var parsed = CliArgs{ .file_path = null, .config_path = null };

    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();

    _ = iter.next();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            const next = iter.next() orelse return error.MissingConfigPath;
            parsed.config_path = try allocator.dupe(u8, next);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownFlag;
        }
        if (parsed.file_path == null) {
            parsed.file_path = try allocator.dupe(u8, arg);
        }
    }

    return parsed;
}

test {
    std.testing.refAllDecls(@This());
}
