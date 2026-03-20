const std = @import("std");
const core = @import("core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Zicro GUI starting...", .{});

    // TODO: Initialize Mach Engine
    // TODO: Create window
    // TODO: Setup text renderer

    _ = allocator;

    std.log.info("Zicro GUI initialized (placeholder)", .{});
}
