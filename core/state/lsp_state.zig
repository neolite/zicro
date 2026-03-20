const std = @import("std");
const LspClient = @import("../lsp/client.zig").Client;

pub const LspChangePosition = struct {
    line: usize,
    character: usize,
};

pub const PendingLspChange = struct {
    start: LspChangePosition,
    end: LspChangePosition,
    text: []u8,
};

pub const LspState = struct {
    client: LspClient,
    pending_lsp_sync: bool,
    next_lsp_flush_ns: i128,
    pending_lsp_changes: std.array_list.Managed(PendingLspChange),
    force_full_lsp_sync: bool,
    change_delay_ns: i128,

    pub fn init(allocator: std.mem.Allocator, change_delay_ns: i128) LspState {
        return .{
            .client = LspClient.init(allocator),
            .pending_lsp_sync = false,
            .next_lsp_flush_ns = 0,
            .pending_lsp_changes = std.array_list.Managed(PendingLspChange).init(allocator),
            .force_full_lsp_sync = false,
            .change_delay_ns = change_delay_ns,
        };
    }
};
