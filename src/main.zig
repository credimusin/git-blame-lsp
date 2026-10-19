const std = @import("std");
const git = @import("git.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;
const Value = std.json.Value;

pub const MessageReader = struct {
    file: File,
    io: Io,
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub fn init(file: File, io: Io, allocator: Allocator) MessageReader {
        return .{ .file = file, .io = io, .allocator = allocator };
    }

    pub fn deinit(self: *MessageReader) void {
        self.buf.deinit(self.allocator);
    }

    pub fn nextMessage(self: *MessageReader) !?[]const u8 {
        while (true) {
            const available = self.buf.items[self.start..];

            var header_end: ?usize = null;
            var body_offset: usize = 0;

            if (std.mem.indexOf(u8, available, "\r\n\r\n")) |pos| {
                header_end = pos;
                body_offset = pos + 4;
            } else if (std.mem.indexOf(u8, available, "\n\n")) |pos| {
                header_end = pos;
                body_offset = pos + 2;
            }

            if (header_end) |_| {
                const header_slice = available[0..body_offset];
                var content_length: ?usize = null;

                var it = std.mem.splitScalar(u8, header_slice, '\n');
                while (it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                        const val_str = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                        content_length = std.fmt.parseInt(usize, val_str, 10) catch null;
                    }
                }

                if (content_length) |len| {
                    const total_needed = body_offset + len;
                    if (available.len >= total_needed) {
                        const body = available[body_offset..total_needed];
                        self.start += total_needed;
                        return body;
                    }
                }
            }

            if (self.start > 0) {
                const len = self.buf.items.len - self.start;
                std.mem.copyForwards(u8, self.buf.items[0..len], self.buf.items[self.start..]);
                self.buf.shrinkRetainingCapacity(len);
                self.start = 0;
            }

            try self.buf.ensureUnusedCapacity(self.allocator, 64 * 1024);
            var dest = [_][]u8{self.buf.unusedCapacitySlice()};
            const amt = try self.file.readStreaming(self.io, &dest);
            if (amt == 0) {
                return null;
            }
            self.buf.items.len += amt;
        }
    }
};

const Documents = struct {
    allocator: Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(self: *Documents) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    fn set(self: *Documents, uri: []const u8, text: []const u8) !void {
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        const entry = try self.map.getOrPut(self.allocator, uri);
        if (entry.found_existing) {
            self.allocator.free(entry.value_ptr.*);
        } else {
            entry.key_ptr.* = self.allocator.dupe(u8, uri) catch |err| {
                self.map.removeByPtr(entry.key_ptr);
                return err;
            };
        }
        entry.value_ptr.* = owned_text;
    }

    fn remove(self: *Documents, uri: []const u8) void {
        const kv = self.map.fetchRemove(uri) orelse return;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value);
    }

    fn get(self: *const Documents, uri: []const u8) ?[]const u8 {
        return self.map.get(uri);
    }
};

const Server = struct {
    io: Io,
    stdout: File,
    runner: git.GitRunner,
    documents: Documents,
};

fn sendResponse(io: Io, stdout: File, allocator: Allocator, response_json: []const u8) !void {
    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{response_json.len});
    defer allocator.free(header);

    try stdout.writeStreamingAll(io, header);
    try stdout.writeStreamingAll(io, response_json);
}

fn sendResult(server: *Server, arena: Allocator, id: Value, result_json: []const u8) !void {
    const id_str = try idToString(arena, id);
    const resp = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    try sendResponse(server.io, server.stdout, arena, resp);
}

pub fn jsonEscape(allocator: Allocator, text: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const hex_digits = "0123456789abcdef";

    for (text) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x08 => try list.appendSlice(allocator, "\\b"),
            0x0C => try list.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    const esc = [_]u8{ '\\', 'u', '0', '0', hex_digits[c >> 4], hex_digits[c & 0x0F] };
                    try list.appendSlice(allocator, &esc);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn idToString(allocator: Allocator, id_val: Value) ![]const u8 {
    switch (id_val) {
        .integer => |i| return try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .string => |s| {
            const escaped = try jsonEscape(allocator, s);
            defer allocator.free(escaped);
            return try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
        },
        else => return try allocator.dupe(u8, "null"),
    }
}

fn field(value: ?Value, key: []const u8) ?Value {
    const v = value orelse return null;
    if (v != .object) return null;
    return v.object.get(key);
}

fn stringField(value: ?Value, key: []const u8) ?[]const u8 {
    const v = field(value, key) orelse return null;
    return if (v == .string) v.string else null;
}

fn intField(value: ?Value, key: []const u8) ?i64 {
    const v = field(value, key) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn documentUri(params: ?Value) ?[]const u8 {
    return stringField(field(params, "textDocument"), "uri");
}

fn handleDidOpen(server: *Server, params: ?Value) !void {
    const uri = documentUri(params) orelse return;
    const text = stringField(field(params, "textDocument"), "text") orelse return;
    try server.documents.set(uri, text);
}

fn handleDidChange(server: *Server, params: ?Value) !void {
    const uri = documentUri(params) orelse return;
    const changes = field(params, "contentChanges") orelse return;
    if (changes != .array or changes.array.items.len == 0) return;
    const last = changes.array.items[changes.array.items.len - 1];
    const text = stringField(last, "text") orelse return;
    try server.documents.set(uri, text);
}

fn handleDidClose(server: *Server, params: ?Value) void {
    const uri = documentUri(params) orelse return;
    server.documents.remove(uri);
}

fn hoverText(server: *Server, arena: Allocator, params: ?Value) !?[]const u8 {
    const uri = documentUri(params) orelse return null;
    const line = intField(field(params, "position"), "line") orelse return null;
    if (line < 0) return null;

    const path = try git.urlDecode(arena, uri);
    const text = server.documents.get(uri) orelse
        (Io.Dir.cwd().readFileAlloc(server.io, path, arena, .limited(64 * 1024 * 1024)) catch return null);

    return try git.buildHover(arena, &server.runner, path, text, @intCast(line));
}

fn handleHover(server: *Server, arena: Allocator, id: Value, params: ?Value) !void {
    const text = try hoverText(server, arena, params) orelse return sendResult(server, arena, id, "null");
    const escaped = try jsonEscape(arena, text);
    const result = try std.fmt.allocPrint(arena, "{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"{s}\"}}}}", .{escaped});
    try sendResult(server, arena, id, result);
}

const Flow = enum { keep_going, exit };

fn handleMessage(server: *Server, arena: Allocator, root: Value) !Flow {
    const method = stringField(root, "method") orelse return .keep_going;
    const params = field(root, "params");
    const id = field(root, "id");

    if (std.mem.eql(u8, method, "exit")) return .exit;
    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        try handleDidOpen(server, params);
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        try handleDidChange(server, params);
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        handleDidClose(server, params);
    } else if (id) |req_id| {
        if (std.mem.eql(u8, method, "initialize")) {
            try sendResult(server, arena, req_id, "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true}}");
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try handleHover(server, arena, req_id, params);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try sendResult(server, arena, req_id, "null");
        } else {
            const id_str = try idToString(arena, req_id);
            const resp = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id_str});
            try sendResponse(server.io, server.stdout, arena, resp);
        }
    }
    return .keep_going;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var reader = MessageReader.init(File.stdin(), io, allocator);
    defer reader.deinit();

    var server: Server = .{
        .io = io,
        .stdout = File.stdout(),
        .runner = git.GitRunner.init(io),
        .documents = .{ .allocator = allocator },
    };
    defer server.documents.deinit();

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const msg_body = (reader.nextMessage() catch break) orelse break;

        const parsed = std.json.parseFromSlice(Value, arena_alloc, msg_body, .{}) catch continue;
        if (try handleMessage(&server, arena_alloc, parsed.value) == .exit) break;
    }
}

test "jsonEscape special and control characters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "Hello \"world\" \\\n\r\t\x00\x1f";
    const escaped = try jsonEscape(allocator, input);
    defer allocator.free(escaped);

    try testing.expectEqualStrings("Hello \\\"world\\\" \\\\\\n\\r\\t\\u0000\\u001f", escaped);
}

test "idToString integer, string, and null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const id_int = try idToString(allocator, .{ .integer = 42 });
    defer allocator.free(id_int);
    try testing.expectEqualStrings("42", id_int);

    const id_str = try idToString(allocator, .{ .string = "req-1" });
    defer allocator.free(id_str);
    try testing.expectEqualStrings("\"req-1\"", id_str);

    const id_null = try idToString(allocator, .null);
    defer allocator.free(id_null);
    try testing.expectEqualStrings("null", id_null);
}
