const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,

    fn coversLine(self: Hunk, line: usize) bool {
        if (self.new_count == 0) return line == self.new_start;
        return line >= self.new_start and line < self.new_start + self.new_count;
    }

    fn isPure(self: Hunk) bool {
        return self.old_count == 0 or self.new_count == 0;
    }
};

const Op = enum { equal, delete, insert };

const max_edits = 1000;

pub fn splitLines(allocator: Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(allocator, std.mem.trimEnd(u8, line, "\r"));
    }
    if (text.len == 0 or text[text.len - 1] == '\n') {
        _ = lines.pop();
    }
    return try lines.toOwnedSlice(allocator);
}

pub fn diffLines(allocator: Allocator, old: []const []const u8, new: []const []const u8) ![]Hunk {
    var prefix: usize = 0;
    while (prefix < old.len and prefix < new.len and std.mem.eql(u8, old[prefix], new[prefix])) {
        prefix += 1;
    }

    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and
        std.mem.eql(u8, old[old.len - 1 - suffix], new[new.len - 1 - suffix]))
    {
        suffix += 1;
    }

    const old_mid = old[prefix .. old.len - suffix];
    const new_mid = new[prefix .. new.len - suffix];

    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(allocator);

    if (old_mid.len == 0 and new_mid.len == 0) {
        return try hunks.toOwnedSlice(allocator);
    }

    const script = if (old_mid.len == 0 or new_mid.len == 0) null else try editScript(allocator, old_mid, new_mid);
    const ops = script orelse {
        try hunks.append(allocator, .{ .old_start = prefix, .old_count = old_mid.len, .new_start = prefix, .new_count = new_mid.len });
        return try hunks.toOwnedSlice(allocator);
    };
    defer allocator.free(ops);

    var old_i = prefix;
    var new_i = prefix;
    var open: ?Hunk = null;
    for (ops) |op| {
        if (op == .equal) {
            if (open) |h| try hunks.append(allocator, h);
            open = null;
            old_i += 1;
            new_i += 1;
            continue;
        }
        if (open == null) {
            open = .{ .old_start = old_i, .old_count = 0, .new_start = new_i, .new_count = 0 };
        }
        if (op == .delete) {
            open.?.old_count += 1;
            old_i += 1;
        } else {
            open.?.new_count += 1;
            new_i += 1;
        }
    }
    if (open) |h| try hunks.append(allocator, h);

    return try hunks.toOwnedSlice(allocator);
}

fn editScript(allocator: Allocator, a: []const []const u8, b: []const []const u8) !?[]Op {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);

    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |v| allocator.free(v);
        trace.deinit(allocator);
    }

    var d: isize = 0;
    search: while (d <= max_edits) : (d += 1) {
        const v = try allocator.alloc(isize, @intCast(2 * d + 1));
        trace.append(allocator, v) catch |err| {
            allocator.free(v);
            return err;
        };

        var k = -d;
        while (k <= d) : (k += 2) {
            var x: isize = if (d == 0) 0 else nextX(trace.items[@intCast(d - 1)], d, k);
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[@intCast(k + d)] = x;
            if (x >= n and y >= m) break :search;
        }
    } else return null;

    var ops: std.ArrayList(Op) = .empty;
    errdefer ops.deinit(allocator);

    var x = n;
    var y = m;
    while (d > 0) : (d -= 1) {
        const prev = trace.items[@intCast(d - 1)];
        const k = x - y;
        const down = movesDown(prev, d, k);
        const prev_k = if (down) k + 1 else k - 1;
        const prev_x = at(prev, d - 1, prev_k);
        const prev_y = prev_x - prev_k;

        while (x > prev_x and y > prev_y) {
            try ops.append(allocator, .equal);
            x -= 1;
            y -= 1;
        }
        try ops.append(allocator, if (down) .insert else .delete);
        x = prev_x;
        y = prev_y;
    }
    while (x > 0) : (x -= 1) {
        try ops.append(allocator, .equal);
    }

    std.mem.reverse(Op, ops.items);
    return try ops.toOwnedSlice(allocator);
}

fn at(v: []const isize, d: isize, k: isize) isize {
    return v[@intCast(k + d)];
}

// `prev` holds step d - 1. Down = insertion (comes from diagonal k + 1), right = deletion.
fn movesDown(prev: []const isize, d: isize, k: isize) bool {
    if (k == -d) return true;
    if (k == d) return false;
    return at(prev, d - 1, k - 1) < at(prev, d - 1, k + 1);
}

fn nextX(prev: []const isize, d: isize, k: isize) isize {
    if (movesDown(prev, d, k)) return at(prev, d - 1, k + 1);
    return at(prev, d - 1, k - 1) + 1;
}

pub fn findHunk(hunks: []const Hunk, old: []const []const u8, new: []const []const u8, line: usize) ?Hunk {
    for (hunks) |h| {
        if (h.coversLine(line)) return h;
    }
    for (hunks) |h| {
        if (slideTo(h, old, new, line)) |slid| return slid;
    }
    return null;
}

fn slideTo(hunk: Hunk, old: []const []const u8, new: []const []const u8, line: usize) ?Hunk {
    if (!hunk.isPure()) return null;

    var h = hunk;
    while (!h.coversLine(line)) {
        const next = if (line < h.new_start) slideUp(h, old, new) else slideDown(h, old, new);
        h = next orelse return null;
    }
    return h;
}

const Block = struct {
    lines: []const []const u8,
    start: usize,
    count: usize,
};

fn pureBlock(h: Hunk, old: []const []const u8, new: []const []const u8) Block {
    if (h.new_count == 0) return .{ .lines = old, .start = h.old_start, .count = h.old_count };
    return .{ .lines = new, .start = h.new_start, .count = h.new_count };
}

// A pure block may move up by one line when the line above equals its last line.
fn slideUp(h: Hunk, old: []const []const u8, new: []const []const u8) ?Hunk {
    if (h.old_start == 0 or h.new_start == 0) return null;
    const b = pureBlock(h, old, new);
    if (!std.mem.eql(u8, b.lines[b.start - 1], b.lines[b.start + b.count - 1])) return null;
    return .{ .old_start = h.old_start - 1, .old_count = h.old_count, .new_start = h.new_start - 1, .new_count = h.new_count };
}

// ...and down by one line when the line below equals its first line.
fn slideDown(h: Hunk, old: []const []const u8, new: []const []const u8) ?Hunk {
    const b = pureBlock(h, old, new);
    if (b.start + b.count >= b.lines.len) return null;
    if (!std.mem.eql(u8, b.lines[b.start], b.lines[b.start + b.count])) return null;
    return .{ .old_start = h.old_start + 1, .old_count = h.old_count, .new_start = h.new_start + 1, .new_count = h.new_count };
}

// Maps a line that is not inside any hunk to its 0-based line number in the old text.
pub fn oldLineFor(hunks: []const Hunk, line: usize) usize {
    var old_line = line;
    for (hunks) |h| {
        if (h.new_start + h.new_count > line) break;
        old_line = old_line + h.old_count - h.new_count;
    }
    return old_line;
}

test "splitLines drops the final newline and CR" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cases = [_]struct { name: []const u8, text: []const u8, lines: []const []const u8 }{
        .{ .name = "empty text", .text = "", .lines = &.{} },
        .{ .name = "no final newline", .text = "a\nb", .lines = &.{ "a", "b" } },
        .{ .name = "final newline", .text = "a\nb\n", .lines = &.{ "a", "b" } },
        .{ .name = "trailing empty line", .text = "a\n\n", .lines = &.{ "a", "" } },
        .{ .name = "crlf", .text = "a\r\nb\r\n", .lines = &.{ "a", "b" } },
    };

    for (cases) |case| {
        const lines = try splitLines(allocator, case.text);
        defer allocator.free(lines);

        errdefer std.debug.print("case: {s}\n", .{case.name});
        try testing.expectEqual(case.lines.len, lines.len);
        for (case.lines, lines) |expected, actual| {
            try testing.expectEqualStrings(expected, actual);
        }
    }
}

test "diffLines finds deletions, insertions and modifications" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cases = [_]struct { name: []const u8, old: []const []const u8, new: []const []const u8, hunks: []const Hunk }{
        .{ .name = "identical", .old = &.{ "a", "b" }, .new = &.{ "a", "b" }, .hunks = &.{} },
        .{
            .name = "deleted middle line",
            .old = &.{ "a", "b", "c" },
            .new = &.{ "a", "c" },
            .hunks = &.{.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 0 }},
        },
        .{
            .name = "deleted last line",
            .old = &.{ "a", "b" },
            .new = &.{"a"},
            .hunks = &.{.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 0 }},
        },
        .{
            .name = "inserted first line",
            .old = &.{"a"},
            .new = &.{ "x", "a" },
            .hunks = &.{.{ .old_start = 0, .old_count = 0, .new_start = 0, .new_count = 1 }},
        },
        .{
            .name = "modified line",
            .old = &.{ "a", "b", "c" },
            .new = &.{ "a", "B", "c" },
            .hunks = &.{.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1 }},
        },
        .{
            .name = "modification and deletion apart",
            .old = &.{ "a", "b", "c", "d", "e" },
            .new = &.{ "a", "B", "c", "e" },
            .hunks = &.{
                .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1 },
                .{ .old_start = 3, .old_count = 1, .new_start = 3, .new_count = 0 },
            },
        },
    };

    for (cases) |case| {
        const hunks = try diffLines(allocator, case.old, case.new);
        defer allocator.free(hunks);

        errdefer std.debug.print("case: {s}\n", .{case.name});
        try testing.expectEqualSlices(Hunk, case.hunks, hunks);
    }
}

test "findHunk matches the line Helix marks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cases = [_]struct { name: []const u8, old: []const []const u8, new: []const []const u8, line: usize, hunk: ?Hunk }{
        .{
            .name = "line after a deletion",
            .old = &.{ "a", "b", "c" },
            .new = &.{ "a", "c" },
            .line = 1,
            .hunk = .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 0 },
        },
        .{
            .name = "line before a deletion",
            .old = &.{ "a", "b", "c" },
            .new = &.{ "a", "c" },
            .line = 0,
            .hunk = null,
        },
        .{
            .name = "deletion at end of file",
            .old = &.{ "a", "b" },
            .new = &.{"a"},
            .line = 1,
            .hunk = .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 0 },
        },
        .{
            .name = "deleted block slid up over a blank line",
            .old = &.{ "}", "", "fn a", "}", "", "fn b" },
            .new = &.{ "}", "", "fn b" },
            .line = 1,
            .hunk = .{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 0 },
        },
        .{
            .name = "inserted blank line slid up",
            .old = &.{ "x", "", "y" },
            .new = &.{ "x", "", "", "y" },
            .line = 1,
            .hunk = .{ .old_start = 1, .old_count = 0, .new_start = 1, .new_count = 1 },
        },
        .{
            .name = "modification does not slide",
            .old = &.{ "a", "a", "b" },
            .new = &.{ "a", "a", "B" },
            .line = 1,
            .hunk = null,
        },
    };

    for (cases) |case| {
        const hunks = try diffLines(allocator, case.old, case.new);
        defer allocator.free(hunks);

        errdefer std.debug.print("case: {s}\n", .{case.name});
        try testing.expectEqual(case.hunk, findHunk(hunks, case.old, case.new, case.line));
    }
}

test "oldLineFor skips hunks above the line" {
    const testing = std.testing;

    const hunks = [_]Hunk{
        .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1 },
        .{ .old_start = 3, .old_count = 1, .new_start = 3, .new_count = 0 },
        .{ .old_start = 5, .old_count = 0, .new_start = 4, .new_count = 2 },
    };

    try testing.expectEqual(0, oldLineFor(&hunks, 0));
    try testing.expectEqual(2, oldLineFor(&hunks, 2));
    try testing.expectEqual(4, oldLineFor(&hunks, 3));
    try testing.expectEqual(5, oldLineFor(&hunks, 6));
}
