const std = @import("std");
const git = @import("git.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = std.Io.File;

pub const MessageReader = struct {
    file: File,
    io: Io,
    buf: [128 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn init(file: File, io: Io) MessageReader {
        return .{ .file = file, .io = io };
    }

    pub fn nextMessage(self: *MessageReader) !?[]const u8 {
        while (true) {
            const available = self.buf[self.start..self.end];

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
                        if (self.start == self.end) {
                            self.start = 0;
                            self.end = 0;
                        }
                        return body;
                    }
                }
            }

            if (self.start > 0) {
                const len = self.end - self.start;
                std.mem.copyForwards(u8, self.buf[0..len], self.buf[self.start..self.end]);
                self.start = 0;
                self.end = len;
            }

            if (self.end == self.buf.len) {
                return error.BufferOverflow;
            }

            var dest = [_][]u8{self.buf[self.end..]};
            const amt = try self.file.readStreaming(self.io, &dest);
            if (amt == 0) {
                return null;
            }
            self.end += amt;
        }
    }
};

fn sendResponse(io: Io, stdout: File, allocator: Allocator, response_json: []const u8) !void {
    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{response_json.len});
    defer allocator.free(header);

    try stdout.writeStreamingAll(io, header);
    try stdout.writeStreamingAll(io, response_json);
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

pub fn idToString(allocator: Allocator, id_val: std.json.Value) ![]const u8 {
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const stdin = File.stdin();
    const stdout = File.stdout();

    var reader = MessageReader.init(stdin, io);
    const git_runner = git.GitRunner.init(allocator, io);

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const msg_body = (reader.nextMessage() catch break) orelse break;

        const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, msg_body, .{}) catch continue;
        const root = parsed.value;

        if (root != .object) continue;

        const method_val = root.object.get("method");
        const id_val = root.object.get("id");

        if (method_val) |m| {
            if (m == .string) {
                const method = m.string;

                if (std.mem.eql(u8, method, "initialize")) {
                    if (id_val) |id| {
                        const id_str = try idToString(arena_alloc, id);
                        const resp = try std.fmt.allocPrint(arena_alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"capabilities\":{{\"textDocumentSync\":0,\"hoverProvider\":true}}}}}}", .{id_str});
                        try sendResponse(io, stdout, arena_alloc, resp);
                    }
                } else if (std.mem.eql(u8, method, "textDocument/hover")) {
                    if (id_val) |id| {
                        var hover_text: ?[]const u8 = null;

                        if (root.object.get("params")) |params| {
                            if (params == .object) {
                                const uri_val = params.object.get("textDocument");
                                const pos_val = params.object.get("position");

                                if (uri_val != null and uri_val.? == .object and pos_val != null and pos_val.? == .object) {
                                    const raw_uri = uri_val.?.object.get("uri");
                                    const line_num = pos_val.?.object.get("line");

                                    if (raw_uri != null and raw_uri.? == .string and line_num != null and line_num.? == .integer) {
                                        const line_int = line_num.?.integer;
                                        if (line_int >= 0) {
                                            const decoded_path = try git.urlDecode(arena_alloc, raw_uri.?.string);
                                            const line_1based: usize = @intCast(line_int + 1);
                                            hover_text = try git.getGitBlameAndDiff(arena_alloc, &git_runner, decoded_path, line_1based);
                                        }
                                    }
                                }
                            }
                        }

                        const id_str = try idToString(arena_alloc, id);
                        if (hover_text) |ht| {
                            const escaped = try jsonEscape(arena_alloc, ht);
                            const resp = try std.fmt.allocPrint(arena_alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"{s}\"}}}}}}", .{ id_str, escaped });
                            try sendResponse(io, stdout, arena_alloc, resp);
                        } else {
                            const resp = try std.fmt.allocPrint(arena_alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
                            try sendResponse(io, stdout, arena_alloc, resp);
                        }
                    }
                } else if (std.mem.eql(u8, method, "shutdown")) {
                    if (id_val) |id| {
                        const id_str = try idToString(arena_alloc, id);
                        const resp = try std.fmt.allocPrint(arena_alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
                        try sendResponse(io, stdout, arena_alloc, resp);
                    }
                } else if (std.mem.eql(u8, method, "exit")) {
                    break;
                } else {
                    // Unknown method request: return standard JSON-RPC 2.0 Method Not Found error (-32601)
                    if (id_val) |id| {
                        const id_str = try idToString(arena_alloc, id);
                        const resp = try std.fmt.allocPrint(arena_alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id_str});
                        try sendResponse(io, stdout, arena_alloc, resp);
                    }
                }
            }
        }
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
