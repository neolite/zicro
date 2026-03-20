const std = @import("std");

// Text utilities
pub const layout = @import("text/layout.zig");

// Editor buffer and state
pub const Buffer = @import("editor/buffer.zig").Buffer;
pub const CursorPos = @import("editor/buffer.zig").CursorPos;

// Syntax highlighting
pub const highlighter = @import("highlight/highlighter.zig");
pub const Language = highlighter.Language;
pub const TokenType = highlighter.TokenType;
pub const Span = highlighter.Span;
pub const LineState = highlighter.LineState;
pub const LineHighlight = highlighter.LineHighlight;

// LSP client and config
pub const LspClient = @import("lsp/client.zig");
pub const lsp_presets = @import("lsp/presets.zig");
pub const lsp_config = @import("lsp/config.zig");
pub const LspConfig = lsp_config.LspConfig;
pub const TypescriptMode = lsp_config.TypescriptMode;
pub const LspAdapter = lsp_config.LspAdapter;

// State management
pub const editor_state = @import("state/editor_state.zig");
pub const lsp_state = @import("state/lsp_state.zig");
pub const EditorState = editor_state.EditorState;
pub const SelectionMode = editor_state.SelectionMode;
pub const ByteRange = editor_state.ByteRange;
pub const SearchMatch = editor_state.SearchMatch;
pub const BlockSelection = editor_state.BlockSelection;
pub const LspState = lsp_state.LspState;
pub const LspChangePosition = lsp_state.LspChangePosition;
pub const PendingLspChange = lsp_state.PendingLspChange;

// Editor motion utilities
pub const editor_motion = @import("app/editor_motion.zig");

// LSP synchronization utilities
pub const lsp_sync = @import("app/lsp_sync.zig");

test {
    std.testing.refAllDecls(@This());
}
