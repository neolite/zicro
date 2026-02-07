const std = @import("std");
const presets = @import("presets.zig");
const Config = @import("../config.zig").Config;

const max_lsp_open_file_bytes: usize = 32 * 1024 * 1024;
const diagnostics_request_timeout_ns: i128 = 1500 * std.time.ns_per_ms;
const max_payloads_per_poll: usize = 24;
const fallback_root_markers = [_][]const u8{".git"};

pub const DiagnosticsSnapshot = struct {
    count: usize,
    first_line: ?usize,
    first_message: []const u8,
    first_symbol: []const u8,
    lines: []const usize,
    pending_requests: usize,
    pending_ms: u32,
    last_latency_ms: u32,
};

pub const LspPosition = struct {
    line: usize,
    character: usize,
};

pub const CompletionItem = struct {
    label: []const u8,
    insert_text: []const u8,
    has_text_edit: bool,
    text_edit_start: LspPosition,
    text_edit_end: LspPosition,
};

pub const CompletionSnapshot = struct {
    pending: bool,
    rev: u64,
    items: []const CompletionItem,
};

pub const HoverSnapshot = struct {
    pending: bool,
    rev: u64,
    text: []const u8,
};

pub const LocationItem = struct {
    uri: []const u8,
    line: usize,
    character: usize,
    same_document: bool,
};

pub const LocationSnapshot = struct {
    pending: bool,
    rev: u64,
    items: []const LocationItem,
};

pub const CapabilitiesSnapshot = struct {
    completion: bool,
    hover: bool,
    definition: bool,
    references: bool,
};

const ChangeMode = enum {
    full,
    incremental,
};

const StartKind = enum {
    command,
    tsgo_via_node,
};

const StartCandidate = struct {
    name: []const u8,
    language_id: []const u8,
    kind: StartKind,
    command: []const u8,
    args: []const []const u8,
    root_markers: []const []const u8,
    priority: i32,
};

pub const IncrementalChange = struct {
    start_line: usize,
    start_character: usize,
    end_line: usize,
    end_character: usize,
    text: []const u8,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    child: ?std.process.Child,
    document_uri: ?[]u8,
    root_uri: ?[]u8,
    next_id: u64,
    version: i64,
    server_name: []const u8,
    pending_requests: usize,
    pending_since_ns: i128,
    last_latency_ms: u32,
    enabled: bool,
    trace_enabled: bool,
    session_ready: bool,
    initialize_request_id: ?u64,
    diagnostics_request_id: ?u64,
    diagnostics_request_started_ns: i128,
    completion_request_id: ?u64,
    completion_request_started_ns: i128,
    hover_request_id: ?u64,
    hover_request_started_ns: i128,
    definition_request_id: ?u64,
    definition_request_started_ns: i128,
    references_request_id: ?u64,
    references_request_started_ns: i128,
    change_mode: ChangeMode,
    supports_pull_diagnostics: bool,
    supports_completion: bool,
    supports_hover: bool,
    supports_definition: bool,
    supports_references: bool,
    did_save_pulse_interval_ns: i128,
    next_did_save_pulse_ns: i128,
    did_save_pulse_queued: bool,
    bootstrap_saved: bool,
    pending_open_text: ?[]u8,
    recv_buffer: std.array_list.Managed(u8),
    diag_count: usize,
    diag_first_line: ?usize,
    diag_first_message: std.array_list.Managed(u8),
    diag_first_symbol: std.array_list.Managed(u8),
    diag_lines: std.array_list.Managed(usize),
    completion_rev: u64,
    completion_items: std.array_list.Managed(CompletionItem),
    hover_rev: u64,
    hover_text: std.array_list.Managed(u8),
    definition_rev: u64,
    definition_items: std.array_list.Managed(LocationItem),
    references_rev: u64,
    references_items: std.array_list.Managed(LocationItem),

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .child = null,
            .document_uri = null,
            .root_uri = null,
            .next_id = 1,
            .version = 1,
            .server_name = "off",
            .pending_requests = 0,
            .pending_since_ns = 0,
            .last_latency_ms = 0,
            .enabled = false,
            .trace_enabled = std.process.hasEnvVarConstant("ZICRO_LSP_TRACE"),
            .session_ready = false,
            .initialize_request_id = null,
            .diagnostics_request_id = null,
            .diagnostics_request_started_ns = 0,
            .completion_request_id = null,
            .completion_request_started_ns = 0,
            .hover_request_id = null,
            .hover_request_started_ns = 0,
            .definition_request_id = null,
            .definition_request_started_ns = 0,
            .references_request_id = null,
            .references_request_started_ns = 0,
            .change_mode = .full,
            .supports_pull_diagnostics = true,
            .supports_completion = false,
            .supports_hover = false,
            .supports_definition = false,
            .supports_references = false,
            .did_save_pulse_interval_ns = 64 * std.time.ns_per_ms,
            .next_did_save_pulse_ns = 0,
            .did_save_pulse_queued = false,
            .bootstrap_saved = false,
            .pending_open_text = null,
            .recv_buffer = std.array_list.Managed(u8).init(allocator),
            .diag_count = 0,
            .diag_first_line = null,
            .diag_first_message = std.array_list.Managed(u8).init(allocator),
            .diag_first_symbol = std.array_list.Managed(u8).init(allocator),
            .diag_lines = std.array_list.Managed(usize).init(allocator),
            .completion_rev = 0,
            .completion_items = std.array_list.Managed(CompletionItem).init(allocator),
            .hover_rev = 0,
            .hover_text = std.array_list.Managed(u8).init(allocator),
            .definition_rev = 0,
            .definition_items = std.array_list.Managed(LocationItem).init(allocator),
            .references_rev = 0,
            .references_items = std.array_list.Managed(LocationItem).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.stop();
        self.recv_buffer.deinit();
        self.diag_first_message.deinit();
        self.diag_first_symbol.deinit();
        self.diag_lines.deinit();
        self.clearCompletionItems();
        self.completion_items.deinit();
        self.hover_text.deinit();
        self.clearLocationItems(&self.definition_items);
        self.definition_items.deinit();
        self.clearLocationItems(&self.references_items);
        self.references_items.deinit();
        if (self.pending_open_text) |text| self.allocator.free(text);
        if (self.document_uri) |uri| self.allocator.free(uri);
        if (self.root_uri) |uri| self.allocator.free(uri);
    }

    pub fn stop(self: *Client) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        self.child = null;
        self.enabled = false;
        self.pending_requests = 0;
        self.pending_since_ns = 0;
        self.last_latency_ms = 0;
        self.session_ready = false;
        self.initialize_request_id = null;
        self.diagnostics_request_id = null;
        self.diagnostics_request_started_ns = 0;
        self.completion_request_id = null;
        self.completion_request_started_ns = 0;
        self.hover_request_id = null;
        self.hover_request_started_ns = 0;
        self.definition_request_id = null;
        self.definition_request_started_ns = 0;
        self.references_request_id = null;
        self.references_request_started_ns = 0;
        self.change_mode = .full;
        self.supports_pull_diagnostics = true;
        self.supports_completion = false;
        self.supports_hover = false;
        self.supports_definition = false;
        self.supports_references = false;
        self.next_did_save_pulse_ns = 0;
        self.did_save_pulse_queued = false;
        self.bootstrap_saved = false;
        self.server_name = "off";
        self.recv_buffer.clearRetainingCapacity();
        self.clearCompletionItems();
        self.hover_text.clearRetainingCapacity();
        self.clearLocationItems(&self.definition_items);
        self.clearLocationItems(&self.references_items);
        if (self.pending_open_text) |text| {
            self.allocator.free(text);
            self.pending_open_text = null;
        }
        _ = self.setDiagnostics(0, null, "", &[_]usize{});
    }

    pub fn startForFile(self: *Client, file_path: []const u8, config: *const Config) !void {
        self.stop();

        const abs_file = try absolutePath(self.allocator, file_path);
        defer self.allocator.free(abs_file);

        var candidates = try self.collectStartCandidates(file_path, config);
        defer candidates.deinit();

        if (candidates.items.len == 0) return error.LspServerUnavailable;
        if (candidates.items.len > 1) {
            std.mem.sort(StartCandidate, candidates.items, {}, compareStartCandidate);
        }

        for (candidates.items) |candidate| {
            const root_path = try findRootDir(self.allocator, abs_file, candidate.root_markers);
            defer self.allocator.free(root_path);

            const started = switch (candidate.kind) {
                .command => try self.tryStartServer(
                    candidate.language_id,
                    file_path,
                    abs_file,
                    root_path,
                    candidate.command,
                    candidate.args,
                ),
                .tsgo_via_node => try self.tryStartTsgoViaNode(
                    candidate.language_id,
                    file_path,
                    abs_file,
                    root_path,
                ),
            };
            if (started) return;
        }

        return error.LspServerUnavailable;
    }

    fn tryStartServer(
        self: *Client,
        server_name: []const u8,
        file_path: []const u8,
        abs_file: []const u8,
        root_path: []const u8,
        command: []const u8,
        args: []const []const u8,
    ) !bool {
        const command_view = try buildCommandView(self.allocator, command, args);
        defer self.allocator.free(command_view);

        const argv = try resolveArgv(self.allocator, root_path, command_view);
        defer freeArgv(self.allocator, argv);

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return false;

        self.child = child;
        self.enabled = true;
        self.session_ready = false;
        self.change_mode = .full;
        self.supports_pull_diagnostics = true;
        self.next_did_save_pulse_ns = 0;
        self.server_name = server_name;
        self.version = 1;

        if (self.document_uri) |uri| self.allocator.free(uri);
        if (self.root_uri) |uri| self.allocator.free(uri);
        self.document_uri = try toFileUri(self.allocator, abs_file);
        self.root_uri = try toFileUri(self.allocator, root_path);

        const text = try std.fs.cwd().readFileAlloc(self.allocator, file_path, max_lsp_open_file_bytes);
        if (self.pending_open_text) |pending| self.allocator.free(pending);
        self.pending_open_text = text;

        self.sendInitialize() catch {
            self.stop();
            return false;
        };

        return true;
    }

    fn tryStartTsgoViaNode(
        self: *Client,
        server_name: []const u8,
        file_path: []const u8,
        abs_file: []const u8,
        root_path: []const u8,
    ) !bool {
        const tsgo_script = try std.fs.path.join(self.allocator, &.{
            root_path,
            "node_modules",
            "@typescript",
            "native-preview",
            "bin",
            "tsgo.js",
        });
        defer self.allocator.free(tsgo_script);

        if (std.fs.cwd().access(tsgo_script, .{})) |_| {} else |_| return false;

        const args = [_][]const u8{ tsgo_script, "--lsp", "-stdio" };
        return try self.tryStartServer(server_name, file_path, abs_file, root_path, "node", &args);
    }

    fn collectStartCandidates(
        self: *Client,
        file_path: []const u8,
        config: *const Config,
    ) !std.array_list.Managed(StartCandidate) {
        var candidates = std.array_list.Managed(StartCandidate).init(self.allocator);
        errdefer candidates.deinit();

        const language = presets.languageForPath(file_path) orelse return candidates;
        const language_roots = presets.rootMarkersForLanguage(language) orelse &fallback_root_markers;

        const is_typescript = std.mem.eql(u8, language, "typescript");
        if (is_typescript) {
            if (config.lsp_typescript.command) |command| {
                try candidates.append(.{
                    .name = "typescript-custom",
                    .language_id = "typescript",
                    .kind = .command,
                    .command = command,
                    .args = config.lsp_typescript.args.items,
                    .root_markers = if (config.lsp_typescript.root_markers.items.len > 0)
                        config.lsp_typescript.root_markers.items
                    else
                        language_roots,
                    .priority = 300,
                });
            } else {
                const default_presets = presets.defaults();
                for (default_presets) |preset| {
                    if (!presets.matchesPath(preset, file_path)) continue;
                    if (!allowTypescriptPreset(config, preset.name)) continue;

                    const roots = if (config.lsp_typescript.root_markers.items.len > 0)
                        config.lsp_typescript.root_markers.items
                    else
                        preset.root_markers;

                    try candidates.append(.{
                        .name = preset.name,
                        .language_id = preset.language_id,
                        .kind = .command,
                        .command = preset.command,
                        .args = preset.args,
                        .root_markers = roots,
                        .priority = preset.priority,
                    });
                }

                if (config.lsp_typescript.mode != .tsls) {
                    try candidates.append(.{
                        .name = "typescript-node-tsgo",
                        .language_id = "typescript",
                        .kind = .tsgo_via_node,
                        .command = "",
                        .args = &.{},
                        .root_markers = if (config.lsp_typescript.root_markers.items.len > 0)
                            config.lsp_typescript.root_markers.items
                        else
                            language_roots,
                        .priority = 115,
                    });
                }
            }
        } else {
            const default_presets = presets.defaults();
            for (default_presets) |preset| {
                if (!presets.matchesPath(preset, file_path)) continue;
                try candidates.append(.{
                    .name = preset.name,
                    .language_id = preset.language_id,
                    .kind = .command,
                    .command = preset.command,
                    .args = preset.args,
                    .root_markers = preset.root_markers,
                    .priority = preset.priority,
                });
            }
        }

        if (std.mem.eql(u8, language, "zig")) {
            self.applyLegacyZigConfig(&candidates, config);
        }

        try self.applyAdapterOverrides(&candidates, file_path, config);
        return candidates;
    }

    fn allowTypescriptPreset(config: *const Config, preset_name: []const u8) bool {
        return switch (config.lsp_typescript.mode) {
            .auto => std.mem.eql(u8, preset_name, "typescript-tsgo") or
                std.mem.eql(u8, preset_name, "typescript-npx-tsgo") or
                std.mem.eql(u8, preset_name, "typescript-tsls"),
            .tsgo => std.mem.eql(u8, preset_name, "typescript-tsgo") or
                std.mem.eql(u8, preset_name, "typescript-npx-tsgo"),
            .tsls => std.mem.eql(u8, preset_name, "typescript-tsls"),
        };
    }

    fn applyLegacyZigConfig(
        self: *Client,
        candidates: *std.array_list.Managed(StartCandidate),
        config: *const Config,
    ) void {
        _ = self;

        if (config.lsp_zig.enabled) |enabled| {
            if (!enabled) {
                removeLanguageCandidates(candidates, "zig");
                return;
            }
        }

        var index: usize = 0;
        while (index < candidates.items.len) : (index += 1) {
            var candidate = &candidates.items[index];
            if (!std.mem.eql(u8, candidate.language_id, "zig")) continue;
            if (!std.mem.eql(u8, candidate.name, "zig-zls")) continue;

            if (config.lsp_zig.command) |command| {
                candidate.command = command;
                candidate.args = config.lsp_zig.args.items;
                candidate.kind = .command;
            } else if (config.lsp_zig.args.items.len > 0) {
                candidate.args = config.lsp_zig.args.items;
            }

            if (config.lsp_zig.root_markers.items.len > 0) {
                candidate.root_markers = config.lsp_zig.root_markers.items;
            }
        }
    }

    fn applyAdapterOverrides(
        self: *Client,
        candidates: *std.array_list.Managed(StartCandidate),
        file_path: []const u8,
        config: *const Config,
    ) !void {
        _ = self;
        const ext = std.fs.path.extension(file_path);

        for (config.lsp_adapters.items) |adapter| {
            var found = false;
            var index: usize = 0;
            while (index < candidates.items.len) : (index += 1) {
                if (!std.mem.eql(u8, candidates.items[index].name, adapter.name)) continue;

                found = true;
                if (!adapter.enabled) {
                    _ = candidates.orderedRemove(index);
                } else {
                    var candidate = &candidates.items[index];
                    candidate.language_id = adapter.language;
                    candidate.kind = .command;
                    if (adapter.command) |command| {
                        candidate.command = command;
                        candidate.args = adapter.args.items;
                    } else if (adapter.args.items.len > 0) {
                        candidate.args = adapter.args.items;
                    }
                    if (adapter.root_markers.items.len > 0) {
                        candidate.root_markers = adapter.root_markers.items;
                    }
                    if (adapter.priority != 0) {
                        candidate.priority = adapter.priority;
                    }
                }
                break;
            }
            if (found) continue;

            if (!adapter.enabled) continue;
            if (!adapterAppliesToExtension(adapter.file_extensions.items, adapter.language, ext)) continue;
            const command = adapter.command orelse continue;
            const root_markers = if (adapter.root_markers.items.len > 0)
                adapter.root_markers.items
            else
                (presets.rootMarkersForLanguage(adapter.language) orelse &fallback_root_markers);

            try candidates.append(.{
                .name = adapter.name,
                .language_id = adapter.language,
                .kind = .command,
                .command = command,
                .args = adapter.args.items,
                .root_markers = root_markers,
                .priority = if (adapter.priority != 0) adapter.priority else 90,
            });
        }
    }

    fn adapterAppliesToExtension(
        file_extensions: []const []const u8,
        language: []const u8,
        ext: []const u8,
    ) bool {
        if (ext.len == 0) return false;

        if (file_extensions.len > 0) {
            for (file_extensions) |entry| {
                if (std.mem.eql(u8, entry, ext)) return true;
            }
            return false;
        }

        if (presets.extensionsForLanguage(language)) |default_exts| {
            for (default_exts) |entry| {
                if (std.mem.eql(u8, entry, ext)) return true;
            }
        }
        return false;
    }

    fn removeLanguageCandidates(candidates: *std.array_list.Managed(StartCandidate), language_id: []const u8) void {
        var index: usize = 0;
        while (index < candidates.items.len) {
            if (std.mem.eql(u8, candidates.items[index].language_id, language_id)) {
                _ = candidates.orderedRemove(index);
                continue;
            }
            index += 1;
        }
    }

    fn compareStartCandidate(_: void, lhs: StartCandidate, rhs: StartCandidate) bool {
        if (lhs.priority == rhs.priority) {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
        return lhs.priority > rhs.priority;
    }

    pub fn poll(self: *Client) !bool {
        self.maybeExpireDiagnosticRequest();
        self.maybeExpireFeatureRequests();
        self.reconcilePendingRequests();
        try self.maybeDispatchDidSavePulse();
        if (!self.enabled) return false;
        const child = self.child orelse return false;
        const stdout = child.stdout orelse return false;

        var fds = [1]std.posix.pollfd{
            std.posix.pollfd{
                .fd = stdout.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            },
        };

        const ready = try std.posix.poll(&fds, 0);
        if (ready == 0) return false;

        if ((fds[0].revents & std.posix.POLL.ERR) == std.posix.POLL.ERR or (fds[0].revents & std.posix.POLL.HUP) == std.posix.POLL.HUP) {
            self.stop();
            return true;
        }

        if ((fds[0].revents & std.posix.POLL.IN) != std.posix.POLL.IN) return false;

        var chunk: [8192]u8 = undefined;
        const read_len = stdout.read(&chunk) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => {
                self.stop();
                return err;
            },
        };
        if (read_len == 0) {
            self.stop();
            return true;
        }

        try self.recv_buffer.appendSlice(chunk[0..read_len]);
        return self.processIncoming();
    }

    pub fn diagnostics(self: *const Client) DiagnosticsSnapshot {
        return .{
            .count = self.diag_count,
            .first_line = self.diag_first_line,
            .first_message = self.diag_first_message.items,
            .first_symbol = self.diag_first_symbol.items,
            .lines = self.diag_lines.items,
            .pending_requests = self.pending_requests,
            .pending_ms = self.pendingDurationMs(),
            .last_latency_ms = self.last_latency_ms,
        };
    }

    pub fn capabilities(self: *const Client) CapabilitiesSnapshot {
        return .{
            .completion = self.supports_completion,
            .hover = self.supports_hover,
            .definition = self.supports_definition,
            .references = self.supports_references,
        };
    }

    pub fn completion(self: *const Client) CompletionSnapshot {
        return .{
            .pending = self.completion_request_id != null,
            .rev = self.completion_rev,
            .items = self.completion_items.items,
        };
    }

    pub fn hover(self: *const Client) HoverSnapshot {
        return .{
            .pending = self.hover_request_id != null,
            .rev = self.hover_rev,
            .text = self.hover_text.items,
        };
    }

    pub fn definitions(self: *const Client) LocationSnapshot {
        return .{
            .pending = self.definition_request_id != null,
            .rev = self.definition_rev,
            .items = self.definition_items.items,
        };
    }

    pub fn references(self: *const Client) LocationSnapshot {
        return .{
            .pending = self.references_request_id != null,
            .rev = self.references_rev,
            .items = self.references_items.items,
        };
    }

    pub fn clearDiagnostics(self: *Client) void {
        _ = self.setDiagnostics(0, null, "", &[_]usize{});
    }

    pub fn setDidSavePulseDebounceMs(self: *Client, debounce_ms: u16) void {
        self.did_save_pulse_interval_ns = @as(i128, @intCast(debounce_ms)) * std.time.ns_per_ms;
        self.next_did_save_pulse_ns = 0;
        self.did_save_pulse_queued = false;
    }

    pub fn didOpen(self: *Client, text: []const u8) !void {
        if (!self.enabled) return;
        const uri = self.document_uri orelse return;

        const params = .{
            .textDocument = .{
                .uri = uri,
                .languageId = self.server_name,
                .version = self.version,
                .text = text,
            },
        };
        try self.sendNotification("textDocument/didOpen", params);
        try self.requestDiagnostics();
    }

    pub fn didChange(self: *Client, text: []const u8) !void {
        if (!self.enabled) return;
        if (!self.session_ready) {
            if (self.pending_open_text) |pending| self.allocator.free(pending);
            self.pending_open_text = try self.allocator.dupe(u8, text);
            return;
        }
        const uri = self.document_uri orelse return;

        self.version += 1;

        const Change = struct { text: []const u8 };
        const changes = [_]Change{.{ .text = text }};

        const params = .{
            .textDocument = .{
                .uri = uri,
                .version = self.version,
            },
            .contentChanges = changes[0..],
        };

        try self.sendNotification("textDocument/didChange", params);
        self.scheduleDidSavePulse();
        try self.requestDiagnostics();
    }

    pub fn didChangeIncremental(self: *Client, change: IncrementalChange) !void {
        if (!self.enabled) return;
        if (!self.session_ready) return error.LspNotReady;
        if (self.change_mode != .incremental) return error.LspIncrementalUnsupported;
        const uri = self.document_uri orelse return;

        self.version += 1;

        const params = .{
            .textDocument = .{
                .uri = uri,
                .version = self.version,
            },
            .contentChanges = [_]struct {
                range: struct {
                    start: struct { line: usize, character: usize },
                    end: struct { line: usize, character: usize },
                },
                text: []const u8,
            }{.{
                .range = .{
                    .start = .{ .line = change.start_line, .character = change.start_character },
                    .end = .{ .line = change.end_line, .character = change.end_character },
                },
                .text = change.text,
            }},
        };

        try self.sendNotification("textDocument/didChange", params);
        self.scheduleDidSavePulse();
        try self.requestDiagnostics();
    }

    pub fn supportsIncrementalSync(self: *const Client) bool {
        return self.enabled and self.session_ready and self.change_mode == .incremental;
    }

    pub fn didSave(self: *Client) !void {
        if (!self.enabled) return;
        if (!self.session_ready) return;
        self.did_save_pulse_queued = false;
        try self.sendDidSaveNotification();
        self.next_did_save_pulse_ns = std.time.nanoTimestamp() + self.did_save_pulse_interval_ns;
        try self.requestDiagnostics();
    }

    pub fn requestCompletion(self: *Client, position: LspPosition) !void {
        if (!self.enabled or !self.session_ready) return;
        if (!self.supports_completion) return error.LspCapabilityUnavailable;
        if (self.completion_request_id != null) return;
        const uri = self.document_uri orelse return;

        const params = .{
            .textDocument = .{ .uri = uri },
            .position = .{
                .line = position.line,
                .character = position.character,
            },
            .context = .{
                .triggerKind = 1,
            },
        };

        self.clearCompletionItems();
        self.completion_rev +%= 1;
        self.completion_request_id = try self.sendRequest("textDocument/completion", params);
        self.completion_request_started_ns = std.time.nanoTimestamp();
    }

    pub fn requestHover(self: *Client, position: LspPosition) !void {
        if (!self.enabled or !self.session_ready) return;
        if (!self.supports_hover) return error.LspCapabilityUnavailable;
        if (self.hover_request_id != null) return;
        const uri = self.document_uri orelse return;

        const params = .{
            .textDocument = .{ .uri = uri },
            .position = .{
                .line = position.line,
                .character = position.character,
            },
        };

        self.hover_text.clearRetainingCapacity();
        self.hover_rev +%= 1;
        self.hover_request_id = try self.sendRequest("textDocument/hover", params);
        self.hover_request_started_ns = std.time.nanoTimestamp();
    }

    pub fn requestDefinition(self: *Client, position: LspPosition) !void {
        if (!self.enabled or !self.session_ready) return;
        if (!self.supports_definition) return error.LspCapabilityUnavailable;
        if (self.definition_request_id != null) return;
        const uri = self.document_uri orelse return;

        const params = .{
            .textDocument = .{ .uri = uri },
            .position = .{
                .line = position.line,
                .character = position.character,
            },
        };

        self.clearLocationItems(&self.definition_items);
        self.definition_rev +%= 1;
        self.definition_request_id = try self.sendRequest("textDocument/definition", params);
        self.definition_request_started_ns = std.time.nanoTimestamp();
    }

    pub fn requestReferences(self: *Client, position: LspPosition) !void {
        if (!self.enabled or !self.session_ready) return;
        if (!self.supports_references) return error.LspCapabilityUnavailable;
        if (self.references_request_id != null) return;
        const uri = self.document_uri orelse return;

        const params = .{
            .textDocument = .{ .uri = uri },
            .position = .{
                .line = position.line,
                .character = position.character,
            },
            .context = .{
                .includeDeclaration = true,
            },
        };

        self.clearLocationItems(&self.references_items);
        self.references_rev +%= 1;
        self.references_request_id = try self.sendRequest("textDocument/references", params);
        self.references_request_started_ns = std.time.nanoTimestamp();
    }

    fn scheduleDidSavePulse(self: *Client) void {
        if (!self.enabled or !self.session_ready) return;
        if (self.did_save_pulse_interval_ns <= 0) return;
        if (!std.mem.eql(u8, self.server_name, "typescript")) return;

        self.did_save_pulse_queued = true;
        self.next_did_save_pulse_ns = std.time.nanoTimestamp() + self.did_save_pulse_interval_ns;
    }

    fn maybeDispatchDidSavePulse(self: *Client) !void {
        if (!self.did_save_pulse_queued) return;
        if (!self.enabled or !self.session_ready) {
            self.did_save_pulse_queued = false;
            return;
        }
        if (self.did_save_pulse_interval_ns <= 0) {
            self.did_save_pulse_queued = false;
            return;
        }
        if (!std.mem.eql(u8, self.server_name, "typescript")) {
            self.did_save_pulse_queued = false;
            return;
        }

        const now = std.time.nanoTimestamp();
        if (now < self.next_did_save_pulse_ns) return;

        self.did_save_pulse_queued = false;
        self.next_did_save_pulse_ns = now + self.did_save_pulse_interval_ns;
        try self.sendDidSaveNotification();
        try self.requestDiagnostics();
    }

    fn sendInitialize(self: *Client) !void {
        const root_uri = self.root_uri orelse return;
        const params = .{
            .processId = @as(?i64, null),
            .rootUri = root_uri,
            .capabilities = .{
                .workspace = .{
                    .configuration = true,
                    .workspaceFolders = true,
                },
                .textDocument = .{
                    .publishDiagnostics = .{
                        .relatedInformation = true,
                        .versionSupport = true,
                    },
                    .synchronization = .{
                        .didSave = true,
                        .willSave = false,
                        .willSaveWaitUntil = false,
                    },
                },
            },
            .clientInfo = .{ .name = "zicro", .version = "0.1.0" },
        };
        self.initialize_request_id = try self.sendRequest("initialize", params);
    }

    fn sendInitialized(self: *Client) !void {
        const Empty = struct {};
        try self.sendNotification("initialized", Empty{});
    }

    fn sendRequest(self: *Client, method: []const u8, params: anytype) !u64 {
        if (!self.enabled) return error.LspDisabled;

        const request_id = self.next_id;
        const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .method = method,
            .params = params,
        }, .{});
        defer self.allocator.free(payload);

        self.next_id += 1;
        try self.sendPayload(payload);
        self.incrementPendingRequests();
        return request_id;
    }

    fn sendNotification(self: *Client, method: []const u8, params: anytype) !void {
        if (!self.enabled) return;

        const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
        }, .{});
        defer self.allocator.free(payload);

        try self.sendPayload(payload);
    }

    fn sendPayload(self: *Client, payload: []const u8) !void {
        if (!self.enabled) return;
        const child = self.child orelse return;
        const stdin = child.stdin orelse return;

        self.traceBytes(">> ", payload);

        var header_buf: [96]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{payload.len});
        stdin.writeAll(header) catch |err| {
            self.stop();
            return err;
        };
        stdin.writeAll(payload) catch |err| {
            self.stop();
            return err;
        };
    }

    fn processIncoming(self: *Client) !bool {
        var diagnostics_changed = false;
        var processed_count: usize = 0;

        while (processed_count < max_payloads_per_poll) {
            const header = findHeaderEnd(self.recv_buffer.items) orelse break;
            const header_bytes = self.recv_buffer.items[0..header.end];
            const content_length = parseContentLength(header_bytes) orelse {
                self.discardConsumed(header.end + header.sep_len);
                continue;
            };

            const payload_start = header.end + header.sep_len;
            const payload_end = payload_start + content_length;
            if (self.recv_buffer.items.len < payload_end) break;

            const payload = self.recv_buffer.items[payload_start..payload_end];
            if (try self.handleIncomingPayload(payload)) {
                diagnostics_changed = true;
            }

            self.discardConsumed(payload_end);
            processed_count += 1;
        }

        return diagnostics_changed;
    }

    fn handleIncomingPayload(self: *Client, payload: []const u8) !bool {
        self.traceBytes("<< ", payload);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        defer parsed.deinit();

        if (parsed.value != .object) return false;

        if (try self.handleInitializeResponse(parsed.value.object)) {
            return false;
        }

        if (try self.handleDiagnosticResponse(parsed.value.object)) {
            return true;
        }

        if (try self.handleCompletionResponse(parsed.value.object)) {
            return true;
        }

        if (try self.handleHoverResponse(parsed.value.object)) {
            return true;
        }

        if (try self.handleDefinitionResponse(parsed.value.object)) {
            return true;
        }

        if (try self.handleReferencesResponse(parsed.value.object)) {
            return true;
        }

        if (self.handleGenericResponse(parsed.value.object)) {
            return false;
        }

        const method_value = parsed.value.object.get("method") orelse return false;
        if (method_value != .string) return false;

        if (try self.handleServerRequest(parsed.value.object, method_value.string)) {
            return false;
        }

        if (!std.mem.eql(u8, method_value.string, "textDocument/publishDiagnostics")) return false;

        const params_value = parsed.value.object.get("params") orelse return false;
        if (params_value != .object) return false;
        const document_uri = self.document_uri orelse "";
        if (params_value.object.get("uri")) |uri_value| {
            if (uri_value == .string and document_uri.len > 0 and !uriEqualLoose(uri_value.string, document_uri)) {
                return false;
            }
        }

        const diagnostics_value = params_value.object.get("diagnostics") orelse return false;
        if (diagnostics_value != .array) return false;

        const diagnostics_items = diagnostics_value.array.items;
        return self.setDiagnosticsFromItems(diagnostics_items);
    }

    fn handleServerRequest(self: *Client, object: std.json.ObjectMap, method: []const u8) !bool {
        const id_value = object.get("id") orelse return false;
        const id = parseJsonRpcId(id_value) orelse return false;

        if (std.mem.eql(u8, method, "workspace/configuration")) {
            const count = workspaceConfigurationItemCount(object);
            try self.sendResponseNullArray(id, count);
            if (std.mem.eql(u8, self.server_name, "typescript") and !self.bootstrap_saved) {
                self.bootstrap_saved = true;
                self.didSave() catch {};
            }
            return true;
        }
        if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
            try self.sendResponseEmptyArray(id);
            return true;
        }

        try self.sendResponseNull(id);
        return true;
    }

    fn handleInitializeResponse(self: *Client, object: std.json.ObjectMap) !bool {
        const init_id = self.initialize_request_id orelse return false;
        const id_value = object.get("id") orelse return false;
        if (id_value != .integer) return false;
        if (id_value.integer < 0) return false;

        const response_id: u64 = @intCast(id_value.integer);
        if (response_id != init_id) return false;

        self.initialize_request_id = null;
        self.decrementPendingRequests();
        if (object.get("error")) |error_value| {
            if (error_value != .null) {
                self.stop();
                return true;
            }
        }

        self.change_mode = parseChangeModeFromInitializeResponse(object);
        const feature_caps = parseLspFeatureCapabilities(object);
        self.supports_completion = feature_caps.completion;
        self.supports_hover = feature_caps.hover;
        self.supports_definition = feature_caps.definition;
        self.supports_references = feature_caps.references;

        try self.sendInitialized();
        self.session_ready = true;

        if (self.pending_open_text) |text| {
            defer self.allocator.free(text);
            self.pending_open_text = null;
            try self.didOpen(text);
            if (std.mem.eql(u8, self.server_name, "typescript")) {
                try self.didChange(text);
            }
        } else {
            try self.didOpen("");
        }
        return true;
    }

    fn requestDiagnostics(self: *Client) !void {
        if (!self.enabled or !self.session_ready) return;
        if (!self.supports_pull_diagnostics) return;
        if (self.diagnostics_request_id != null) return;
        const uri = self.document_uri orelse return;

        const params = .{
            .textDocument = .{ .uri = uri },
        };

        self.diagnostics_request_id = try self.sendRequest("textDocument/diagnostic", params);
        self.diagnostics_request_started_ns = std.time.nanoTimestamp();
    }

    fn handleDiagnosticResponse(self: *Client, object: std.json.ObjectMap) !bool {
        const request_id = self.diagnostics_request_id orelse return false;
        const id_value = object.get("id") orelse return false;
        if (id_value != .integer) return false;
        if (id_value.integer < 0) return false;
        const response_id: u64 = @intCast(id_value.integer);
        if (response_id != request_id) return false;

        self.clearPendingDiagnosticRequest();

        if (object.get("error")) |error_value| {
            if (error_value != .null) {
                if (error_value == .object) {
                    if (error_value.object.get("code")) |code_value| {
                        if (code_value == .integer and code_value.integer == -32601) {
                            self.supports_pull_diagnostics = false;
                        }
                    }
                }
                return false;
            }
        }

        const result_value = object.get("result") orelse return false;
        switch (result_value) {
            .array => |items| {
                return self.setDiagnosticsFromItems(items.items);
            },
            .object => |obj| {
                const items_value = obj.get("items") orelse return false;
                if (items_value != .array) return false;
                return self.setDiagnosticsFromItems(items_value.array.items);
            },
            else => return false,
        }
    }

    fn handleCompletionResponse(self: *Client, object: std.json.ObjectMap) !bool {
        const request_id = self.completion_request_id orelse return false;
        const id_value = object.get("id") orelse return false;
        const response_id = parseResponseId(id_value) orelse return false;
        if (response_id != request_id) return false;

        self.clearPendingCompletionRequest();

        if (object.get("error")) |error_value| {
            if (error_value != .null) {
                self.clearCompletionItems();
                self.completion_rev +%= 1;
                return true;
            }
        }

        const result_value = object.get("result") orelse {
            self.clearCompletionItems();
            self.completion_rev +%= 1;
            return true;
        };
        if (result_value == .null) {
            self.clearCompletionItems();
            self.completion_rev +%= 1;
            return true;
        }

        var parsed_items = std.array_list.Managed(CompletionItem).init(self.allocator);
        defer parsed_items.deinit();
        errdefer {
            for (parsed_items.items) |item| {
                self.allocator.free(item.label);
                self.allocator.free(item.insert_text);
            }
        }

        switch (result_value) {
            .array => |items| {
                try self.appendCompletionItems(&parsed_items, items.items);
            },
            .object => |obj| {
                const items_value = obj.get("items") orelse return false;
                if (items_value != .array) return false;
                try self.appendCompletionItems(&parsed_items, items_value.array.items);
            },
            else => return false,
        }

        self.clearCompletionItems();
        try self.completion_items.appendSlice(parsed_items.items);
        self.completion_rev +%= 1;
        return true;
    }

    fn handleHoverResponse(self: *Client, object: std.json.ObjectMap) !bool {
        const request_id = self.hover_request_id orelse return false;
        const id_value = object.get("id") orelse return false;
        const response_id = parseResponseId(id_value) orelse return false;
        if (response_id != request_id) return false;

        self.clearPendingHoverRequest();

        if (object.get("error")) |error_value| {
            if (error_value != .null) {
                self.hover_text.clearRetainingCapacity();
                self.hover_rev +%= 1;
                return true;
            }
        }

        const result_value = object.get("result") orelse {
            self.hover_text.clearRetainingCapacity();
            self.hover_rev +%= 1;
            return true;
        };
        if (result_value == .null) {
            self.hover_text.clearRetainingCapacity();
            self.hover_rev +%= 1;
            return true;
        }

        self.hover_text.clearRetainingCapacity();
        if (hoverTextFromResult(result_value)) |text| {
            try self.hover_text.appendSlice(text);
        }
        self.hover_rev +%= 1;
        return true;
    }

    fn handleDefinitionResponse(self: *Client, object: std.json.ObjectMap) !bool {
        const request_id = self.definition_request_id orelse return false;
        const id_value = object.get("id") orelse return false;
        const response_id = parseResponseId(id_value) orelse return false;
        if (response_id != request_id) return false;

        self.clearPendingDefinitionRequest();

        if (object.get("error")) |error_value| {
            if (error_value != .null) {
                self.clearLocationItems(&self.definition_items);
                self.definition_rev +%= 1;
                return true;
            }
        }

        const result_value = object.get("result") orelse {
            self.clearLocationItems(&self.definition_items);
            self.definition_rev +%= 1;
            return true;
        };
        if (result_value == .null) {
            self.clearLocationItems(&self.definition_items);
            self.definition_rev +%= 1;
            return true;
        }

        self.clearLocationItems(&self.definition_items);
        switch (result_value) {
            .array => |items| try self.appendLocations(&self.definition_items, items.items),
            .object => {
                const one = [_]std.json.Value{result_value};
                try self.appendLocations(&self.definition_items, &one);
            },
            else => return false,
        }
        self.definition_rev +%= 1;
        return true;
    }

    fn handleReferencesResponse(self: *Client, object: std.json.ObjectMap) !bool {
        const request_id = self.references_request_id orelse return false;
        const id_value = object.get("id") orelse return false;
        const response_id = parseResponseId(id_value) orelse return false;
        if (response_id != request_id) return false;

        self.clearPendingReferencesRequest();

        if (object.get("error")) |error_value| {
            if (error_value != .null) {
                self.clearLocationItems(&self.references_items);
                self.references_rev +%= 1;
                return true;
            }
        }

        const result_value = object.get("result") orelse {
            self.clearLocationItems(&self.references_items);
            self.references_rev +%= 1;
            return true;
        };
        if (result_value == .null) {
            self.clearLocationItems(&self.references_items);
            self.references_rev +%= 1;
            return true;
        }
        if (result_value != .array) return false;

        self.clearLocationItems(&self.references_items);
        try self.appendLocations(&self.references_items, result_value.array.items);
        self.references_rev +%= 1;
        return true;
    }

    fn handleGenericResponse(self: *Client, object: std.json.ObjectMap) bool {
        const id_value = object.get("id") orelse return false;
        if (id_value != .integer or id_value.integer < 0) return false;
        const response_id: u64 = @intCast(id_value.integer);

        const has_result = object.get("result") != null;
        const has_error = object.get("error") != null;
        if (!has_result and !has_error) return false;

        if (self.diagnostics_request_id) |request_id| {
            if (request_id == response_id) {
                if (has_error) {
                    if (object.get("error")) |error_value| {
                        if (error_value != .null) {
                            self.supports_pull_diagnostics = false;
                        }
                    }
                }
                self.clearPendingDiagnosticRequest();
                return true;
            }
        }

        self.decrementPendingRequests();
        return true;
    }

    fn clearPendingDiagnosticRequest(self: *Client) void {
        if (self.diagnostics_request_started_ns > 0) {
            const elapsed = std.time.nanoTimestamp() - self.diagnostics_request_started_ns;
            self.last_latency_ms = nsToMs(elapsed);
        }
        self.diagnostics_request_id = null;
        self.diagnostics_request_started_ns = 0;
        self.decrementPendingRequests();
    }

    fn maybeExpireDiagnosticRequest(self: *Client) void {
        if (self.diagnostics_request_id == null) return;
        if (self.diagnostics_request_started_ns == 0) return;
        const now = std.time.nanoTimestamp();
        if (now - self.diagnostics_request_started_ns < diagnostics_request_timeout_ns) return;

        self.supports_pull_diagnostics = false;
        self.clearPendingDiagnosticRequest();
    }

    fn maybeExpireFeatureRequests(self: *Client) void {
        const now = std.time.nanoTimestamp();

        if (self.completion_request_id != null and self.completion_request_started_ns > 0) {
            if (now - self.completion_request_started_ns >= diagnostics_request_timeout_ns) {
                self.clearPendingCompletionRequest();
            }
        }

        if (self.hover_request_id != null and self.hover_request_started_ns > 0) {
            if (now - self.hover_request_started_ns >= diagnostics_request_timeout_ns) {
                self.clearPendingHoverRequest();
            }
        }

        if (self.definition_request_id != null and self.definition_request_started_ns > 0) {
            if (now - self.definition_request_started_ns >= diagnostics_request_timeout_ns) {
                self.clearPendingDefinitionRequest();
            }
        }

        if (self.references_request_id != null and self.references_request_started_ns > 0) {
            if (now - self.references_request_started_ns >= diagnostics_request_timeout_ns) {
                self.clearPendingReferencesRequest();
            }
        }
    }

    fn clearPendingCompletionRequest(self: *Client) void {
        if (self.completion_request_started_ns > 0) {
            const elapsed = std.time.nanoTimestamp() - self.completion_request_started_ns;
            self.last_latency_ms = nsToMs(elapsed);
        }
        self.completion_request_id = null;
        self.completion_request_started_ns = 0;
        self.decrementPendingRequests();
    }

    fn clearPendingHoverRequest(self: *Client) void {
        if (self.hover_request_started_ns > 0) {
            const elapsed = std.time.nanoTimestamp() - self.hover_request_started_ns;
            self.last_latency_ms = nsToMs(elapsed);
        }
        self.hover_request_id = null;
        self.hover_request_started_ns = 0;
        self.decrementPendingRequests();
    }

    fn clearPendingDefinitionRequest(self: *Client) void {
        if (self.definition_request_started_ns > 0) {
            const elapsed = std.time.nanoTimestamp() - self.definition_request_started_ns;
            self.last_latency_ms = nsToMs(elapsed);
        }
        self.definition_request_id = null;
        self.definition_request_started_ns = 0;
        self.decrementPendingRequests();
    }

    fn clearPendingReferencesRequest(self: *Client) void {
        if (self.references_request_started_ns > 0) {
            const elapsed = std.time.nanoTimestamp() - self.references_request_started_ns;
            self.last_latency_ms = nsToMs(elapsed);
        }
        self.references_request_id = null;
        self.references_request_started_ns = 0;
        self.decrementPendingRequests();
    }

    fn appendCompletionItems(self: *Client, out: *std.array_list.Managed(CompletionItem), items: []const std.json.Value) !void {
        const max_items: usize = 64;

        for (items) |item| {
            if (out.items.len >= max_items) break;
            if (item != .object) continue;

            const label_value = item.object.get("label") orelse continue;
            if (label_value != .string) continue;
            const label = try self.allocator.dupe(u8, label_value.string);
            errdefer self.allocator.free(label);

            var insert_text = label_value.string;
            var has_text_edit = false;
            var edit_start: LspPosition = .{ .line = 0, .character = 0 };
            var edit_end: LspPosition = .{ .line = 0, .character = 0 };

            if (item.object.get("insertText")) |insert_value| {
                if (insert_value == .string and insert_value.string.len > 0) {
                    insert_text = insert_value.string;
                }
            }

            if (item.object.get("textEdit")) |text_edit_value| {
                const parsed = parseTextEdit(text_edit_value);
                if (parsed.ok) {
                    has_text_edit = true;
                    edit_start = parsed.start;
                    edit_end = parsed.end;
                    insert_text = parsed.new_text;
                }
            }

            const insert_owned = try self.allocator.dupe(u8, insert_text);
            errdefer self.allocator.free(insert_owned);

            try out.append(.{
                .label = label,
                .insert_text = insert_owned,
                .has_text_edit = has_text_edit,
                .text_edit_start = edit_start,
                .text_edit_end = edit_end,
            });
        }
    }

    fn clearCompletionItems(self: *Client) void {
        for (self.completion_items.items) |item| {
            self.allocator.free(item.label);
            self.allocator.free(item.insert_text);
        }
        self.completion_items.clearRetainingCapacity();
    }

    fn appendLocations(self: *Client, out: *std.array_list.Managed(LocationItem), items: []const std.json.Value) !void {
        const document_uri = self.document_uri orelse "";
        for (items) |item| {
            if (item != .object) continue;
            const parsed = parseLocation(item.object) orelse continue;

            const uri_owned = try self.allocator.dupe(u8, parsed.uri);
            errdefer self.allocator.free(uri_owned);

            try out.append(.{
                .uri = uri_owned,
                .line = parsed.position.line,
                .character = parsed.position.character,
                .same_document = uriEqualLoose(uri_owned, document_uri),
            });
        }
    }

    fn clearLocationItems(self: *Client, items: *std.array_list.Managed(LocationItem)) void {
        for (items.items) |item| {
            self.allocator.free(item.uri);
        }
        items.clearRetainingCapacity();
    }

    fn incrementPendingRequests(self: *Client) void {
        if (self.pending_requests == 0) {
            self.pending_since_ns = std.time.nanoTimestamp();
        }
        self.pending_requests += 1;
    }

    fn decrementPendingRequests(self: *Client) void {
        if (self.pending_requests == 0) return;
        self.pending_requests -= 1;
        if (self.pending_requests == 0) {
            self.pending_since_ns = 0;
        }
    }

    fn pendingDurationMs(self: *const Client) u32 {
        if (self.pending_requests == 0 or self.pending_since_ns == 0) return 0;
        const elapsed = std.time.nanoTimestamp() - self.pending_since_ns;
        return nsToMs(elapsed);
    }

    fn reconcilePendingRequests(self: *Client) void {
        if (self.pending_requests == 0) return;
        if (self.initialize_request_id != null) return;
        if (self.diagnostics_request_id != null) return;
        if (self.completion_request_id != null) return;
        if (self.hover_request_id != null) return;
        if (self.definition_request_id != null) return;
        if (self.references_request_id != null) return;
        self.pending_requests = 0;
        self.pending_since_ns = 0;
    }

    fn setDiagnosticsFromItems(self: *Client, items: []const std.json.Value) bool {
        const summary = diagnosticsSummary(items);
        var lines = std.array_list.Managed(usize).init(self.allocator);
        defer lines.deinit();

        for (items) |item| {
            const line = diagnosticLine(item) orelse continue;
            if (!containsLine(lines.items, line)) {
                lines.append(line) catch {};
            }
        }

        return self.setDiagnostics(items.len, summary.first_line, summary.first_message, lines.items);
    }

    fn sendDidSaveNotification(self: *Client) !void {
        const uri = self.document_uri orelse return;
        const params = .{
            .textDocument = .{ .uri = uri },
        };
        try self.sendNotification("textDocument/didSave", params);
    }

    fn sendResponseNull(self: *Client, id: JsonRpcId) !void {
        var payload = std.array_list.Managed(u8).init(self.allocator);
        defer payload.deinit();

        try payload.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
        try self.appendJsonRpcId(&payload, id);
        try payload.appendSlice(",\"result\":null}");
        try self.sendPayload(payload.items);
    }

    fn sendResponseEmptyArray(self: *Client, id: JsonRpcId) !void {
        var payload = std.array_list.Managed(u8).init(self.allocator);
        defer payload.deinit();

        try payload.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
        try self.appendJsonRpcId(&payload, id);
        try payload.appendSlice(",\"result\":[]}");
        try self.sendPayload(payload.items);
    }

    fn sendResponseNullArray(self: *Client, id: JsonRpcId, count: usize) !void {
        var payload = std.array_list.Managed(u8).init(self.allocator);
        defer payload.deinit();

        try payload.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
        try self.appendJsonRpcId(&payload, id);
        try payload.appendSlice(",\"result\":[");
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (i > 0) try payload.append(',');
            try payload.appendSlice("null");
        }
        try payload.appendSlice("]}");
        try self.sendPayload(payload.items);
    }

    fn appendJsonRpcId(self: *Client, payload: *std.array_list.Managed(u8), id: JsonRpcId) !void {
        switch (id) {
            .integer => |raw| try payload.writer().print("{d}", .{raw}),
            .string => |raw| {
                const encoded = try std.json.Stringify.valueAlloc(self.allocator, raw, .{});
                defer self.allocator.free(encoded);
                try payload.appendSlice(encoded);
            },
        }
    }

    fn setDiagnostics(self: *Client, count: usize, first_line: ?usize, first_message_input: []const u8, lines: []const usize) bool {
        const first_message = if (first_message_input.len > 400) first_message_input[0..400] else first_message_input;
        const first_symbol = extractQuotedSymbol(first_message);
        const changed = count != self.diag_count or
            first_line != self.diag_first_line or
            !std.mem.eql(u8, first_message, self.diag_first_message.items) or
            !std.mem.eql(u8, first_symbol, self.diag_first_symbol.items) or
            !std.mem.eql(usize, lines, self.diag_lines.items);
        if (!changed) return false;

        self.diag_count = count;
        self.diag_first_line = first_line;
        self.diag_first_message.clearRetainingCapacity();
        self.diag_first_message.appendSlice(first_message) catch {};
        self.diag_first_symbol.clearRetainingCapacity();
        self.diag_first_symbol.appendSlice(first_symbol) catch {};
        self.diag_lines.clearRetainingCapacity();
        self.diag_lines.appendSlice(lines) catch {};
        return true;
    }

    fn discardConsumed(self: *Client, count: usize) void {
        if (count >= self.recv_buffer.items.len) {
            self.recv_buffer.clearRetainingCapacity();
            return;
        }

        const remaining = self.recv_buffer.items[count..];
        std.mem.copyForwards(u8, self.recv_buffer.items[0..remaining.len], remaining);
        self.recv_buffer.items.len = remaining.len;
    }

    fn traceBytes(self: *Client, prefix: []const u8, bytes: []const u8) void {
        if (!self.trace_enabled) return;

        var file = std.fs.openFileAbsolute("/tmp/zicro-lsp-trace.log", .{ .mode = .write_only }) catch
            std.fs.createFileAbsolute("/tmp/zicro-lsp-trace.log", .{ .truncate = false }) catch return;
        defer file.close();

        file.seekFromEnd(0) catch return;
        file.writeAll(prefix) catch return;
        const payload = if (bytes.len > 2000) bytes[0..2000] else bytes;
        file.writeAll(payload) catch return;
        file.writeAll("\n") catch {};
    }
};

const DiagnosticsSummary = struct {
    first_line: ?usize,
    first_message: []const u8,
};

const JsonRpcId = union(enum) {
    integer: u64,
    string: []const u8,
};

fn parseChangeModeFromInitializeResponse(object: std.json.ObjectMap) ChangeMode {
    const result_value = object.get("result") orelse return .full;
    if (result_value != .object) return .full;

    const capabilities_value = result_value.object.get("capabilities") orelse return .full;
    if (capabilities_value != .object) return .full;

    const sync_value = capabilities_value.object.get("textDocumentSync") orelse return .full;
    return parseChangeModeFromTextDocumentSync(sync_value);
}

fn parseChangeModeFromTextDocumentSync(sync_value: std.json.Value) ChangeMode {
    switch (sync_value) {
        .integer => |sync_kind| {
            return if (sync_kind == 2) .incremental else .full;
        },
        .object => |sync_obj| {
            const change_value = sync_obj.get("change") orelse return .full;
            if (change_value != .integer) return .full;
            return if (change_value.integer == 2) .incremental else .full;
        },
        else => return .full,
    }
}

fn diagnosticsSummary(items: []const std.json.Value) DiagnosticsSummary {
    var first_line: ?usize = null;
    var first_message: []const u8 = "";

    if (items.len == 0) {
        return .{
            .first_line = null,
            .first_message = "",
        };
    }

    if (items[0] == .object) {
        const first_obj = items[0].object;
        if (first_obj.get("message")) |message_value| {
            if (message_value == .string) {
                first_message = message_value.string;
            }
        }
        first_line = diagnosticLine(items[0]);
    }

    return .{
        .first_line = first_line,
        .first_message = first_message,
    };
}

fn diagnosticLine(item: std.json.Value) ?usize {
    if (item != .object) return null;
    const range_value = item.object.get("range") orelse return null;
    if (range_value != .object) return null;
    const start_value = range_value.object.get("start") orelse return null;
    if (start_value != .object) return null;
    const line_value = start_value.object.get("line") orelse return null;
    if (line_value != .integer or line_value.integer < 0) return null;
    const line_num: usize = @intCast(line_value.integer);
    return line_num + 1;
}

fn containsLine(lines: []const usize, target: usize) bool {
    for (lines) |line| {
        if (line == target) return true;
    }
    return false;
}

fn extractQuotedSymbol(message: []const u8) []const u8 {
    const first_quote = std.mem.indexOfScalar(u8, message, '\'') orelse return "";
    const rest = message[first_quote + 1 ..];
    const second_rel = std.mem.indexOfScalar(u8, rest, '\'') orelse return "";
    if (second_rel == 0) return "";
    return rest[0..second_rel];
}

const HeaderEnd = struct {
    end: usize,
    sep_len: usize,
};

fn findHeaderEnd(bytes: []const u8) ?HeaderEnd {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |index| {
        return .{ .end = index, .sep_len = 4 };
    }
    if (std.mem.indexOf(u8, bytes, "\n\n")) |index| {
        return .{ .end = index, .sep_len = 2 };
    }
    return null;
}

fn parseContentLength(header_bytes: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, header_bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, "\r ");
        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        if (!std.ascii.eqlIgnoreCase(key, "Content-Length")) continue;
        const raw = line[colon + 1 ..];
        const value = std.mem.trim(u8, raw, " ");
        return std.fmt.parseUnsigned(usize, value, 10) catch null;
    }
    return null;
}

fn workspaceConfigurationItemCount(object: std.json.ObjectMap) usize {
    const params_value = object.get("params") orelse return 0;
    if (params_value != .object) return 0;
    const items_value = params_value.object.get("items") orelse return 0;
    if (items_value != .array) return 0;
    return items_value.array.items.len;
}

fn parseJsonRpcId(value: std.json.Value) ?JsonRpcId {
    return switch (value) {
        .integer => |raw| blk: {
            if (raw < 0) break :blk null;
            break :blk JsonRpcId{ .integer = @intCast(raw) };
        },
        .string => |raw| JsonRpcId{ .string = raw },
        else => null,
    };
}

fn parseResponseId(value: std.json.Value) ?u64 {
    if (value != .integer) return null;
    if (value.integer < 0) return null;
    return @intCast(value.integer);
}

const ParsedTextEdit = struct {
    ok: bool,
    start: LspPosition,
    end: LspPosition,
    new_text: []const u8,
};

fn parseTextEdit(value: std.json.Value) ParsedTextEdit {
    if (value != .object) return .{
        .ok = false,
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
        .new_text = "",
    };

    if (value.object.get("newText")) |new_text_value| {
        if (new_text_value == .string) {
            if (value.object.get("range")) |range_value| {
                if (parseRange(range_value)) |range| {
                    return .{
                        .ok = true,
                        .start = range.start,
                        .end = range.end,
                        .new_text = new_text_value.string,
                    };
                }
            }

            if (value.object.get("replace")) |replace_value| {
                if (parseRange(replace_value)) |range| {
                    return .{
                        .ok = true,
                        .start = range.start,
                        .end = range.end,
                        .new_text = new_text_value.string,
                    };
                }
            }

            if (value.object.get("insert")) |insert_value| {
                if (parseRange(insert_value)) |range| {
                    return .{
                        .ok = true,
                        .start = range.start,
                        .end = range.end,
                        .new_text = new_text_value.string,
                    };
                }
            }
        }
    }

    return .{
        .ok = false,
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
        .new_text = "",
    };
}

const RangeValue = struct {
    start: LspPosition,
    end: LspPosition,
};

fn parseRange(value: std.json.Value) ?RangeValue {
    if (value != .object) return null;
    const start_value = value.object.get("start") orelse return null;
    const end_value = value.object.get("end") orelse return null;
    const start = parsePosition(start_value) orelse return null;
    const end = parsePosition(end_value) orelse return null;
    return .{
        .start = start,
        .end = end,
    };
}

fn parsePosition(value: std.json.Value) ?LspPosition {
    if (value != .object) return null;
    const line_value = value.object.get("line") orelse return null;
    const char_value = value.object.get("character") orelse return null;
    if (line_value != .integer or line_value.integer < 0) return null;
    if (char_value != .integer or char_value.integer < 0) return null;
    return .{
        .line = @intCast(line_value.integer),
        .character = @intCast(char_value.integer),
    };
}

const ParsedLocation = struct {
    uri: []const u8,
    position: LspPosition,
};

fn parseLocation(object: std.json.ObjectMap) ?ParsedLocation {
    if (object.get("uri")) |uri_value| {
        if (uri_value == .string) {
            const range_value = object.get("range") orelse return null;
            const range = parseRange(range_value) orelse return null;
            return .{
                .uri = uri_value.string,
                .position = range.start,
            };
        }
    }

    if (object.get("targetUri")) |uri_value| {
        if (uri_value == .string) {
            if (object.get("targetSelectionRange")) |target_sel| {
                const range = parseRange(target_sel) orelse return null;
                return .{
                    .uri = uri_value.string,
                    .position = range.start,
                };
            }

            if (object.get("targetRange")) |target_range| {
                const range = parseRange(target_range) orelse return null;
                return .{
                    .uri = uri_value.string,
                    .position = range.start,
                };
            }
        }
    }

    return null;
}

fn hoverTextFromResult(value: std.json.Value) ?[]const u8 {
    if (value == .object) {
        if (value.object.get("contents")) |contents| {
            return hoverTextFromContents(contents);
        }
    }
    return hoverTextFromContents(value);
}

fn hoverTextFromContents(contents: std.json.Value) ?[]const u8 {
    return switch (contents) {
        .string => |text| if (text.len > 0) text else null,
        .array => |items| blk: {
            for (items.items) |item| {
                if (hoverTextFromContents(item)) |text| {
                    break :blk text;
                }
            }
            break :blk null;
        },
        .object => |obj| blk: {
            if (obj.get("value")) |value| {
                if (value == .string and value.string.len > 0) {
                    break :blk value.string;
                }
            }
            if (obj.get("language")) |_| {
                if (obj.get("value")) |value| {
                    if (value == .string and value.string.len > 0) {
                        break :blk value.string;
                    }
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn uriEqualLoose(lhs: []const u8, rhs: []const u8) bool {
    if (std.mem.eql(u8, lhs, rhs)) return true;
    return std.ascii.eqlIgnoreCase(lhs, rhs);
}

fn parseLspFeatureCapabilities(object: std.json.ObjectMap) CapabilitiesSnapshot {
    var out: CapabilitiesSnapshot = .{
        .completion = false,
        .hover = false,
        .definition = false,
        .references = false,
    };

    const result_value = object.get("result") orelse return out;
    if (result_value != .object) return out;
    const capabilities_value = result_value.object.get("capabilities") orelse return out;
    if (capabilities_value != .object) return out;

    out.completion = hasCapability(capabilities_value.object.get("completionProvider"));
    out.hover = hasCapability(capabilities_value.object.get("hoverProvider"));
    out.definition = hasCapability(capabilities_value.object.get("definitionProvider"));
    out.references = hasCapability(capabilities_value.object.get("referencesProvider"));
    return out;
}

fn hasCapability(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    return switch (actual) {
        .null => false,
        .bool => |enabled| enabled,
        .object => true,
        else => false,
    };
}

fn nsToMs(value_ns: i128) u32 {
    if (value_ns <= 0) return 0;
    const value_u128: u128 = @intCast(value_ns);
    const ms_u128 = value_u128 / std.time.ns_per_ms;
    const max_u32 = std.math.maxInt(u32);
    if (ms_u128 > max_u32) return max_u32;
    return @intCast(ms_u128);
}

test "parseContentLength handles CRLF and LF headers" {
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength("Content-Length: 42\r\nContent-Type: x\r\n"));
    try std.testing.expectEqual(@as(?usize, 7), parseContentLength("content-length: 7\n"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Type: x\r\n"));
}

test "findHeaderEnd supports CRLF and LF separators" {
    const crlf = findHeaderEnd("Content-Length: 1\r\n\r\nx").?;
    try std.testing.expectEqual(@as(usize, 17), crlf.end);
    try std.testing.expectEqual(@as(usize, 4), crlf.sep_len);

    const lf = findHeaderEnd("Content-Length: 1\n\nx").?;
    try std.testing.expectEqual(@as(usize, 17), lf.end);
    try std.testing.expectEqual(@as(usize, 2), lf.sep_len);
}

test "parse initialize response detects incremental sync" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "id": 1,
        \\  "result": {
        \\    "capabilities": {
        \\      "textDocumentSync": { "change": 2 }
        \\    }
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const mode = parseChangeModeFromInitializeResponse(parsed.value.object);
    try std.testing.expectEqual(ChangeMode.incremental, mode);
}

test "parse initialize response defaults to full sync" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "id": 1,
        \\  "result": {
        \\    "capabilities": {
        \\      "textDocumentSync": 1
        \\    }
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const mode = parseChangeModeFromInitializeResponse(parsed.value.object);
    try std.testing.expectEqual(ChangeMode.full, mode);
}

test "diagnosticsSummary extracts first message and line" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {
        \\    "range": { "start": { "line": 3, "character": 1 }, "end": { "line": 3, "character": 2 } },
        \\    "message": "bad type"
        \\  },
        \\  {
        \\    "range": { "start": { "line": 9, "character": 0 }, "end": { "line": 9, "character": 1 } },
        \\    "message": "second"
        \\  }
        \\]
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    const summary = diagnosticsSummary(parsed.value.array.items);
    try std.testing.expectEqual(@as(?usize, 4), summary.first_line);
    try std.testing.expectEqualStrings("bad type", summary.first_message);
}

test "diagnosticLine extracts one-based lines" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "range": { "start": { "line": 6, "character": 0 }, "end": { "line": 6, "character": 1 } },
        \\  "message": "x"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const line = diagnosticLine(parsed.value);
    try std.testing.expectEqual(@as(?usize, 7), line);
}

test "extractQuotedSymbol parses lint variable name" {
    try std.testing.expectEqualStrings("hello", extractQuotedSymbol("'hello' is declared but its value is never read."));
    try std.testing.expectEqualStrings("", extractQuotedSymbol("no quoted symbol"));
}

test "pending diagnostics request expires and clears" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    client.supports_pull_diagnostics = true;
    client.pending_requests = 1;
    client.diagnostics_request_id = 42;
    client.diagnostics_request_started_ns = std.time.nanoTimestamp() - diagnostics_request_timeout_ns - 1;

    client.maybeExpireDiagnosticRequest();

    try std.testing.expect(client.diagnostics_request_id == null);
    try std.testing.expectEqual(@as(usize, 0), client.pending_requests);
    try std.testing.expect(!client.supports_pull_diagnostics);
}

test "parse feature capabilities from initialize response" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "id": 1,
        \\  "result": {
        \\    "capabilities": {
        \\      "completionProvider": { "triggerCharacters": ["."] },
        \\      "hoverProvider": true,
        \\      "definitionProvider": true,
        \\      "referencesProvider": true
        \\    }
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const caps = parseLspFeatureCapabilities(parsed.value.object);
    try std.testing.expect(caps.completion);
    try std.testing.expect(caps.hover);
    try std.testing.expect(caps.definition);
    try std.testing.expect(caps.references);
}

test "parse text edit supports both range and replace fields" {
    const allocator = std.testing.allocator;

    const payload_range =
        \\{
        \\  "newText": "value",
        \\  "range": {
        \\    "start": { "line": 1, "character": 2 },
        \\    "end": { "line": 1, "character": 4 }
        \\  }
        \\}
    ;
    const parsed_range = try std.json.parseFromSlice(std.json.Value, allocator, payload_range, .{});
    defer parsed_range.deinit();
    const range_edit = parseTextEdit(parsed_range.value);
    try std.testing.expect(range_edit.ok);
    try std.testing.expectEqual(@as(usize, 1), range_edit.start.line);
    try std.testing.expectEqual(@as(usize, 2), range_edit.start.character);

    const payload_replace =
        \\{
        \\  "newText": "value2",
        \\  "replace": {
        \\    "start": { "line": 3, "character": 5 },
        \\    "end": { "line": 3, "character": 8 }
        \\  }
        \\}
    ;
    const parsed_replace = try std.json.parseFromSlice(std.json.Value, allocator, payload_replace, .{});
    defer parsed_replace.deinit();
    const replace_edit = parseTextEdit(parsed_replace.value);
    try std.testing.expect(replace_edit.ok);
    try std.testing.expectEqual(@as(usize, 3), replace_edit.start.line);
    try std.testing.expectEqual(@as(usize, 8), replace_edit.end.character);
}

test "parse location supports both Location and LocationLink" {
    const allocator = std.testing.allocator;

    const location_payload =
        \\{
        \\  "uri": "file:///tmp/a.ts",
        \\  "range": {
        \\    "start": { "line": 4, "character": 1 },
        \\    "end": { "line": 4, "character": 2 }
        \\  }
        \\}
    ;
    const parsed_location = try std.json.parseFromSlice(std.json.Value, allocator, location_payload, .{});
    defer parsed_location.deinit();
    try std.testing.expect(parsed_location.value == .object);
    const location = parseLocation(parsed_location.value.object).?;
    try std.testing.expectEqualStrings("file:///tmp/a.ts", location.uri);
    try std.testing.expectEqual(@as(usize, 4), location.position.line);

    const link_payload =
        \\{
        \\  "targetUri": "file:///tmp/b.ts",
        \\  "targetSelectionRange": {
        \\    "start": { "line": 7, "character": 3 },
        \\    "end": { "line": 7, "character": 9 }
        \\  }
        \\}
    ;
    const parsed_link = try std.json.parseFromSlice(std.json.Value, allocator, link_payload, .{});
    defer parsed_link.deinit();
    try std.testing.expect(parsed_link.value == .object);
    const link = parseLocation(parsed_link.value.object).?;
    try std.testing.expectEqualStrings("file:///tmp/b.ts", link.uri);
    try std.testing.expectEqual(@as(usize, 3), link.position.character);
}

test "hover text parser extracts useful content" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "contents": {
        \\    "kind": "markdown",
        \\    "value": "const value: number"
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const text = hoverTextFromResult(parsed.value).?;
    try std.testing.expectEqualStrings("const value: number", text);
}

test "publishDiagnostics ignores updates for other document uri" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    client.document_uri = try allocator.dupe(u8, "file:///Users/example/index.ts");
    _ = client.setDiagnostics(1, 3, "Type error", &[_]usize{3});

    const payload =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "textDocument/publishDiagnostics",
        \\  "params": {
        \\    "uri": "file:///Users/example/tsconfig.json",
        \\    "diagnostics": []
        \\  }
        \\}
    ;

    const changed = try client.handleIncomingPayload(payload);
    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(usize, 1), client.diag_count);
    try std.testing.expectEqual(@as(?usize, 3), client.diag_first_line);
}

test "didSave pulse is trailing debounced" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    client.enabled = true;
    client.session_ready = true;
    client.server_name = "typescript";
    client.document_uri = try allocator.dupe(u8, "file:///Users/example/index.ts");
    client.did_save_pulse_interval_ns = 64 * std.time.ns_per_ms;

    try client.didChange("const value = 1;");
    try std.testing.expect(client.did_save_pulse_queued);
    const first_deadline = client.next_did_save_pulse_ns;
    try std.testing.expect(first_deadline > 0);

    try client.maybeDispatchDidSavePulse();
    try std.testing.expect(client.did_save_pulse_queued);

    client.next_did_save_pulse_ns = std.time.nanoTimestamp() - 1;
    try client.maybeDispatchDidSavePulse();
    try std.testing.expect(!client.did_save_pulse_queued);
}

fn resolveArgv(allocator: std.mem.Allocator, root_path: []const u8, command: []const []const u8) ![]const []const u8 {
    var argv = try allocator.alloc([]const u8, command.len);

    argv[0] = try resolveBinary(allocator, root_path, command[0]);
    var i: usize = 1;
    while (i < command.len) : (i += 1) {
        argv[i] = try allocator.dupe(u8, command[i]);
    }

    return argv;
}

fn buildCommandView(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, args.len + 1);
    out[0] = command;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        out[i + 1] = args[i];
    }

    return out;
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |entry| {
        allocator.free(entry);
    }
    allocator.free(argv);
}

fn resolveBinary(allocator: std.mem.Allocator, root_path: []const u8, binary: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, binary, std.fs.path.sep)) |_| {
        return allocator.dupe(u8, binary);
    }

    const local_path = try std.fs.path.join(allocator, &.{ root_path, "node_modules", ".bin", binary });
    if (std.fs.cwd().access(local_path, .{})) |_| {
        return local_path;
    } else |_| {
        allocator.free(local_path);
    }

    return allocator.dupe(u8, binary);
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const cwd = std.fs.cwd();
    return cwd.realpathAlloc(allocator, path);
}

fn toFileUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var escaped = std.array_list.Managed(u8).init(allocator);
    defer escaped.deinit();

    for (path) |ch| {
        if (ch == ' ') {
            try escaped.appendSlice("%20");
        } else {
            try escaped.append(ch);
        }
    }

    return std.fmt.allocPrint(allocator, "file://{s}", .{escaped.items});
}

fn findRootDir(allocator: std.mem.Allocator, abs_file: []const u8, markers: []const []const u8) ![]u8 {
    const start_dir = std.fs.path.dirname(abs_file) orelse return allocator.dupe(u8, ".");

    var current = try allocator.dupe(u8, start_dir);

    while (true) {
        for (markers) |marker| {
            const candidate = try std.fs.path.join(allocator, &.{ current, marker });
            defer allocator.free(candidate);

            if (std.fs.cwd().access(candidate, .{})) |_| {
                return current;
            } else |_| {}
        }

        const parent = std.fs.path.dirname(current) orelse return current;
        if (std.mem.eql(u8, parent, current)) return current;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}
