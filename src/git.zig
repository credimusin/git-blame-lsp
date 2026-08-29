const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const GitRunner = struct {
    allocator: Allocator,
    io: Io,

    pub fn init(allocator: Allocator, io: Io) GitRunner {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn run(self: *const GitRunner, argv: []const []const u8, cwd: ?[]const u8) !?[]u8 {
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return null;

        var stdout_list: std.ArrayList(u8) = .empty;
        errdefer stdout_list.deinit(self.allocator);

        if (child.stdout) |file| {
            var buf: [4096]u8 = undefined;
            var iov = [_][]u8{&buf};
            while (true) {
                const amt = file.readStreaming(self.io, &iov) catch break;
                if (amt == 0) break;
                try stdout_list.appendSlice(self.allocator, buf[0..amt]);
            }
        }

        const term = child.wait(self.io) catch return null;
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    stdout_list.deinit(self.allocator);
                    return null;
                }
            },
            else => {
                stdout_list.deinit(self.allocator);
                return null;
            },
        }

        return try stdout_list.toOwnedSlice(self.allocator);
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

pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    diff_lines: std.ArrayList([]const u8),
};

pub fn getHunkDiff(allocator: Allocator, runner: *const GitRunner, file_path: []const u8, dir_path: []const u8, target_line: usize) !?[]const u8 {
    const raw_diff = (try runner.run(&.{ "git", "diff", "HEAD", "-U0", "--no-color", file_path }, dir_path)) orelse
        (try runner.run(&.{ "git", "diff", "-U0", "--no-color", file_path }, dir_path)) orelse return null;
    defer allocator.free(raw_diff);

    var hunks: std.ArrayList(Hunk) = .empty;
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
            const dedented = try dedentDiff(allocator, hunk.diff_lines.items);
            defer {
                for (dedented) |d| allocator.free(d);
                allocator.free(dedented);
            }

            var diff_buf: std.ArrayList(u8) = .empty;
            errdefer diff_buf.deinit(allocator);

            try diff_buf.appendSlice(allocator, "```diff\n");
            const max_lines = @min(dedented.len, 20);
            for (dedented[0..max_lines]) |l| {
                try diff_buf.appendSlice(allocator, l);
                try diff_buf.append(allocator, '\n');
            }
            if (dedented.len > 20) {
                try diff_buf.appendSlice(allocator, "... (more lines)\n");
            }
            try diff_buf.appendSlice(allocator, "```");

            return try diff_buf.toOwnedSlice(allocator);
        }
    }

    return null;
}

pub fn getStatusAndStats(allocator: Allocator, runner: *const GitRunner, file_path: []const u8, dir_path: []const u8) ![]const u8 {
    const fname = std.fs.path.basename(file_path);
    var status_buf: [4]u8 = undefined;
    var status_code: []const u8 = "M";
    var added: usize = 0;
    var deleted: usize = 0;

    if (try runner.run(&.{ "git", "status", "--porcelain", file_path }, dir_path)) |st| {
        defer allocator.free(st);
        const trimmed = std.mem.trim(u8, st, " \t\r\n");
        if (trimmed.len >= 1) {
            const code_slice = std.mem.trim(u8, trimmed[0..@min(2, trimmed.len)], " ");
            const len = @min(code_slice.len, status_buf.len);
            @memcpy(status_buf[0..len], code_slice[0..len]);
            status_code = status_buf[0..len];
        }
    }

    const numstat_raw = (try runner.run(&.{ "git", "diff", "HEAD", "--numstat", file_path }, dir_path)) orelse
        (try runner.run(&.{ "git", "diff", "--numstat", file_path }, dir_path));

    if (numstat_raw) |numstat| {
        defer allocator.free(numstat);
        var parts = std.mem.splitScalar(u8, std.mem.trim(u8, numstat, " \t\r\n"), '\t');
        if (parts.next()) |a_str| {
            if (parts.next()) |d_str| {
                added = std.fmt.parseInt(usize, a_str, 10) catch 0;
                deleted = std.fmt.parseInt(usize, d_str, 10) catch 0;
            }
        }
    }

    return try std.fmt.allocPrint(allocator, "{s} {s} (+{d}/-{d})", .{ status_code, fname, added, deleted });
}

pub fn getGitBlameAndDiff(allocator: Allocator, runner: *const GitRunner, file_path: []const u8, line_no: usize) !?[]const u8 {
    const dir_path = std.fs.path.dirname(file_path) orelse return null;

    const hunk_diff = try getHunkDiff(allocator, runner, file_path, dir_path, line_no);
    defer if (hunk_diff) |hd| allocator.free(hd);

    const line_arg = try std.fmt.allocPrint(allocator, "{d},{d}", .{ line_no, line_no });
    defer allocator.free(line_arg);

    const blame_out = try runner.run(&.{ "git", "blame", "-L", line_arg, "--porcelain", file_path }, dir_path);
    defer if (blame_out) |b| allocator.free(b);

    var sha: []const u8 = "";
    var author: []const u8 = "";
    var date_buf: [16]u8 = undefined;
    var author_time: []const u8 = "";
    var summary: []const u8 = "";
    var prev_sha: []const u8 = "";

    if (blame_out) |raw_blame| {
        var lines_it = std.mem.splitScalar(u8, raw_blame, '\n');
        while (lines_it.next()) |line| {
            if (sha.len == 0 and line.len > 0) {
                var words = std.mem.splitScalar(u8, line, ' ');
                if (words.next()) |s| {
                    sha = s[0..@min(8, s.len)];
                }
            } else if (std.mem.startsWith(u8, line, "author ")) {
                author = std.mem.trim(u8, line[7..], " \t\r\n");
            } else if (std.mem.startsWith(u8, line, "author-time ")) {
                const ts_str = std.mem.trim(u8, line[12..], " \t\r\n");
                const ts = std.fmt.parseInt(i64, ts_str, 10) catch 0;
                if (ts > 0) {
                    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
                    const epoch_day = epoch_seconds.getEpochDay();
                    const year_day = epoch_day.calculateYearDay();
                    const month_day = year_day.calculateMonthDay();
                    author_time = std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                        year_day.year,
                        month_day.month.numeric(),
                        month_day.day_index + 1,
                    }) catch "";
                }
            } else if (std.mem.startsWith(u8, line, "summary ")) {
                summary = std.mem.trim(u8, line[8..], " \t\r\n");
            } else if (std.mem.startsWith(u8, line, "previous ")) {
                var parts = std.mem.splitScalar(u8, line, ' ');
                _ = parts.next();
                if (parts.next()) |psha| {
                    prev_sha = psha[0..@min(8, psha.len)];
                }
            }
        }
    }

    var result_list: std.ArrayList(u8) = .empty;
    errdefer result_list.deinit(allocator);

    const is_uncommitted = std.mem.startsWith(u8, sha, "0000000") or std.mem.eql(u8, author, "Not Committed Yet");

    if (is_uncommitted) {
        const file_stat = try getStatusAndStats(allocator, runner, file_path, dir_path);
        defer allocator.free(file_stat);

        try result_list.appendSlice(allocator, "`");
        try result_list.appendSlice(allocator, file_stat);
        try result_list.appendSlice(allocator, "`\n");

        if (hunk_diff) |hd| {
            try result_list.appendSlice(allocator, hd);
            try result_list.appendSlice(allocator, "\n");
        }

        if (prev_sha.len > 0) {
            const prev_out = try runner.run(&.{ "git", "show", "-s", "--format=%an%x00%ar%x00%s", prev_sha }, dir_path);
            if (prev_out) |po| {
                defer allocator.free(po);
                var parts = std.mem.splitScalar(u8, std.mem.trim(u8, po, " \t\r\n"), 0);
                const p_author = parts.next() orelse "";
                const p_time = parts.next() orelse "";
                const p_raw_sum = parts.rest();
                const p_sum = try cleanSummary(allocator, p_raw_sum);
                defer allocator.free(p_sum);

                const prev_str = try std.fmt.allocPrint(allocator, "• Prev: `{s}` • {s} ({s})", .{ prev_sha, p_author, p_time });
                defer allocator.free(prev_str);
                try result_list.appendSlice(allocator, prev_str);

                if (p_sum.len > 0) {
                    try result_list.appendSlice(allocator, "  \n  ↳ *");
                    try result_list.appendSlice(allocator, p_sum);
                    try result_list.appendSlice(allocator, "*");
                }
            }
        }
    } else if (sha.len > 0) {
        if (hunk_diff) |hd| {
            try result_list.appendSlice(allocator, hd);
            try result_list.appendSlice(allocator, "\n");
        }

        try result_list.appendSlice(allocator, "`Blame: ");
        try result_list.appendSlice(allocator, sha);
        try result_list.appendSlice(allocator, " • ");
        try result_list.appendSlice(allocator, author);
        if (author_time.len > 0) {
            try result_list.appendSlice(allocator, " • ");
            try result_list.appendSlice(allocator, author_time);
        }
        try result_list.appendSlice(allocator, "`");

        const clean_sum = try cleanSummary(allocator, summary);
        defer allocator.free(clean_sum);
        if (clean_sum.len > 0) {
            try result_list.appendSlice(allocator, "  \n  ↳ *");
            try result_list.appendSlice(allocator, clean_sum);
            try result_list.appendSlice(allocator, "*");
        }
    }

    if (result_list.items.len == 0) return null;
    return try result_list.toOwnedSlice(allocator);
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
