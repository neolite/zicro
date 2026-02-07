const Buffer = @import("../editor/buffer.zig").Buffer;
const highlighter = @import("../highlight/highlighter.zig");

pub const SelectionMode = enum {
    linear,
    block,
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const SearchMatch = struct {
    start: usize,
    end: usize,
};

pub const BlockSelection = struct {
    start_line: usize,
    end_line: usize,
    start_col: usize,
    end_col: usize,
};

pub const EditorState = struct {
    buffer: Buffer,
    file_path: ?[]u8,
    cursor: usize,
    selection_anchor: ?usize,
    selection_mode: SelectionMode,
    search_match: ?SearchMatch,
    scroll_y: usize,
    dirty: bool,
    confirm_quit: bool,
    preferred_visual_col: ?usize,
    language: highlighter.Language,
};
