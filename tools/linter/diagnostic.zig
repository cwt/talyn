const std = @import("std");

pub const Severity = enum {
    err,
    warning,
    info,

    pub fn prefix(self: Severity) []const u8 {
        return switch (self) {
            .err => "\x1b[1;31m[ERROR]\x1b[0m",
            .warning => "\x1b[1;33m[WARNING]\x1b[0m",
            .info => "\x1b[1;36m[INFO]\x1b[0m",
        };
    }
};

pub const Diagnostic = struct {
    file_path: []const u8,
    line: usize,
    column: usize,
    rule_id: []const u8,
    bug_ref: []const u8,
    severity: Severity = .err,
    message: []const u8,
    risk: []const u8,
    fix: []const u8,

    pub fn print(self: Diagnostic, io: std.Io, gpa: std.mem.Allocator) !void {
        _ = gpa;
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
        const w = &stdout_writer.interface;

        try w.print("\n{s} \x1b[1m{s}\x1b[0m ({s})\n", .{
            self.severity.prefix(),
            self.rule_id,
            self.bug_ref,
        });
        try w.print("  \x1b[36m-->\x1b[0m {s}:{d}:{d}\n", .{
            self.file_path,
            self.line,
            self.column,
        });
        try w.print("  \x1b[1mIssue:\x1b[0m {s}\n", .{self.message});
        try w.print("  \x1b[31mRisk:\x1b[0m  {s}\n", .{self.risk});
        try w.print("  \x1b[32mFix:\x1b[0m   {s}\n", .{self.fix});

        try w.flush();
    }
};
