const std = @import("std");
const presets = @import("presets.zig");

const max_lsp_open_file_bytes: usize = 32 * 1024 * 1024;

pub const DiagnosticsSnapshot = struct {
    count: usize,
    first_line: ?usize,
    first_message: []const u8,
    first_symbol: []const u8,
    lines: []const usize,
    pending_requests: usize,
};

const ChangeMode = enum {
    full,
    incremental,
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
    enabled: bool,
    trace_enabled: bool,
    session_ready: bool,
    initialize_request_id: ?u64,
    diagnostics_request_id: ?u64,
    change_mode: ChangeMode,
    supports_pull_diagnostics: bool,
    did_save_pulse_interval_ns: i128,
    next_did_save_pulse_ns: i128,
    bootstrap_saved: bool,
    pending_open_text: ?[]u8,
    recv_buffer: std.array_list.Managed(u8),
    diag_count: usize,
    diag_first_line: ?usize,
    diag_first_message: std.array_list.Managed(u8),
    diag_first_symbol: std.array_list.Managed(u8),
    diag_lines: std.array_list.Managed(usize),

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
            .enabled = false,
            .trace_enabled = std.process.hasEnvVarConstant("ZICRO_LSP_TRACE"),
            .session_ready = false,
            .initialize_request_id = null,
            .diagnostics_request_id = null,
            .change_mode = .full,
            .supports_pull_diagnostics = true,
            .did_save_pulse_interval_ns = 64 * std.time.ns_per_ms,
            .next_did_save_pulse_ns = 0,
            .bootstrap_saved = false,
            .pending_open_text = null,
            .recv_buffer = std.array_list.Managed(u8).init(allocator),
            .diag_count = 0,
            .diag_first_line = null,
            .diag_first_message = std.array_list.Managed(u8).init(allocator),
            .diag_first_symbol = std.array_list.Managed(u8).init(allocator),
            .diag_lines = std.array_list.Managed(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.stop();
        self.recv_buffer.deinit();
        self.diag_first_message.deinit();
        self.diag_first_symbol.deinit();
        self.diag_lines.deinit();
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
        self.session_ready = false;
        self.initialize_request_id = null;
        self.diagnostics_request_id = null;
        self.change_mode = .full;
        self.supports_pull_diagnostics = true;
        self.next_did_save_pulse_ns = 0;
        self.bootstrap_saved = false;
        self.server_name = "off";
        self.recv_buffer.clearRetainingCapacity();
        if (self.pending_open_text) |text| {
            self.allocator.free(text);
            self.pending_open_text = null;
        }
        _ = self.setDiagnostics(0, null, "", &[_]usize{});
    }

    pub fn startForFile(self: *Client, file_path: []const u8) !void {
        self.stop();

        const server = presets.forPath(file_path) orelse return;

        const abs_file = try absolutePath(self.allocator, file_path);
        defer self.allocator.free(abs_file);

        const root_path = try findRootDir(self.allocator, abs_file, server.root_markers);
        defer self.allocator.free(root_path);

        const argv = try resolveArgv(self.allocator, root_path, server.command);
        defer freeArgv(self.allocator, argv);

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        self.child = child;
        self.enabled = true;
        self.session_ready = false;
        self.change_mode = .full;
        self.supports_pull_diagnostics = true;
        self.next_did_save_pulse_ns = 0;
        self.server_name = server.name;
        self.version = 1;

        if (self.document_uri) |uri| self.allocator.free(uri);
        if (self.root_uri) |uri| self.allocator.free(uri);

        self.document_uri = try toFileUri(self.allocator, abs_file);
        self.root_uri = try toFileUri(self.allocator, root_path);

        const text = try std.fs.cwd().readFileAlloc(self.allocator, file_path, max_lsp_open_file_bytes);
        if (self.pending_open_text) |pending| self.allocator.free(pending);
        self.pending_open_text = text;

        try self.sendInitialize();
    }

    pub fn poll(self: *Client) !bool {
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
        };
    }

    pub fn clearDiagnostics(self: *Client) void {
        _ = self.setDiagnostics(0, null, "", &[_]usize{});
    }

    pub fn setDidSavePulseDebounceMs(self: *Client, debounce_ms: u16) void {
        self.did_save_pulse_interval_ns = @as(i128, @intCast(debounce_ms)) * std.time.ns_per_ms;
        self.next_did_save_pulse_ns = 0;
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
        try self.maybeSendDidSavePulse();
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
        try self.maybeSendDidSavePulse();
        try self.requestDiagnostics();
    }

    pub fn supportsIncrementalSync(self: *const Client) bool {
        return self.enabled and self.session_ready and self.change_mode == .incremental;
    }

    pub fn didSave(self: *Client) !void {
        if (!self.enabled) return;
        if (!self.session_ready) return;
        try self.sendDidSaveNotification();
        self.next_did_save_pulse_ns = std.time.nanoTimestamp() + self.did_save_pulse_interval_ns;
        try self.requestDiagnostics();
    }

    fn maybeSendDidSavePulse(self: *Client) !void {
        if (!self.enabled or !self.session_ready) return;
        if (self.did_save_pulse_interval_ns <= 0) return;
        if (!std.mem.eql(u8, self.server_name, "typescript")) return;

        const now = std.time.nanoTimestamp();
        if (now < self.next_did_save_pulse_ns) return;

        self.next_did_save_pulse_ns = now + self.did_save_pulse_interval_ns;
        try self.sendDidSaveNotification();
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
        self.pending_requests += 1;
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

        while (true) {
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

        const method_value = parsed.value.object.get("method") orelse return false;
        if (method_value != .string) return false;

        if (try self.handleServerRequest(parsed.value.object, method_value.string)) {
            return false;
        }

        if (!std.mem.eql(u8, method_value.string, "textDocument/publishDiagnostics")) return false;

        const params_value = parsed.value.object.get("params") orelse return false;
        if (params_value != .object) return false;

        const diagnostics_value = params_value.object.get("diagnostics") orelse return false;
        if (diagnostics_value != .array) return false;

        const diagnostics_items = diagnostics_value.array.items;
        return self.setDiagnosticsFromItems(diagnostics_items);
    }

    fn handleServerRequest(self: *Client, object: std.json.ObjectMap, method: []const u8) !bool {
        const id_value = object.get("id") orelse return false;
        if (id_value != .integer) return false;
        if (id_value.integer < 0) return false;
        const id: u64 = @intCast(id_value.integer);

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
        if (self.pending_requests > 0) self.pending_requests -= 1;
        if (object.get("error")) |error_value| {
            if (error_value != .null) {
                self.stop();
                return true;
            }
        }

        self.change_mode = parseChangeModeFromInitializeResponse(object);

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
    }

    fn handleDiagnosticResponse(self: *Client, object: std.json.ObjectMap) !bool {
        const request_id = self.diagnostics_request_id orelse return false;
        const id_value = object.get("id") orelse return false;
        if (id_value != .integer) return false;
        if (id_value.integer < 0) return false;
        const response_id: u64 = @intCast(id_value.integer);
        if (response_id != request_id) return false;

        self.diagnostics_request_id = null;
        if (self.pending_requests > 0) self.pending_requests -= 1;

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

    fn sendResponseNull(self: *Client, id: u64) !void {
        const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .result = @as(?u8, null),
        }, .{});
        defer self.allocator.free(payload);
        try self.sendPayload(payload);
    }

    fn sendResponseEmptyArray(self: *Client, id: u64) !void {
        var payload = std.array_list.Managed(u8).init(self.allocator);
        defer payload.deinit();
        try payload.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{id});
        try self.sendPayload(payload.items);
    }

    fn sendResponseNullArray(self: *Client, id: u64, count: usize) !void {
        var payload = std.array_list.Managed(u8).init(self.allocator);
        defer payload.deinit();

        try payload.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (i > 0) try payload.append(',');
            try payload.appendSlice("null");
        }
        try payload.appendSlice("]}");
        try self.sendPayload(payload.items);
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

fn resolveArgv(allocator: std.mem.Allocator, root_path: []const u8, command: []const []const u8) ![]const []const u8 {
    var argv = try allocator.alloc([]const u8, command.len);

    argv[0] = try resolveBinary(allocator, root_path, command[0]);
    var i: usize = 1;
    while (i < command.len) : (i += 1) {
        argv[i] = try allocator.dupe(u8, command[i]);
    }

    return argv;
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
