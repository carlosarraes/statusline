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
    const reset = "\x1b[0m";
};

const StatuslineInput = struct {
    workspace: ?struct {
        current_dir: ?[]const u8,
    } = null,
    cwd: ?[]const u8 = null,
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

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input_json = try readStdinAlloc(allocator, 1024 * 1024);

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

    var output_buf: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output_buf);
    const writer = &output_writer;

    const input_dir = if (input.workspace) |ws| ws.current_dir orelse input.cwd else input.cwd;
    const current_dir = if (input_dir) |dir| blk: {
        if (std.fs.path.isAbsolute(dir)) break :blk dir;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        break :blk try allocator.dupe(u8, try getCwd(&cwd_buf));
    } else null;

    if (current_dir) |dir| {
        try writer.print("{s}", .{colors.yellow});
        try formatPath(writer, dir, init.environ_map.get("HOME") orelse "");
        try writer.print("{s}", .{colors.reset});

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
