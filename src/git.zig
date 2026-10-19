const std = @import("std");
const diff = @import("diff.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const GitRunner = struct {
    io: Io,

    pub fn init(io: Io) GitRunner {
        return .{ .io = io };
    }

    pub fn run(self: *const GitRunner, allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8) !?[]u8 {
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return null;

        var stdout_list: std.ArrayList(u8) = .empty;
        defer stdout_list.deinit(allocator);

        if (child.stdout) |file| {
            var buf: [4096]u8 = undefined;
            var iov = [_][]u8{&buf};
            while (true) {
                const amt = file.readStreaming(self.io, &iov) catch break;
                if (amt == 0) break;
                try stdout_list.appendSlice(allocator, buf[0..amt]);
            }
        }

        const term = child.wait(self.io) catch return null;
        switch (term) {
            .exited => |code| if (code != 0) return null,
            else => return null,
        }

        return try stdout_list.toOwnedSlice(allocator);
    }
};

pub fn urlDecode(allocator: Allocator, uri: []const u8) ![]const u8 {
    var path = uri;
    if (std.mem.startsWith(u8, path, "file://")) {
        path = path["file://".len..];
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '%' and i + 2 < path.len) {
            const hex = path[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch {
                try result.append(allocator, path[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, byte);
            i += 3;
        } else {
            try result.append(allocator, path[i]);
            i += 1;
        }
    }

    if (result.items.len >= 3 and result.items[0] == '/' and std.ascii.isAlphabetic(result.items[1]) and result.items[2] == ':') {
        const owned = try result.toOwnedSlice(allocator);
        defer allocator.free(owned);
        return try allocator.dupe(u8, owned[1..]);
    }

    return try result.toOwnedSlice(allocator);
}

pub fn cleanSummary(allocator: Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const prefix = "Merge pull request ";
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        return try std.fmt.allocPrint(allocator, "PR {s}", .{trimmed[prefix.len..]});
    }
    return try allocator.dupe(u8, trimmed);
}

pub fn dedentDiff(allocator: Allocator, lines: []const []const u8) ![]const []const u8 {
    if (lines.len == 0) {
        return try allocator.alloc([]const u8, 0);
    }

    var min_indent: usize = 9999;
    var found_indent = false;

    for (lines) |line| {
        if (line.len > 1 and (line[0] == '+' or line[0] == '-')) {
            const rest = line[1..];
            const trimmed = std.mem.trimStart(u8, rest, " \t");
            if (trimmed.len > 0) {
                const indent = rest.len - trimmed.len;
                if (indent < min_indent) {
                    min_indent = indent;
                    found_indent = true;
                }
            }
        }
    }

    if (!found_indent) min_indent = 0;

    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    for (lines) |line| {
        if (line.len > 1 and (line[0] == '+' or line[0] == '-')) {
            const sign = line[0];
            const rest = line[1..];
            var trimmed: []const u8 = undefined;
            if (rest.len >= min_indent and std.mem.trimStart(u8, rest[0..min_indent], " \t").len == 0) {
                trimmed = rest[min_indent..];
            } else {
                trimmed = std.mem.trimStart(u8, rest, " \t");
            }
            const formatted = try std.fmt.allocPrint(allocator, "{c} {s}", .{ sign, trimmed });
            try result.append(allocator, formatted);
        } else {
            try result.append(allocator, try allocator.dupe(u8, line));
        }
    }

    return try result.toOwnedSlice(allocator);
}

pub fn formatDiffBlock(allocator: Allocator, lines: []const []const u8, target_idx: ?usize) ![]const u8 {
    const dedented = try dedentDiff(allocator, lines);
    defer {
        for (dedented) |d| allocator.free(d);
        allocator.free(dedented);
    }

    var start_idx: usize = 0;
    var end_idx: usize = dedented.len;

    if (dedented.len > 10) {
        if (target_idx) |t_idx| {
            start_idx = if (t_idx > 3) t_idx - 3 else 0;
            end_idx = @min(dedented.len, t_idx + 4);

            while (end_idx - start_idx < 7 and (start_idx > 0 or end_idx < dedented.len)) {
                if (start_idx > 0) start_idx -= 1;
                if (end_idx < dedented.len and end_idx - start_idx < 7) end_idx += 1;
            }
        }
    }

    var diff_buf: std.ArrayList(u8) = .empty;
    errdefer diff_buf.deinit(allocator);

    try diff_buf.appendSlice(allocator, "```diff\n");
    if (start_idx > 0) {
        try diff_buf.appendSlice(allocator, "... (more lines)\n");
    }
    for (dedented[start_idx..end_idx]) |l| {
        try diff_buf.appendSlice(allocator, l);
        try diff_buf.append(allocator, '\n');
    }
    if (end_idx < dedented.len) {
        try diff_buf.appendSlice(allocator, "... (more lines)\n");
    }
    try diff_buf.appendSlice(allocator, "```");

    return try diff_buf.toOwnedSlice(allocator);
}

pub const PatchHunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    diff_lines: std.ArrayList([]const u8),
};

pub fn getHunkDiff(allocator: Allocator, raw_diff: []const u8, target_line: usize) !?[]const u8 {
    var hunks: std.ArrayList(PatchHunk) = .empty;
    defer {
        for (hunks.items) |*h| {
            for (h.diff_lines.items) |l| allocator.free(l);
            h.diff_lines.deinit(allocator);
        }
        hunks.deinit(allocator);
    }

    var lines_it = std.mem.splitScalar(u8, raw_diff, '\n');
    var current_hunk_idx: ?usize = null;

    while (lines_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@ ")) {
            const end_idx = std.mem.indexOfPos(u8, line, 3, " @@") orelse continue;
            const header_content = line[3..end_idx];

            var parts = std.mem.splitScalar(u8, header_content, ' ');
            const old_part = parts.next() orelse continue;
            const new_part = parts.next() orelse continue;

            if (!std.mem.startsWith(u8, old_part, "-") or !std.mem.startsWith(u8, new_part, "+")) continue;

            var old_start: usize = 1;
            var old_count: usize = 1;
            if (std.mem.indexOfScalar(u8, old_part[1..], ',')) |comma| {
                old_start = std.fmt.parseInt(usize, old_part[1 .. 1 + comma], 10) catch 1;
                old_count = std.fmt.parseInt(usize, old_part[2 + comma ..], 10) catch 1;
            } else {
                old_start = std.fmt.parseInt(usize, old_part[1..], 10) catch 1;
            }

            var new_start: usize = 1;
            var new_count: usize = 1;
            if (std.mem.indexOfScalar(u8, new_part[1..], ',')) |comma| {
                new_start = std.fmt.parseInt(usize, new_part[1 .. 1 + comma], 10) catch 1;
                new_count = std.fmt.parseInt(usize, new_part[2 + comma ..], 10) catch 1;
            } else {
                new_start = std.fmt.parseInt(usize, new_part[1..], 10) catch 1;
            }

            try hunks.append(allocator, .{
                .old_start = old_start,
                .old_count = old_count,
                .new_start = new_start,
                .new_count = new_count,
                .diff_lines = .empty,
            });
            current_hunk_idx = hunks.items.len - 1;
        } else if (current_hunk_idx) |idx| {
            if (line.len > 0 and (line[0] == '+' or line[0] == '-')) {
                try hunks.items[idx].diff_lines.append(allocator, try allocator.dupe(u8, line));
            }
        }
    }

    for (hunks.items) |hunk| {
        const n_start = hunk.new_start;
        const n_count = hunk.new_count;
        const n_end = if (n_count > 0) n_start + n_count - 1 else n_start;

        if ((n_count == 0 and target_line == n_start) or (n_count > 0 and target_line >= n_start and target_line <= n_end)) {
            var target_idx: ?usize = null;
            if (n_count > 0) {
                const offset = target_line - n_start;
                var plus_count: usize = 0;
                for (hunk.diff_lines.items, 0..) |line, i| {
                    if (line.len > 0 and line[0] == '+') {
                        if (plus_count == offset) {
                            target_idx = i;
                            break;
                        }
                        plus_count += 1;
                    }
                }
            } else {
                target_idx = 0;
            }

            return try formatDiffBlock(allocator, hunk.diff_lines.items, target_idx);
        }
    }

    return null;
}

pub const BlameInfo = struct {
    sha: []const u8 = "",
    orig_line: usize = 0,
    author: []const u8 = "",
    author_time: i64 = 0,
    summary: []const u8 = "",
    filename: []const u8 = "",

    fn shortSha(self: BlameInfo) []const u8 {
        return self.sha[0..@min(8, self.sha.len)];
    }
};

pub fn parseBlame(porcelain: []const u8) ?BlameInfo {
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    var words = std.mem.splitScalar(u8, lines.next() orelse return null, ' ');

    var info: BlameInfo = .{};
    info.sha = words.next() orelse return null;
    info.orig_line = std.fmt.parseInt(usize, words.next() orelse return null, 10) catch return null;

    while (lines.next()) |line| {
        if (std.mem.cutPrefix(u8, line, "author ")) |v| {
            info.author = v;
        } else if (std.mem.cutPrefix(u8, line, "author-time ")) |v| {
            info.author_time = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (std.mem.cutPrefix(u8, line, "summary ")) |v| {
            info.summary = v;
        } else if (std.mem.cutPrefix(u8, line, "filename ")) |v| {
            info.filename = v;
        }
    }
    return info;
}

fn formatDate(buf: *[16]u8, timestamp: i64) []const u8 {
    if (timestamp <= 0) return "";
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch "";
}

fn appendCommitLine(out: *std.ArrayList(u8), arena: Allocator, label: []const u8, info: BlameInfo) !void {
    try out.print(arena, "`{s}: {s} • {s}", .{ label, info.shortSha(), info.author });
    var date_buf: [16]u8 = undefined;
    const date = formatDate(&date_buf, info.author_time);
    if (date.len > 0) try out.print(arena, " • {s}", .{date});
    try out.append(arena, '`');

    const summary = try cleanSummary(arena, info.summary);
    if (summary.len > 0) try out.print(arena, "  \n  ↳ *{s}*", .{summary});
}

const RepoFile = struct {
    runner: *const GitRunner,
    dir: []const u8,
    name: []const u8,

    fn headContent(self: RepoFile, arena: Allocator) !?[]u8 {
        const spec = try std.fmt.allocPrint(arena, "HEAD:./{s}", .{self.name});
        return try self.runner.run(arena, &.{ "git", "cat-file", "blob", spec }, self.dir);
    }

    fn blameAtHead(self: RepoFile, arena: Allocator, old_line: usize) !?BlameInfo {
        const range = try std.fmt.allocPrint(arena, "{d},{d}", .{ old_line + 1, old_line + 1 });
        const out = try self.runner.run(arena, &.{ "git", "blame", "--porcelain", "-L", range, "HEAD", "--", self.name }, self.dir) orelse return null;
        return parseBlame(out);
    }
};

pub fn buildHover(arena: Allocator, runner: *const GitRunner, file_path: []const u8, text: []const u8, line: usize) !?[]const u8 {
    const file: RepoFile = .{
        .runner = runner,
        .dir = std.fs.path.dirname(file_path) orelse return null,
        .name = std.fs.path.basename(file_path),
    };

    const head_text = try file.headContent(arena) orelse return null;
    const old_lines = try diff.splitLines(arena, head_text);
    const new_lines = try diff.splitLines(arena, text);
    const hunks = try diff.diffLines(arena, old_lines, new_lines);

    if (diff.findHunk(hunks, old_lines, new_lines, line)) |hunk| {
        return try localChangeHover(arena, file, hunks, hunk, old_lines, new_lines, line);
    }

    const old_line = diff.oldLineFor(hunks, line);
    if (old_line >= old_lines.len) return null;
    return try committedHover(arena, file, old_line);
}

fn localChangeHover(
    arena: Allocator,
    file: RepoFile,
    hunks: []const diff.Hunk,
    hunk: diff.Hunk,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    line: usize,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var added: usize = 0;
    var deleted: usize = 0;
    for (hunks) |h| {
        added += h.new_count;
        deleted += h.old_count;
    }
    try out.print(arena, "`M {s} (+{d}/-{d})`\n", .{ file.name, added, deleted });

    var diff_lines: std.ArrayList([]const u8) = .empty;
    for (old_lines[hunk.old_start..][0..hunk.old_count]) |l| {
        try diff_lines.append(arena, try std.fmt.allocPrint(arena, "-{s}", .{l}));
    }
    for (new_lines[hunk.new_start..][0..hunk.new_count]) |l| {
        try diff_lines.append(arena, try std.fmt.allocPrint(arena, "+{s}", .{l}));
    }
    const offset = line - hunk.new_start;
    const target_idx = if (hunk.new_count == 0) 0 else hunk.old_count + offset;
    try out.appendSlice(arena, try formatDiffBlock(arena, diff_lines.items, target_idx));

    if (hunk.old_count > 0) {
        const old_line = hunk.old_start + @min(offset, hunk.old_count - 1);
        if (try file.blameAtHead(arena, old_line)) |info| {
            try out.append(arena, '\n');
            try appendCommitLine(&out, arena, "Prev", info);
        }
    }

    if (hunk.new_count == 0 and line < new_lines.len) {
        if (try file.blameAtHead(arena, hunk.old_start + hunk.old_count)) |info| {
            try out.appendSlice(arena, "\n\n");
            try appendCommitLine(&out, arena, "Blame", info);
        }
    }

    return try out.toOwnedSlice(arena);
}

fn committedHover(arena: Allocator, file: RepoFile, old_line: usize) !?[]const u8 {
    const info = try file.blameAtHead(arena, old_line) orelse return null;

    var out: std.ArrayList(u8) = .empty;

    const commit_path = try std.fmt.allocPrint(arena, ":/{s}", .{info.filename});
    if (try file.runner.run(arena, &.{ "git", "show", "-U0", "--no-color", info.sha, "--", commit_path }, file.dir)) |patch| {
        if (try getHunkDiff(arena, patch, info.orig_line)) |block| {
            try out.print(arena, "{s}\n", .{block});
        }
    }

    try appendCommitLine(&out, arena, "Blame", info);
    return try out.toOwnedSlice(arena);
}

test "urlDecode Unix and Windows paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const unix_path = try urlDecode(allocator, "file:///home/user/project/file.zig");
    defer allocator.free(unix_path);
    try testing.expectEqualStrings("/home/user/project/file.zig", unix_path);

    const space_path = try urlDecode(allocator, "file:///my%20folder/test%20file.zig");
    defer allocator.free(space_path);
    try testing.expectEqualStrings("/my folder/test file.zig", space_path);

    const win_path = try urlDecode(allocator, "file:///C:/Users/Developer/main.zig");
    defer allocator.free(win_path);
    try testing.expectEqualStrings("C:/Users/Developer/main.zig", win_path);
}

test "cleanSummary PR and normal messages" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const pr_msg = try cleanSummary(allocator, "Merge pull request #12 from branch");
    defer allocator.free(pr_msg);
    try testing.expectEqualStrings("PR #12 from branch", pr_msg);

    const normal_msg = try cleanSummary(allocator, "  Fix issue with LSP hover  \n");
    defer allocator.free(normal_msg);
    try testing.expectEqualStrings("Fix issue with LSP hover", normal_msg);
}

test "dedentDiff indentation and empty lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const empty = try dedentDiff(allocator, &.{});
    defer allocator.free(empty);
    try testing.expectEqual(0, empty.len);

    const input = [_][]const u8{
        "-    pub fn oldFn() void {",
        "+    pub fn newFn() void {",
        "+        doSomething();",
        "+    }",
    };
    const dedented = try dedentDiff(allocator, &input);
    defer {
        for (dedented) |d| allocator.free(d);
        allocator.free(dedented);
    }

    try testing.expectEqual(4, dedented.len);
    try testing.expectEqualStrings("- pub fn oldFn() void {", dedented[0]);
    try testing.expectEqualStrings("+ pub fn newFn() void {", dedented[1]);
    try testing.expectEqualStrings("+     doSomething();", dedented[2]);
    try testing.expectEqualStrings("+ }", dedented[3]);
}

test "parseBlame reads porcelain header fields" {
    const testing = std.testing;

    const porcelain =
        \\d6dcc2d8db74b1d5b2c3c42beb2cd389f8659d20 7 3 1
        \\author Tester
        \\author-mail <t@t>
        \\author-time 1792059801
        \\summary add sub
        \\filename sub/b.txt
    ;
    const info = parseBlame(porcelain) orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("d6dcc2d8", info.shortSha());
    try testing.expectEqual(7, info.orig_line);
    try testing.expectEqualStrings("Tester", info.author);
    try testing.expectEqual(1792059801, info.author_time);
    try testing.expectEqualStrings("add sub", info.summary);
    try testing.expectEqualStrings("sub/b.txt", info.filename);
}
