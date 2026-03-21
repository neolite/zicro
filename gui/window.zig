const std = @import("std");
const core = @import("core");

// SDL2 window with text rendering
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const WINDOW_WIDTH = 1200;
const WINDOW_HEIGHT = 800;

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
        "Zicro GUI Editor",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
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
    var scroll_offset: usize = 0;
    var cursor_blink_timer: u32 = 0;
    var cursor_visible = true;

    // Selection state
    var selection_active = false;
    var selection_start_line: usize = 0;
    var selection_start_col: usize = 0;

    // File state
    var file_path: ?[]const u8 = null;
    var file_modified = false;

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
                    const mods = c.SDL_GetModState();
                    const shift_pressed = (mods & c.KMOD_SHIFT) != 0;

                    // Start selection if shift is pressed and not already selecting
                    if (shift_pressed and !selection_active) {
                        selection_active = true;
                        selection_start_line = cursor_line;
                        selection_start_col = cursor_col;
                    }

                    switch (key) {
                        c.SDLK_ESCAPE, c.SDLK_q => running = false,
                        c.SDLK_UP => {
                            if (cursor_line > 0) {
                                cursor_line -= 1;
                                // Auto-scroll up if cursor goes above visible area
                                if (cursor_line < scroll_offset) {
                                    scroll_offset = cursor_line;
                                }
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                            // Clear selection if shift not pressed
                            if (!shift_pressed) {
                                selection_active = false;
                            }
                        },
                        c.SDLK_DOWN => {
                            if (cursor_line + 1 < line_count) {
                                cursor_line += 1;
                                // Auto-scroll down if cursor goes below visible area
                                const visible_lines: usize = 30;
                                if (cursor_line >= scroll_offset + visible_lines) {
                                    scroll_offset = cursor_line - visible_lines + 1;
                                }
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                            // Clear selection if shift not pressed
                            if (!shift_pressed) {
                                selection_active = false;
                            }
                        },
                        c.SDLK_LEFT => {
                            if (cursor_col > 0) {
                                cursor_col -= 1;
                                cursor_blink_timer = 0;
                                cursor_visible = true;
                            }
                            // Clear selection if shift not pressed
                            if (!shift_pressed) {
                                selection_active = false;
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
                            // Clear selection if shift not pressed
                            if (!shift_pressed) {
                                selection_active = false;
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
                        c.SDLK_c => {
                            if ((mods & c.KMOD_GUI) != 0 or (mods & c.KMOD_CTRL) != 0) {
                                // Copy: Cmd+C or Ctrl+C
                                if (selection_active) {
                                    const sel_min_line = @min(selection_start_line, cursor_line);
                                    const sel_max_line = @max(selection_start_line, cursor_line);

                                    var selected_text = std.array_list.Managed(u8).init(allocator);
                                    defer selected_text.deinit();

                                    var line_idx = sel_min_line;
                                    while (line_idx <= sel_max_line) : (line_idx += 1) {
                                        const line = buffer.lineOwned(allocator, line_idx) catch continue;
                                        defer allocator.free(line);

                                        if (sel_min_line == sel_max_line) {
                                            // Single line
                                            const min_col = @min(selection_start_col, cursor_col);
                                            const max_col = @max(selection_start_col, cursor_col);
                                            const text = line[min_col..@min(max_col, line.len)];
                                            selected_text.appendSlice(text) catch {};
                                        } else if (line_idx == sel_min_line) {
                                            // First line
                                            const start_col = if (selection_start_line < cursor_line) selection_start_col else cursor_col;
                                            selected_text.appendSlice(line[start_col..]) catch {};
                                            selected_text.append('\n') catch {};
                                        } else if (line_idx == sel_max_line) {
                                            // Last line
                                            const end_col = if (selection_start_line < cursor_line) cursor_col else selection_start_col;
                                            selected_text.appendSlice(line[0..@min(end_col, line.len)]) catch {};
                                        } else {
                                            // Middle line
                                            selected_text.appendSlice(line) catch {};
                                            selected_text.append('\n') catch {};
                                        }
                                    }

                                    const text_z = allocator.dupeZ(u8, selected_text.items) catch continue;
                                    defer allocator.free(text_z);
                                    _ = c.SDL_SetClipboardText(text_z.ptr);
                                }
                            }
                        },
                        c.SDLK_v => {
                            if ((mods & c.KMOD_GUI) != 0 or (mods & c.KMOD_CTRL) != 0) {
                                // Paste: Cmd+V or Ctrl+V
                                const clipboard_text = c.SDL_GetClipboardText();
                                if (clipboard_text != null) {
                                    defer c.SDL_free(clipboard_text);
                                    const text = std.mem.sliceTo(clipboard_text, 0);

                                    // Delete selection if active
                                    if (selection_active) {
                                        const sel_min_line = @min(selection_start_line, cursor_line);
                                        const sel_max_line = @max(selection_start_line, cursor_line);
                                        const sel_start = buffer.offsetFromLineCol(sel_min_line, if (selection_start_line < cursor_line) selection_start_col else cursor_col);
                                        const sel_end = buffer.offsetFromLineCol(sel_max_line, if (selection_start_line < cursor_line) cursor_col else selection_start_col);
                                        buffer.delete(sel_start, sel_end - sel_start) catch {};
                                        cursor_line = sel_min_line;
                                        cursor_col = if (selection_start_line < cursor_line) selection_start_col else cursor_col;
                                        selection_active = false;
                                    }

                                    const line_start = buffer.offsetFromLineCol(cursor_line, 0);
                                    const insert_offset = line_start + cursor_col;
                                    buffer.insert(insert_offset, text) catch {};

                                    // Update cursor position
                                    var newlines: usize = 0;
                                    var last_newline_pos: usize = 0;
                                    for (text, 0..) |ch, idx| {
                                        if (ch == '\n') {
                                            newlines += 1;
                                            last_newline_pos = idx;
                                        }
                                    }

                                    if (newlines > 0) {
                                        cursor_line += newlines;
                                        cursor_col = text.len - last_newline_pos - 1;
                                    } else {
                                        cursor_col += text.len;
                                    }

                                    cursor_blink_timer = 0;
                                    cursor_visible = true;
                                }
                            }
                        },
                        c.SDLK_x => {
                            if ((mods & c.KMOD_GUI) != 0 or (mods & c.KMOD_CTRL) != 0) {
                                // Cut: Cmd+X or Ctrl+X (copy + delete)
                                if (selection_active) {
                                    // First copy
                                    const sel_min_line = @min(selection_start_line, cursor_line);
                                    const sel_max_line = @max(selection_start_line, cursor_line);

                                    var selected_text = std.array_list.Managed(u8).init(allocator);
                                    defer selected_text.deinit();

                                    var line_idx = sel_min_line;
                                    while (line_idx <= sel_max_line) : (line_idx += 1) {
                                        const line = buffer.lineOwned(allocator, line_idx) catch continue;
                                        defer allocator.free(line);

                                        if (sel_min_line == sel_max_line) {
                                            const min_col = @min(selection_start_col, cursor_col);
                                            const max_col = @max(selection_start_col, cursor_col);
                                            const text = line[min_col..@min(max_col, line.len)];
                                            selected_text.appendSlice(text) catch {};
                                        } else if (line_idx == sel_min_line) {
                                            const start_col = if (selection_start_line < cursor_line) selection_start_col else cursor_col;
                                            selected_text.appendSlice(line[start_col..]) catch {};
                                            selected_text.append('\n') catch {};
                                        } else if (line_idx == sel_max_line) {
                                            const end_col = if (selection_start_line < cursor_line) cursor_col else selection_start_col;
                                            selected_text.appendSlice(line[0..@min(end_col, line.len)]) catch {};
                                        } else {
                                            selected_text.appendSlice(line) catch {};
                                            selected_text.append('\n') catch {};
                                        }
                                    }

                                    const text_z = allocator.dupeZ(u8, selected_text.items) catch continue;
                                    defer allocator.free(text_z);
                                    _ = c.SDL_SetClipboardText(text_z.ptr);

                                    // Then delete
                                    const sel_start = buffer.offsetFromLineCol(sel_min_line, if (selection_start_line < cursor_line) selection_start_col else cursor_col);
                                    const sel_end = buffer.offsetFromLineCol(sel_max_line, if (selection_start_line < cursor_line) cursor_col else selection_start_col);
                                    buffer.delete(sel_start, sel_end - sel_start) catch {};

                                    cursor_line = sel_min_line;
                                    cursor_col = if (selection_start_line < cursor_line) selection_start_col else cursor_col;
                                    selection_active = false;
                                    cursor_blink_timer = 0;
                                    cursor_visible = true;
                                }
                            }
                        },
                        c.SDLK_s => {
                            if ((mods & c.KMOD_GUI) != 0 or (mods & c.KMOD_CTRL) != 0) {
                                // Save: Cmd+S or Ctrl+S
                                if (file_path) |path| {
                                    // Save to existing file
                                    const file = std.fs.cwd().createFile(path, .{}) catch {
                                        std.log.err("Failed to save file: {s}", .{path});
                                        continue;
                                    };
                                    defer file.close();

                                    const total_lines = buffer.lineCount();
                                    var line_idx: usize = 0;
                                    while (line_idx < total_lines) : (line_idx += 1) {
                                        const line = buffer.lineOwned(allocator, line_idx) catch continue;
                                        defer allocator.free(line);
                                        file.writeAll(line) catch {};
                                        if (line_idx + 1 < total_lines) {
                                            file.writeAll("\n") catch {};
                                        }
                                    }

                                    file_modified = false;
                                    std.log.info("Saved: {s}", .{path});
                                }
                            }
                        },
                        c.SDLK_z => {
                            if ((mods & c.KMOD_GUI) != 0 or (mods & c.KMOD_CTRL) != 0) {
                                if ((mods & c.KMOD_SHIFT) != 0) {
                                    // Redo: Cmd+Shift+Z or Ctrl+Shift+Z
                                    buffer.redo() catch {};
                                } else {
                                    // Undo: Cmd+Z or Ctrl+Z
                                    buffer.undo() catch {};
                                }
                                // Reset cursor to safe position
                                const total_lines = buffer.lineCount();
                                if (cursor_line >= total_lines) {
                                    cursor_line = if (total_lines > 0) total_lines - 1 else 0;
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
                        file_modified = true;
                    }
                },
                c.SDL_MOUSEWHEEL => {
                    const total_lines = buffer.lineCount();
                    const visible_lines: usize = 30;

                    if (event.wheel.y > 0) {
                        // Scroll up
                        if (scroll_offset > 0) {
                            scroll_offset -= 1;
                        }
                    } else if (event.wheel.y < 0) {
                        // Scroll down
                        if (scroll_offset + visible_lines < total_lines) {
                            scroll_offset += 1;
                        }
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
        const visible_lines = @min(line_count - scroll_offset, 30);

        var line_y: i32 = 70;
        var i: usize = 0;
        while (i < visible_lines) : (i += 1) {
            const line_index = scroll_offset + i;
            const line = buffer.lineOwned(allocator, line_index) catch continue;
            defer allocator.free(line);

            if (line.len == 0) {
                line_y += 20;
                continue;
            }

            // Calculate selection range for this line
            var sel_start_col: ?usize = null;
            var sel_end_col: ?usize = null;

            if (selection_active) {
                const sel_min_line = @min(selection_start_line, cursor_line);
                const sel_max_line = @max(selection_start_line, cursor_line);

                if (line_index >= sel_min_line and line_index <= sel_max_line) {
                    if (sel_min_line == sel_max_line) {
                        // Single line selection
                        const min_col = @min(selection_start_col, cursor_col);
                        const max_col = @max(selection_start_col, cursor_col);
                        sel_start_col = min_col;
                        sel_end_col = max_col;
                    } else if (line_index == sel_min_line) {
                        // First line of multi-line selection
                        if (selection_start_line < cursor_line) {
                            sel_start_col = selection_start_col;
                            sel_end_col = line.len;
                        } else {
                            sel_start_col = cursor_col;
                            sel_end_col = line.len;
                        }
                    } else if (line_index == sel_max_line) {
                        // Last line of multi-line selection
                        sel_start_col = 0;
                        if (selection_start_line < cursor_line) {
                            sel_end_col = cursor_col;
                        } else {
                            sel_end_col = selection_start_col;
                        }
                    } else {
                        // Middle line - fully selected
                        sel_start_col = 0;
                        sel_end_col = line.len;
                    }
                }
            }

            // Render selection highlight if applicable
            if (sel_start_col != null and sel_end_col != null) {
                const start_x = 80 + @as(i32, @intCast(sel_start_col.? * 8));
                const width = @as(i32, @intCast((sel_end_col.? - sel_start_col.?) * 8));
                _ = c.SDL_SetRenderDrawColor(renderer, 60, 100, 180, 255);
                const sel_rect = c.SDL_Rect{
                    .x = start_x,
                    .y = line_y,
                    .w = width,
                    .h = 18
                };
                _ = c.SDL_RenderFillRect(renderer, &sel_rect);
            }

            // Render line number
            var line_num_buf: [16]u8 = undefined;
            const line_num_str = std.fmt.bufPrintZ(&line_num_buf, "{d:4}", .{line_index + 1}) catch continue;

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

        // Draw status bar
        const status_bar_y = 760;
        _ = c.SDL_SetRenderDrawColor(renderer, 50, 50, 50, 255);
        const status_bar_rect = c.SDL_Rect{
            .x = 0,
            .y = status_bar_y,
            .w = WINDOW_WIDTH,
            .h = 40
        };
        _ = c.SDL_RenderFillRect(renderer, &status_bar_rect);

        // Render status text
        var status_buf: [256]u8 = undefined;
        const modified_indicator = if (file_modified) "*" else "";
        const file_name = if (file_path) |path| std.fs.path.basename(path) else "[No Name]";
        const status_text = std.fmt.bufPrintZ(&status_buf, "{s}{s} | Line {d}, Col {d} | {d} lines | {s}", .{
            file_name,
            modified_indicator,
            cursor_line + 1,
            cursor_col + 1,
            buffer.lineCount(),
            if (selection_active) "SELECTING" else "NORMAL"
        }) catch "Status";

        const status_color = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
        const status_surface = c.TTF_RenderText_Solid(font, status_text.ptr, status_color) orelse {
            c.SDL_RenderPresent(renderer);
            c.SDL_Delay(16);
            continue;
        };
        defer c.SDL_FreeSurface(status_surface);

        const status_texture = c.SDL_CreateTextureFromSurface(renderer, status_surface) orelse {
            c.SDL_RenderPresent(renderer);
            c.SDL_Delay(16);
            continue;
        };
        defer c.SDL_DestroyTexture(status_texture);

        const status_text_rect = c.SDL_Rect{
            .x = 10,
            .y = status_bar_y + 10,
            .w = status_surface.*.w,
            .h = status_surface.*.h
        };
        _ = c.SDL_RenderCopy(renderer, status_texture, null, &status_text_rect);

        // Render cursor
        cursor_blink_timer += 16;
        if (cursor_blink_timer >= 500) {
            cursor_blink_timer = 0;
            cursor_visible = !cursor_visible;
        }

        if (cursor_visible and cursor_line >= scroll_offset and cursor_line < scroll_offset + 30) {
            const cursor_screen_line = cursor_line - scroll_offset;
            const cursor_x = 80 + @as(i32, @intCast(cursor_col * 8));
            const cursor_y = 70 + @as(i32, @intCast(cursor_screen_line * 20));

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
