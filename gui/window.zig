const std = @import("std");
const core = @import("core");

// Simple SDL2-like window using Zig's C interop
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize SDL
    if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
        std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    // Create window
    const window = c.SDL_CreateWindow(
        "Zicro GUI - Proof of Concept",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        1200,
        800,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        std.log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    // Create renderer
    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        std.log.err("SDL_CreateRenderer failed: {s}", .{c.SDL_GetError()});
        return error.RendererCreationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    // Initialize core buffer
    var buffer = try core.Buffer.initEmpty(allocator);
    defer buffer.deinit();

    const demo_text =
        \\// Zicro GUI - Real Window Demo
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    std.debug.print("Hello from Zicro GUI!\n", .{});
        \\}
    ;
    try buffer.insert(0, demo_text);

    std.log.info("Zicro GUI window opened!", .{});
    std.log.info("Buffer has {d} lines", .{buffer.lineCount()});

    // Main loop
    var running = true;
    var event: c.SDL_Event = undefined;

    while (running) {
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE or event.key.keysym.sym == c.SDLK_q) {
                        running = false;
                    }
                },
                else => {},
            }
        }

        // Clear screen with dark background
        _ = c.SDL_SetRenderDrawColor(renderer, 30, 30, 30, 255);
        _ = c.SDL_RenderClear(renderer);

        // Draw title bar
        _ = c.SDL_SetRenderDrawColor(renderer, 60, 120, 200, 255);
        const title_rect = c.SDL_Rect{ .x = 0, .y = 0, .w = 1200, .h = 40 };
        _ = c.SDL_RenderFillRect(renderer, &title_rect);

        // Draw content area
        _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 40, 255);
        const content_rect = c.SDL_Rect{ .x = 20, .y = 60, .w = 1160, .h = 720 };
        _ = c.SDL_RenderFillRect(renderer, &content_rect);

        // Draw status bar
        _ = c.SDL_SetRenderDrawColor(renderer, 50, 50, 50, 255);
        const status_rect = c.SDL_Rect{ .x = 0, .y = 760, .w = 1200, .h = 40 };
        _ = c.SDL_RenderFillRect(renderer, &status_rect);

        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(16); // ~60 FPS
    }

    std.log.info("Zicro GUI closed", .{});
}
