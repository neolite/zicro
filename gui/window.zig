const std = @import("std");
const core = @import("core");

// SDL2 window with text rendering
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
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

    // Initialize SDL_ttf
    if (c.TTF_Init() < 0) {
        std.log.err("TTF_Init failed: {s}", .{c.TTF_GetError()});
        return error.TTFInitFailed;
    }
    defer c.TTF_Quit();

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
        \\// Zicro GUI - Real Window Demo with Text Rendering!
        \\const std = @import("std");
        \\const core = @import("core");
        \\
        \\pub fn main() !void {
        \\    var buffer = try core.Buffer.initEmpty(allocator);
        \\    defer buffer.deinit();
        \\
        \\    try buffer.insert(0, "Hello from Zicro GUI!");
        \\    std.debug.print("Buffer: {s}\n", .{buffer.bytes()});
        \\}
        \\
        \\// This GUI window demonstrates:
        \\// - SDL2 window creation (1200x800)
        \\// - SDL2_ttf text rendering
        \\// - Monaco monospace font
        \\// - Line numbers + code display
        \\// - Integration with zicro-core buffer
        \\// - 60 FPS rendering loop
        \\//
        \\// Next features to add:
        \\// - Keyboard input handling
        \\// - Cursor rendering and movement
        \\// - Text editing (insert/delete)
        \\// - Scrolling (mouse wheel + arrow keys)
        \\// - Syntax highlighting colors
        \\// - LSP integration UI
    ;
    try buffer.insert(0, demo_text);

    // Load monospace font
    const font = c.TTF_OpenFont("/System/Library/Fonts/Monaco.ttf", 14) orelse {
        std.log.err("TTF_OpenFont failed: {s}", .{c.TTF_GetError()});
        return error.FontLoadFailed;
    };
    defer c.TTF_CloseFont(font);

    std.log.info("Zicro GUI window opened!", .{});
    std.log.info("Buffer has {d} lines", .{buffer.lineCount()});

    // Editor state
    var cursor_line: usize = 0;
    var cursor_col: usize = 0;
    var cursor_blink_timer: u32 = 0;
    var cursor_visible = true;

    // Main loop
    var running = true;
    var event: c.SDL_Event = undefined;

    while (running) {
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    const key = event.key.keysym.sym;
                    const line_count = buffer.lineCount();

                    switch (key) {
                        c.SDLK_ESCAPE, c.SDLK_q => running = false,
                        c.SDLK_UP => {
                            if (cursor_line > 0) {
                                cursor_line -= 1;
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                        },
                        c.SDLK_DOWN => {
                            if (cursor_line + 1 < line_count) {
                                cursor_line += 1;
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                        },
                        c.SDLK_LEFT => {
                            if (cursor_col > 0) {
                                cursor_col -= 1;
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                        },
                        c.SDLK_RIGHT => {
                            const line = buffer.lineOwned(allocator, cursor_line) catch &[_]u8{};
                            defer if (line.len > 0) allocator.free(line);
                            if (cursor_col < line.len) {
                                cursor_col += 1;
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                        },
                        c.SDLK_HOME => {
                            cursor_col = 0;
                            cursor_blink_timer = 0;
                            cursor_visible = true;
                        },
                        c.SDLK_END => {
                            const line = buffer.lineOwned(allocator, cursor_line) catch &[_]u8{};
                            defer if (line.len > 0) allocator.free(line);
                            cursor_col = line.len;
                            cursor_blink_timer = 0;
                            cursor_visible = true;
                        },
                        c.SDLK_BACKSPACE => {
                            if (cursor_col > 0) {
                                const line = buffer.lineOwned(allocator, cursor_line) catch continue;
                                defer allocator.free(line);

                                const line_start = buffer.offsetFromLineCol(cursor_line, 0);
                                const delete_offset = line_start + cursor_col - 1;

                                buffer.delete(delete_offset, 1) catch {};
                                cursor_col -= 1;
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            } else if (cursor_line > 0) {
                                // Join with previous line
                                const prev_line = buffer.lineOwned(allocator, cursor_line - 1) catch continue;
                                defer allocator.free(prev_line);

                                const line_start = buffer.offsetFromLineCol(cursor_line, 0);
                                buffer.delete(line_start - 1, 1) catch {};

                                cursor_line -= 1;
                                cursor_col = prev_line.len;
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                        },
                        c.SDLK_DELETE => {
                            const line = buffer.lineOwned(allocator, cursor_line) catch continue;
                            defer allocator.free(line);

                            if (cursor_col < line.len) {
                                const line_start = buffer.offsetFromLineCol(cursor_line, 0);
                                const delete_offset = line_start + cursor_col;
                                buffer.delete(delete_offset, 1) catch {};
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                        },
                        c.SDLK_RETURN => {
                            const line_start = buffer.offsetFromLineCol(cursor_line, 0);
                            const insert_offset = line_start + cursor_col;
                            buffer.insert(insert_offset, "\n") catch {};
                            cursor_line += 1;
                            cursor_col = 0;
                            cursor_blink_timer = 0;
                            cursor_visible = true;
                        },
                        c.SDLK_z => {
                            const mods = c.SDL_GetModState();
                            if ((mods & c.KMOD_GUI) != 0 or (mods & c.KMOD_CTRL) != 0) {
                                if ((mods & c.KMOD_SHIFT) != 0) {
                                    // Redo: Cmd+Shift+Z or Ctrl+Shift+Z
                                    buffer.redo() catch {};
                                } else {
                                    // Undo: Cmd+Z or Ctrl+Z
                                    buffer.undo() catch {};
                                }
                                // Reset cursor to safe position
                                const line_count = buffer.lineCount();
                                if (cursor_line >= line_count) {
                                    cursor_line = if (line_count > 0) line_count - 1 else 0;
                                }
                                const line = buffer.lineOwned(allocator, cursor_line) catch &[_]u8{};
                                defer if (line.len > 0) allocator.free(line);
                                if (cursor_col > line.len) {
                                    cursor_col = line.len;
                                }
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                        },
                        else => {},
                    }
                },
                c.SDL_TEXTINPUT => {
                    const text = std.mem.sliceTo(&event.text.text, 0);
                    if (text.len > 0) {
                        const line_start = buffer.offsetFromLineCol(cursor_line, 0);
                        const insert_offset = line_start + cursor_col;
                        buffer.insert(insert_offset, text) catch {};
                        cursor_col += text.len;
                        cursor_blink_timer = 0;
                        cursor_visible = true;
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

        // Render text from buffer
        const line_count = buffer.lineCount();
        const visible_lines = @min(line_count, 30);

        var line_y: i32 = 70;
        var i: usize = 0;
        while (i < visible_lines) : (i += 1) {
            const line = buffer.lineOwned(allocator, i) catch continue;
            defer allocator.free(line);

            if (line.len == 0) {
                line_y += 20;
                continue;
            }

            // Render line number
            var line_num_buf: [16]u8 = undefined;
            const line_num_str = std.fmt.bufPrintZ(&line_num_buf, "{d:4}", .{i + 1}) catch continue;

            const line_num_color = c.SDL_Color{ .r = 100, .g = 100, .b = 100, .a = 255 };
            const line_num_surface = c.TTF_RenderText_Solid(font, line_num_str.ptr, line_num_color) orelse continue;
            defer c.SDL_FreeSurface(line_num_surface);

            const line_num_texture = c.SDL_CreateTextureFromSurface(renderer, line_num_surface) orelse continue;
            defer c.SDL_DestroyTexture(line_num_texture);

            const line_num_rect = c.SDL_Rect{
                .x = 30,
                .y = line_y,
                .w = line_num_surface.*.w,
                .h = line_num_surface.*.h
            };
            _ = c.SDL_RenderCopy(renderer, line_num_texture, null, &line_num_rect);

            // Render line content
            const line_z = allocator.dupeZ(u8, line) catch continue;
            defer allocator.free(line_z);

            const text_color = c.SDL_Color{ .r = 220, .g = 220, .b = 220, .a = 255 };
            const text_surface = c.TTF_RenderText_Solid(font, line_z.ptr, text_color) orelse continue;
            defer c.SDL_FreeSurface(text_surface);

            const text_texture = c.SDL_CreateTextureFromSurface(renderer, text_surface) orelse continue;
            defer c.SDL_DestroyTexture(text_texture);

            const text_rect = c.SDL_Rect{
                .x = 80,
                .y = line_y,
                .w = @min(text_surface.*.w, 1100),
                .h = text_surface.*.h
            };
            _ = c.SDL_RenderCopy(renderer, text_texture, null, &text_rect);

            line_y += 20;
        }

        // Render cursor
        cursor_blink_timer += 16;
        if (cursor_blink_timer >= 500) {
            cursor_blink_timer = 0;
            cursor_visible = !cursor_visible;
        }

        if (cursor_visible and cursor_line < visible_lines) {
            const cursor_x = 80 + @as(i32, @intCast(cursor_col * 8));
            const cursor_y = 70 + @as(i32, @intCast(cursor_line * 20));

            _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
            const cursor_rect = c.SDL_Rect{
                .x = cursor_x,
                .y = cursor_y,
                .w = 2,
                .h = 18
            };
            _ = c.SDL_RenderFillRect(renderer, &cursor_rect);
        }

        // Draw status bar
        _ = c.SDL_SetRenderDrawColor(renderer, 50, 50, 50, 255);
        const status_rect = c.SDL_Rect{ .x = 0, .y = 760, .w = 1200, .h = 40 };
        _ = c.SDL_RenderFillRect(renderer, &status_rect);

        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(16); // ~60 FPS
    }

    std.log.info("Zicro GUI closed", .{});
}
