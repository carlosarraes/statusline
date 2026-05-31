// Simple statusline: <cwd> • [<branch>] • <git diff --stat>
// Compile with: zig build-exe statusline.zig -O ReleaseFast

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const colors = struct {
    const cyan = "\x1b[36m";
    const green = "\x1b[32m";
    const gray = "\x1b[90m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const reset = "\x1b[0m";
};

const StatuslineInput = struct {
    workspace: ?struct {
        current_dir: ?[]const u8 = null,
        git_worktree: ?[]const u8 = null,
    } = null,
    cwd: ?[]const u8 = null,
    context_window: ?struct {
        used_percentage: ?f64 = null,
    } = null,
};

// Input for the subagent panel: a different shape (a list of tasks) on the
// same stdin, selected with the `--subagent` flag.
const SubagentInput = struct {
    tasks: []const Task = &.{},

    const Task = struct {
        id: []const u8 = "",
        name: ?[]const u8 = null,
        status: ?[]const u8 = null,
        tokenCount: ?f64 = null,
        cwd: ?[]const u8 = null,
    };
};

const DiffStats = struct {
    files: u32 = 0,
    insertions: u32 = 0,
    deletions: u32 = 0,

    fn isEmpty(self: DiffStats) bool {
        return self.files == 0;
    }

    fn format(self: DiffStats, writer: anytype) !void {
        if (self.isEmpty()) return;

        try writer.print(" {s}•{s} {s}{d}f{s}", .{
            colors.gray,
            colors.reset,
            colors.cyan,
            self.files,
            colors.reset,
        });

        if (self.insertions > 0) {
            try writer.print(" {s}{d}(+){s}", .{
                colors.green,
                self.insertions,
                colors.reset,
            });
        }

        if (self.deletions > 0) {
            try writer.print(" {s}{d}(-){s}", .{
                colors.red,
                self.deletions,
                colors.reset,
            });
        }
    }
};

fn execCommand(allocator: Allocator, io: std.Io, command: []const u8, cwd: ?[]const u8) ![]const u8 {
    const argv = [_][]const u8{ "sh", "-c", command };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = if (cwd) |dir| .{ .path = dir } else .inherit,
        .stderr_limit = .limited(0),
        .stdout_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return allocator.dupe(u8, trimmed);
}

fn getGitBranch(allocator: Allocator, io: std.Io, dir: []const u8) ?[]const u8 {
    return execCommand(allocator, io, "git branch --show-current", dir) catch return null;
}

fn getDiffStats(allocator: Allocator, io: std.Io, dir: []const u8) DiffStats {
    const output = execCommand(allocator, io, "git diff --stat", dir) catch return DiffStats{};
    defer allocator.free(output);

    if (output.len == 0) return DiffStats{};

    const trimmed = std.mem.trimEnd(u8, output, "\n");
    const last_nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
    const last_line = if (last_nl) |pos| trimmed[pos + 1 ..] else trimmed;

    return parseDiffSummary(last_line);
}

fn parseDiffSummary(line: []const u8) DiffStats {
    var stats = DiffStats{};

    // Parse: "3 files changed, 90 insertions(+), 2 deletions(-)"
    var tokens = std.mem.tokenizeAny(u8, line, " ,");
    var prev_token: ?[]const u8 = null;

    while (tokens.next()) |token| {
        if (prev_token) |prev| {
            if (std.mem.indexOf(u8, token, "file") != null) {
                stats.files = std.fmt.parseUnsigned(u32, prev, 10) catch stats.files;
            } else if (std.mem.indexOf(u8, token, "insertion") != null) {
                stats.insertions = std.fmt.parseUnsigned(u32, prev, 10) catch stats.insertions;
            } else if (std.mem.indexOf(u8, token, "deletion") != null) {
                stats.deletions = std.fmt.parseUnsigned(u32, prev, 10) catch stats.deletions;
            }
        }
        prev_token = token;
    }

    return stats;
}

fn isHomePath(path: []const u8, home: []const u8) bool {
    return std.mem.eql(u8, path, home) or
        (path.len > home.len and std.mem.startsWith(u8, path, home) and path[home.len] == '/');
}

fn formatPath(writer: *std.Io.Writer, path: []const u8, home: []const u8) !void {
    if (home.len > 0 and isHomePath(path, home)) {
        try writer.print("~{s}", .{path[home.len..]});
    } else {
        try writer.print("{s}", .{path});
    }
}

fn readStdinAlloc(allocator: Allocator, max_bytes: usize) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
        if (n == 0) break;
        if (list.items.len + n > max_bytes) return error.InputTooLarge;
        try list.appendSlice(allocator, buffer[0..n]);
    }

    return list.toOwnedSlice(allocator);
}

fn getCwd(buffer: []u8) ![]u8 {
    const rc = std.posix.system.getcwd(buffer.ptr, buffer.len);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => buffer[0 .. @as(usize, @intCast(rc)) - 1],
        .RANGE => error.NameTooLong,
        else => error.Unexpected,
    };
}

fn writeStdout(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const rc = std.posix.system.write(
            std.posix.STDOUT_FILENO,
            remaining.ptr,
            @min(remaining.len, 0x7ffff000),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => remaining = remaining[@intCast(rc)..],
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

const context_bar_width = 10;

fn contextColor(pct: u8) []const u8 {
    if (pct >= 90) return colors.red;
    if (pct >= 70) return colors.yellow;
    return colors.green;
}

fn formatContext(writer: *std.Io.Writer, used_percentage: f64) !void {
    const clamped = std.math.clamp(used_percentage, 0.0, 100.0);
    const pct: u8 = @intFromFloat(clamped);
    const filled = pct / (100 / context_bar_width);
    const color = contextColor(pct);

    try writer.print(" {s}•{s} {s}", .{ colors.gray, colors.reset, color });
    var i: u8 = 0;
    while (i < context_bar_width) : (i += 1) {
        try writer.writeAll(if (i < filled) "▓" else "░");
    }
    try writer.print(" {d}%{s}", .{ pct, colors.reset });
}

fn formatTokens(writer: *std.Io.Writer, count: u64) !void {
    if (count < 1000) {
        try writer.print("{d}", .{count});
    } else if (count < 1_000_000) {
        try writer.print("{d}.{d}k", .{ count / 1000, (count % 1000) / 100 });
    } else {
        try writer.print("{d}.{d}m", .{ count / 1_000_000, (count % 1_000_000) / 100_000 });
    }
}

fn statusColor(status: []const u8) []const u8 {
    if (std.mem.indexOf(u8, status, "error") != null or
        std.mem.indexOf(u8, status, "fail") != null) return colors.red;
    if (std.mem.indexOf(u8, status, "pending") != null or
        std.mem.indexOf(u8, status, "queue") != null) return colors.yellow;
    if (std.mem.indexOf(u8, status, "run") != null or
        std.mem.indexOf(u8, status, "active") != null or
        std.mem.indexOf(u8, status, "progress") != null) return colors.green;
    return colors.gray;
}

// Minimal JSON string encoder: escapes the bytes our content can contain.
// The ANSI escape byte 0x1b is a JSON control char and is unicode-escaped.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => if (c < 0x20)
                try writer.print("\\u{x:0>4}", .{c})
            else
                try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn formatSubagentRow(writer: *std.Io.Writer, task: SubagentInput.Task) !void {
    try writer.print("{s}{s}{s}", .{ colors.cyan, task.name orelse "agent", colors.reset });

    if (task.status) |st| {
        try writer.print(" {s}·{s} {s}{s}{s}", .{ colors.gray, colors.reset, statusColor(st), st, colors.reset });
    }

    if (task.tokenCount) |tc| {
        try writer.print(" {s}·{s} {s}", .{ colors.gray, colors.reset, colors.gray });
        try formatTokens(writer, @intFromFloat(@round(tc)));
        try writer.writeAll(colors.reset);
    }

    if (task.cwd) |cwd| {
        const base = std.fs.path.basename(cwd);
        if (base.len > 0) {
            try writer.print(" {s}·{s} {s}{s}{s}", .{ colors.gray, colors.reset, colors.blue, base, colors.reset });
        }
    }
}

fn isSubagentMode(init: std.process.Init) bool {
    var it = init.minimal.args.iterate();
    _ = it.skip(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--subagent")) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input_json = try readStdinAlloc(allocator, 1024 * 1024);

    if (isSubagentMode(init)) {
        runSubagent(allocator, input_json);
        return;
    }

    try runStatusline(allocator, init, input_json);
}

// Emits one JSON line per subagent row to override its panel rendering.
// Any per-row failure is skipped, leaving that row's default display intact.
fn runSubagent(allocator: Allocator, input_json: []const u8) void {
    const parsed = json.parseFromSlice(SubagentInput, allocator, input_json, .{
        .ignore_unknown_fields = true,
    }) catch return;

    for (parsed.value.tasks) |task| {
        if (task.id.len == 0) continue;

        var content_buf: [512]u8 = undefined;
        var content_writer: std.Io.Writer = .fixed(&content_buf);
        formatSubagentRow(&content_writer, task) catch continue;

        var row_buf: [1024]u8 = undefined;
        var row_writer: std.Io.Writer = .fixed(&row_buf);
        const ok = blk: {
            row_writer.writeAll("{\"id\":") catch break :blk false;
            writeJsonString(&row_writer, task.id) catch break :blk false;
            row_writer.writeAll(",\"content\":") catch break :blk false;
            writeJsonString(&row_writer, content_writer.buffered()) catch break :blk false;
            row_writer.writeAll("}\n") catch break :blk false;
            break :blk true;
        };
        if (ok) writeStdout(row_writer.buffered()) catch {};
    }
}

fn runStatusline(allocator: Allocator, init: std.process.Init, input_json: []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.Writer = .fixed(&stdout_buf);
    const stdout = &stdout_writer;

    const parsed = json.parseFromSlice(StatuslineInput, allocator, input_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        stdout.writeAll(colors.cyan ++ "~" ++ colors.reset ++ "\n") catch {};
        writeStdout(stdout.buffered()) catch {};
        return;
    };

    const input = parsed.value;

    var output_buf: [2048]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output_buf);
    const writer = &output_writer;

    const input_dir = if (input.workspace) |ws| ws.current_dir orelse input.cwd else input.cwd;
    const current_dir = if (input_dir) |dir| blk: {
        if (std.fs.path.isAbsolute(dir)) break :blk dir;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        break :blk try allocator.dupe(u8, try getCwd(&cwd_buf));
    } else null;

    const in_worktree = if (input.workspace) |ws| ws.git_worktree != null else false;

    if (current_dir) |dir| {
        try writer.print("{s}", .{colors.yellow});
        try formatPath(writer, dir, init.environ_map.get("HOME") orelse "");
        try writer.print("{s}", .{colors.reset});

        if (in_worktree) {
            try writer.print(" {s}•{s} {s}⑂{s}", .{ colors.gray, colors.reset, colors.magenta, colors.reset });
        }

        if (getGitBranch(allocator, init.io, dir)) |branch| {
            defer allocator.free(branch);
            const diff_stats = getDiffStats(allocator, init.io, dir);

            try writer.print(" {s}•{s} {s}[{s}{s}{s}]{s}", .{
                colors.gray,
                colors.reset,
                colors.gray,
                colors.blue,
                branch,
                colors.gray,
                colors.reset,
            });

            try diff_stats.format(writer);
        }
    } else {
        try writer.print("{s}~{s}", .{ colors.cyan, colors.reset });
    }

    if (input.context_window) |cw| {
        if (cw.used_percentage) |pct| {
            try formatContext(writer, pct);
        }
    }

    stdout.writeAll(output_writer.buffered()) catch {};
    stdout.writeAll("\n") catch {};
    writeStdout(stdout.buffered()) catch {};
}

test "DiffStats formatting" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const stats = DiffStats{ .files = 3, .insertions = 90, .deletions = 2 };
    try stats.format(&writer);

    const expected = " \x1b[90m•\x1b[0m \x1b[36m3f\x1b[0m \x1b[32m90(+)\x1b[0m \x1b[31m2(-)\x1b[0m";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "isHomePath matches home and descendants only" {
    try std.testing.expect(isHomePath("/home/carraes", "/home/carraes"));
    try std.testing.expect(isHomePath("/home/carraes/projs/statusline", "/home/carraes"));
    try std.testing.expect(!isHomePath("/home/carraes-other/projs/statusline", "/home/carraes"));
}

test "parseDiffSummary basic" {
    const line = " 3 files changed, 90 insertions(+), 2 deletions(-)";
    const stats = parseDiffSummary(line);

    try std.testing.expectEqual(@as(u32, 3), stats.files);
    try std.testing.expectEqual(@as(u32, 90), stats.insertions);
    try std.testing.expectEqual(@as(u32, 2), stats.deletions);
}

test "parseDiffSummary only insertions" {
    const line = " 1 file changed, 5 insertions(+)";
    const stats = parseDiffSummary(line);

    try std.testing.expectEqual(@as(u32, 1), stats.files);
    try std.testing.expectEqual(@as(u32, 5), stats.insertions);
    try std.testing.expectEqual(@as(u32, 0), stats.deletions);
}

test "parseDiffSummary only deletions" {
    const line = " 2 files changed, 10 deletions(-)";
    const stats = parseDiffSummary(line);

    try std.testing.expectEqual(@as(u32, 2), stats.files);
    try std.testing.expectEqual(@as(u32, 0), stats.insertions);
    try std.testing.expectEqual(@as(u32, 10), stats.deletions);
}

test "formatContext low usage renders a green bar" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatContext(&writer, 22);

    const expected = " \x1b[90m•\x1b[0m \x1b[32m▓▓░░░░░░░░ 22%\x1b[0m";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "formatContext high usage renders a red bar" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatContext(&writer, 95);

    const expected = " \x1b[90m•\x1b[0m \x1b[31m▓▓▓▓▓▓▓▓▓░ 95%\x1b[0m";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "formatTokens humanizes counts" {
    const cases = .{
        .{ @as(u64, 0), "0" },
        .{ @as(u64, 999), "999" },
        .{ @as(u64, 1000), "1.0k" },
        .{ @as(u64, 12300), "12.3k" },
        .{ @as(u64, 1_500_000), "1.5m" },
    };
    inline for (cases) |case| {
        var buf: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try formatTokens(&writer, case[0]);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}

test "writeJsonString escapes the ansi escape byte" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeJsonString(&writer, "\x1b[32mok\x1b[0m");

    try std.testing.expectEqualStrings("\"\\u001b[32mok\\u001b[0m\"", writer.buffered());
}
