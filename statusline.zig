// Simple statusline: <cwd> • [<branch>] • <git diff --stat>
// Compile with: zig build-exe statusline.zig -O ReleaseFast -fsingle-threaded

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

fn execCommand(allocator: Allocator, command: [:0]const u8, cwd: ?[]const u8) ![]const u8 {
    const argv = [_][:0]const u8{ "sh", "-c", command };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (cwd) |dir| child.cwd = dir;

    try child.spawn();

    const stdout = child.stdout.?;
    const raw_output = try stdout.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw_output);

    _ = try child.wait();

    const trimmed = std.mem.trim(u8, raw_output, " \t\n\r");
    return allocator.dupe(u8, trimmed);
}

fn isGitRepo(allocator: Allocator, dir: []const u8) bool {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const temp_alloc = fba.allocator();

    const cmd = temp_alloc.dupeZ(u8, "git rev-parse --is-inside-work-tree") catch return false;
    const result = execCommand(allocator, cmd, dir) catch return false;
    defer allocator.free(result);

    return std.mem.eql(u8, result, "true");
}

fn getGitBranch(allocator: Allocator, dir: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const temp_alloc = fba.allocator();

    const cmd = try temp_alloc.dupeZ(u8, "git branch --show-current");
    return execCommand(allocator, cmd, dir) catch try allocator.dupe(u8, "");
}

fn getDiffStats(allocator: Allocator, dir: []const u8) !DiffStats {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const temp_alloc = fba.allocator();

    const cmd = try temp_alloc.dupeZ(u8, "git diff --stat");
    const output = execCommand(allocator, cmd, dir) catch return DiffStats{};
    defer allocator.free(output);

    if (output.len == 0) return DiffStats{};

    var lines = std.mem.splitScalar(u8, output, '\n');
    var last_line: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (line.len > 0) {
            last_line = line;
        }
    }

    if (last_line) |line| {
        return parseDiffSummary(line);
    }

    return DiffStats{};
}

fn parseDiffSummary(line: []const u8) DiffStats {
    var stats = DiffStats{};

    // Parse: "3 files changed, 90 insertions(+), 2 deletions(-)"
    var tokens = std.mem.tokenizeAny(u8, line, " ,");
    var prev_token: ?[]const u8 = null;

    while (tokens.next()) |token| {
        if (prev_token) |prev| {
            if (std.mem.indexOf(u8, token, "file") != null or std.mem.indexOf(u8, token, "changed") != null) {
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

fn formatPath(writer: anytype, path: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse "";
    if (home.len > 0 and std.mem.startsWith(u8, path, home)) {
        try writer.print("~{s}", .{path[home.len..]});
    } else {
        try writer.print("{s}", .{path});
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdin = std.fs.File.stdin();
    const input_json = try stdin.readToEndAlloc(allocator, 1024 * 1024);

    const parsed = json.parseFromSlice(StatuslineInput, allocator, input_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        var stdout_buf: [32]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const stdout = &stdout_writer.interface;
        stdout.writeAll(colors.cyan) catch {};
        stdout.writeAll("~") catch {};
        stdout.writeAll(colors.reset) catch {};
        stdout.writeAll("\n") catch {};
        stdout.flush() catch {};
        return;
    };

    const input = parsed.value;

    var output_buf: [1024]u8 = undefined;
    var output_stream = std.io.fixedBufferStream(&output_buf);
    const writer = output_stream.writer();

    const current_dir = if (input.workspace) |ws| ws.current_dir else null;

    if (current_dir == null) {
        try writer.print("{s}~{s}", .{ colors.cyan, colors.reset });
    } else {
        const dir = current_dir.?;

        if (isGitRepo(allocator, dir)) {
            const branch = try getGitBranch(allocator, dir);
            defer allocator.free(branch);

            const diff_stats = try getDiffStats(allocator, dir);

            try writer.print("{s}", .{colors.yellow});
            try formatPath(writer, dir);
            try writer.print("{s}", .{colors.reset});

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
        } else {
            try writer.print("{s}", .{colors.yellow});
            try formatPath(writer, dir);
            try writer.print("{s}", .{colors.reset});
        }
    }

    const output = output_stream.getWritten();

    var stdout_buf: [32]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    stdout.writeAll(output) catch {};
    stdout.writeAll("\n") catch {};
    stdout.flush() catch {};
}

test "DiffStats formatting" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const stats = DiffStats{ .files = 3, .insertions = 90, .deletions = 2 };
    try stats.format(writer);

    const expected = " \x1b[90m•\x1b[0m \x1b[36m3f\x1b[0m \x1b[32m90(+)\x1b[0m \x1b[31m2(-)\x1b[0m";
    try std.testing.expectEqualStrings(expected, stream.getWritten());
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
