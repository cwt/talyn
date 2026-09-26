const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// TALYN-015/SQE_POINTER_LIFETIME
///
/// io_uring SQE-prep helpers (`ring.timeout`, `ring.link_timeout`,
/// `ring.connect`, `ring.accept`, `ring.recvmsg`, `ring.sendmsg`,
/// `ring.read`, `ring.write`, `ring.read_fixed`, ...) store pointer
/// arguments raw in `sqe.addr`/`sqe.__pad2`, and the kernel dereferences
/// them at *submit* time. Talyn defers submission (`IO.queue_unlocked`
/// batches SQEs until a cancel or a near-full queue, and every flush
/// happens after the queuing function returns), so any pointer derived
/// from the queuing function's own stack frame is dead memory by the
/// time the kernel reads it.
///
/// This is the class of BUG-334 (`ring.link_timeout` armed from a
/// timespec inside the callee's by-value `data` parameter — the kernel
/// read reclaimed stack bytes) and BUG-30 (caller iovecs).
///
/// Scope: `src/loop/scheduling/io/*.zig` — the only place direct
/// `ring.*` prep calls live — to keep the false-positive surface small.
///
/// Flagged patterns (pointer-position arguments of SQE-prep calls whose
/// receiver identifier contains "ring"):
///   1. `&<by-value-param>...`  — address of the callee's stack copy.
///   2. `&<capture>...`         — address of a stack capture copy.
///   3. bare `<capture>...` (e.g. `timeout` from
///      `if (data.timeout) |*timeout|`) when the capture's controlling
///      expression roots in a by-value parameter — the exact BUG-334
///      shape — or when the chain ends in `.ptr`/`.items` indirection.
///   4. `&<local>...` where the local's declaration is not provably
///      heap/pool-resident (initializer lacks set./self./loop./io.-rooted
///      or push/create/alloc/dupe/empty storage).
///
/// Known limitations (documented, not silent): bare pointer-valued
/// parameter fields (`data.msg`, `data.addr`) are pre-existing pointers
/// whose targets live in caller-owned heap structs — ownership is
/// enforced by the BlockingTask/cleanup conventions and review, not
/// statically. By-value `ReadBuffer` arguments (`data.data`) hide their
/// inner pointer; residency is covered by transport lifetime rules.
pub fn check(
    ast: *const std.zig.Ast,
    file_path: []const u8,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    if (std.mem.indexOf(u8, file_path, "src/loop/scheduling/io/") == null) return;

    const tags = ast.tokens.items(.tag);
    const n_tokens: usize = tags.len;

    var scopes: std.ArrayList(Scope) = .empty;
    defer {
        for (scopes.items) |*s| s.deinit(gpa);
        scopes.deinit(gpa);
    }

    var depth: i32 = 0;
    var pending: ?FnHeader = null;

    var t: usize = 0;
    while (t < n_tokens) : (t += 1) {
        const tag = tags[t];

        // ── (1) brace tracking: push/pop function scopes ─────────────
        if (tag == .l_brace) {
            depth += 1;
            if (pending) |*hdr| {
                if (hdr.awaiting_body) {
                    const params = hdr.params;
                    pending = null;
                    try scopes.append(gpa, .{ .body_depth = depth, .params = params });
                }
            }
            continue;
        }
        if (tag == .r_brace) {
            if (scopes.items.len > 0 and scopes.items[scopes.items.len - 1].body_depth == depth) {
                var scope = scopes.pop().?;
                scope.deinit(gpa);
            }
            depth -= 1;
            continue;
        }

        // ── (2) fn/test header collection ────────────────────────────
        if (tag == .keyword_fn and pending == null) {
            pending = .{};
            continue;
        }
        if (tag == .keyword_test and pending == null) {
            pending = .{ .awaiting_body = true };
            continue;
        }
        if (pending) |*hdr| {
            if (hdr.awaiting_body) {
                // Bodyless declaration (extern fn / fn-type field):
                // the statement ends at a semicolon or a closing brace.
                if (tag == .semicolon or tag == .r_brace) {
                    hdr.params.deinit(gpa);
                    pending = null;
                }
                continue;
            }
            if (hdr.skip_to_paren) {
                if (tag == .l_paren) {
                    hdr.skip_to_paren = false;
                    hdr.in_params = true;
                    hdr.paren_depth = 1; // opening paren already counted
                    hdr.param_start = null;
                }
                continue;
            }
            if (hdr.in_params) {
                switch (tag) {
                    .l_paren => {
                        hdr.paren_depth += 1;
                        if (hdr.param_start == null) hdr.param_start = t;
                    },
                    .r_paren => {
                        hdr.paren_depth -= 1;
                        if (hdr.paren_depth == 0) {
                            if (hdr.param_start) |s| {
                                if (t > s) try pendingParamAdd(hdr, ast, gpa, s, t - 1);
                            }
                            hdr.param_start = null;
                            hdr.in_params = false;
                            hdr.awaiting_body = true;
                        } else if (hdr.param_start == null) {
                            hdr.param_start = t;
                        }
                    },
                    .comma => {
                        if (hdr.paren_depth == 1) {
                            if (hdr.param_start) |s| {
                                if (t > s) try pendingParamAdd(hdr, ast, gpa, s, t - 1);
                            }
                            hdr.param_start = null;
                        } else if (hdr.param_start == null) {
                            hdr.param_start = t;
                        }
                    },
                    else => {
                        if (hdr.param_start == null) hdr.param_start = t;
                    },
                }
                continue;
            }
            continue;
        }

        // ── (3) ring.* SQE-prep call detection ────────────────────────
        // Token layout: <recv-ident> . <op-ident> (
        if (t + 2 < n_tokens and tag == .l_paren and t >= 3 and
            tags[t - 3] == .identifier and tags[t - 2] == .period and
            tags[t - 1] == .identifier)
        {
            const recv = ast.tokenSlice(@intCast(t - 3));
            if (std.mem.indexOf(u8, recv, "ring") != null) {
                const op_name = ast.tokenSlice(@intCast(t - 1));
                if (pointerPositions(op_name)) |positions| {
                    try evalCallArgs(ast, gpa, diagnostics, scopes.items, t, positions, file_path);
                }
            }
        }

        // ── (4) decl + capture binding in the innermost scope ────────
        if (scopes.items.len > 0) {
            const scope = &scopes.items[scopes.items.len - 1];
            if (depth >= scope.body_depth) {
                try scope.trackDecl(ast, gpa, tag, t);
                if (tag == .pipe) try scope.handlePipe(ast, gpa, t);
            }
        }
    }
}

const Param = struct { name: []const u8, is_pointer: bool };
const Local = struct { name: []const u8, init_start: usize, init_end: usize };
const Capture = struct { name: []const u8, root: []const u8 };

const FnHeader = struct {
    params: std.ArrayList(Param) = .empty,
    skip_to_paren: bool = true,
    in_params: bool = false,
    paren_depth: i32 = 0,
    param_start: ?usize = null,
    awaiting_body: bool = false,
};

const Scope = struct {
    body_depth: i32,
    params: std.ArrayList(Param),

    decl_state: enum { none, want_name, want_eq, in_init } = .none,
    decl_name: ?[]const u8 = null,
    decl_init_start: usize = 0,

    captures: std.ArrayList(Capture) = .empty,
    locals: std.ArrayList(Local) = .empty,

    fn deinit(self: *Scope, gpa: std.mem.Allocator) void {
        self.params.deinit(gpa);
        self.captures.deinit(gpa);
        self.locals.deinit(gpa);
    }

    fn trackDecl(self: *Scope, ast: *const std.zig.Ast, gpa: std.mem.Allocator, tag: std.zig.Token.Tag, token: usize) !void {
        switch (self.decl_state) {
            .none => {
                if (tag == .keyword_const or tag == .keyword_var) {
                    self.decl_state = .want_name;
                    self.decl_name = null;
                }
            },
            .want_name => {
                if (tag == .identifier) {
                    self.decl_name = ast.tokenSlice(@intCast(token));
                    self.decl_state = .want_eq;
                } else if (tag == .semicolon or tag == .l_brace or tag == .r_brace) {
                    self.decl_state = .none;
                }
            },
            .want_eq => {
                if (tag == .equal) {
                    self.decl_init_start = token + 1;
                    self.decl_state = .in_init;
                } else if (tag == .semicolon or tag == .l_brace or tag == .r_brace) {
                    self.decl_state = .none;
                }
            },
            .in_init => {
                if (tag == .semicolon or tag == .l_brace or tag == .r_brace) {
                    try self.recordLocal(ast, gpa, token);
                    self.decl_state = .none;
                }
            },
        }
    }

    fn recordLocal(self: *Scope, ast: *const std.zig.Ast, gpa: std.mem.Allocator, end_token: usize) !void {
        const name = self.decl_name orelse return;
        for (self.locals.items) |l| {
            if (std.mem.eql(u8, l.name, name)) return;
        }
        if (localInitLooksHeapResident(ast, .{ .name = name, .init_start = self.decl_init_start, .init_end = end_token })) return;
        try self.locals.append(gpa, .{ .name = name, .init_start = self.decl_init_start, .init_end = end_token });
    }

    fn addCapture(self: *Scope, gpa: std.mem.Allocator, name: []const u8, root: []const u8) !void {
        for (self.captures.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return;
        }
        try self.captures.append(gpa, .{ .name = name, .root = root });
    }

    /// Bind pipe captures:  `) |x|`,  `=> |x|`,  `) |*x, y|`.
    /// Root = first non-field identifier of the controlling expression.
    fn handlePipe(self: *Scope, ast: *const std.zig.Ast, gpa: std.mem.Allocator, pipe_token: usize) !void {
        const tags = ast.tokens.items(.tag);
        if (pipe_token == 0) return;
        const prev = tags[pipe_token - 1];

        var root: ?[]const u8 = null;
        if (prev == .r_paren) {
            // if/while/for — walk back to the matching l_paren: an
            // l_paren closes the match only AFTER balancing the depth
            // it offsets (decrement first, then break at zero).
            var d: i32 = 0;
            var i: usize = pipe_token - 1;
            while (true) {
                if (tags[i] == .r_paren) {
                    d += 1;
                } else if (tags[i] == .l_paren) {
                    d -= 1;
                    if (d == 0) break;
                }
                if (i == 0) return;
                i -= 1;
            }
            root = rootIdentifier(ast, i + 1, pipe_token - 1);
        } else if (prev == .arrow) {
            // switch capture — root of the switch operand: from the
            // switch keyword, the operand is its parenthesized range.
            var i: usize = pipe_token;
            while (i > 0) : (i -= 1) {
                if (tags[i] == .keyword_switch) break;
            }
            if (tags[i] != .keyword_switch) return;
            while (i < tags.len and tags[i] != .l_paren) i += 1;
            if (i >= tags.len) return;
            const l_paren = i;
            var d: i32 = 0;
            var r_paren: usize = l_paren;
            while (i < tags.len) : (i += 1) {
                if (tags[i] == .l_paren) {
                    d += 1;
                } else if (tags[i] == .r_paren) {
                    d -= 1;
                    if (d == 0) {
                        r_paren = i;
                        break;
                    }
                }
            }
            root = rootIdentifier(ast, l_paren + 1, r_paren - 1);
        } else {
            return; // `catch |err|` etc. do not alias param storage
        }
        const root_name = root orelse return;

        var j: usize = pipe_token + 1;
        var current: ?usize = null;
        while (j < tags.len and tags[j] != .pipe) : (j += 1) {
            if (tags[j] == .identifier) current = j;
            if (tags[j] == .comma) {
                if (current) |c| {
                    const name = ast.tokenSlice(@intCast(c));
                    try self.addCapture(gpa, name, root_name);
                    current = null;
                }
            }
        }
        // Flush the last capture — the loop above exits at the closing
        // pipe before the trailing name is committed.
        if (current) |c| {
            const name = ast.tokenSlice(@intCast(c));
            try self.addCapture(gpa, name, root_name);
        }
    }
};

/// Root identifier of a token range: first identifier not preceded by
/// a period (i.e. not a field access).
fn rootIdentifier(ast: *const std.zig.Ast, start: usize, end: usize) ?[]const u8 {
    const tags = ast.tokens.items(.tag);
    if (start > end) return null;
    var i = start;
    while (i <= end) : (i += 1) {
        if (tags[i] == .identifier) {
            if (i > 0 and tags[i - 1] == .period) continue;
            return ast.tokenSlice(@intCast(i));
        }
    }
    return null;
}

/// Resolve an argument root to its storage class, following capture
/// chains transitively.
const RootKind = enum { by_value_param, pointer_param, local, unknown };

fn resolveRoot(scopes: []Scope, root: []const u8) RootKind {
    const scope = &scopes[scopes.len - 1];
    var name = root;
    var hops: usize = 0;
    while (hops < 8) : (hops += 1) {
        var found = false;
        for (scope.captures.items) |c| {
            if (std.mem.eql(u8, c.name, name)) {
                name = c.root;
                found = true;
                break;
            }
        }
        if (!found) break;
    }
    for (scope.params.items) |p| {
        if (std.mem.eql(u8, p.name, name)) return if (p.is_pointer) .pointer_param else .by_value_param;
    }
    for (scope.locals.items) |l| {
        if (std.mem.eql(u8, l.name, name)) return .local;
    }
    return .unknown;
}

/// True when the local's initializer provably targets heap/pool storage
/// that outlives the function (set./self./loop./io.-rooted, or created
/// through push/create/alloc/dupe/.empty).
fn localInitLooksHeapResident(ast: *const std.zig.Ast, local: Local) bool {
    const tags = ast.tokens.items(.tag);
    var i = local.init_start;
    while (i <= local.init_end and i < tags.len) : (i += 1) {
        if (tags[i] != .identifier) continue;
        if (i > 0 and tags[i - 1] == .keyword_comptime) continue;
        const s = ast.tokenSlice(@intCast(i));
        if (std.mem.eql(u8, s, "set") or std.mem.eql(u8, s, "self") or
            std.mem.eql(u8, s, "loop") or std.mem.eql(u8, s, "io") or
            std.mem.eql(u8, s, "empty") or std.mem.eql(u8, s, "push") or
            std.mem.eql(u8, s, "create") or std.mem.eql(u8, s, "alloc") or
            std.mem.eql(u8, s, "dupe")) return true;
    }
    return false;
}

/// SQE-prep ops that store a pointer the kernel dereferences, mapped to
/// the 0-based argument positions holding pointers (position 0 is the
/// first argument after the receiver, conventionally user_data).
fn pointerPositions(op: []const u8) ?[]const usize {
    const table = .{
        .{ "link_timeout", &[_]usize{1} },
        .{ "timeout", &[_]usize{1} },
        .{ "connect", &[_]usize{2} },
        .{ "accept", &[_]usize{ 2, 3 } },
        .{ "accept_direct", &[_]usize{ 2, 3 } },
        .{ "accept_multishot", &[_]usize{ 2, 3 } },
        .{ "recvmsg", &[_]usize{2} },
        .{ "sendmsg", &[_]usize{2} },
        .{ "send_zc", &[_]usize{2} },
        .{ "read", &[_]usize{2} },
        .{ "write", &[_]usize{2} },
        .{ "read_fixed", &[_]usize{2} },
        .{ "write_fixed", &[_]usize{2} },
        .{ "openat", &[_]usize{2} },
        .{ "statx", &[_]usize{ 2, 5 } },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, op, entry[0])) return entry[1];
    }
    return null;
}

const Range = struct { start: usize, end: usize };

/// Split the call's argument list at top-level commas and evaluate the
/// pointer positions against stack-frame storage patterns.
fn evalCallArgs(
    ast: *const std.zig.Ast,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    scopes: []Scope,
    l_paren_token: usize,
    positions: []const usize,
    file_path: []const u8,
) !void {
    if (scopes.len == 0) return;
    const tags = ast.tokens.items(.tag);

    var arg_ranges: std.ArrayList(Range) = .empty;
    defer arg_ranges.deinit(gpa);

    var d: i32 = 0;
    var arg_start: ?usize = null;
    var i = l_paren_token + 1;
    while (i < tags.len) : (i += 1) {
        const tag = tags[i];
        switch (tag) {
            .l_paren, .l_brace, .l_bracket => {
                d += 1;
                if (arg_start == null) arg_start = i;
            },
            .r_paren, .r_brace, .r_bracket => {
                if (d == 0 and tag == .r_paren) {
                    if (arg_start) |s| {
                        if (i > s) try arg_ranges.append(gpa, .{ .start = s, .end = i - 1 });
                    }
                    break;
                }
                d -= 1;
                if (arg_start == null) arg_start = i;
            },
            .comma => {
                if (d == 0) {
                    if (arg_start) |s| {
                        if (i > s) try arg_ranges.append(gpa, .{ .start = s, .end = i - 1 });
                    }
                    arg_start = null;
                }
            },
            else => {
                if (arg_start == null) arg_start = i;
            },
        }
    }

    for (positions) |pos| {
        if (pos >= arg_ranges.items.len) continue;
        try checkArg(ast, gpa, diagnostics, scopes, arg_ranges.items[pos], file_path);
    }
}

/// Collect one parameter: `name: Type` or nameless `Type`.
fn pendingParamAdd(
    hdr: *FnHeader,
    ast: *const std.zig.Ast,
    gpa: std.mem.Allocator,
    start: usize,
    end: usize,
) !void {
    const tags = ast.tokens.items(.tag);
    var name: ?[]const u8 = null;
    var colon: ?usize = null;
    var i = start;
    while (i <= end) : (i += 1) {
        if (tags[i] == .colon) colon = i;
        if (tags[i] == .identifier and colon == null) name = ast.tokenSlice(@intCast(i));
    }
    var is_pointer = false;
    const type_start: ?usize = if (colon) |c| c + 1 else start;
    if (type_start) |ts| {
        if (ts <= end) {
            const first = tags[ts];
            is_pointer = first == .asterisk or first == .asterisk_asterisk or first == .l_bracket;
        }
    }
    if (name) |n| try hdr.params.append(gpa, .{ .name = n, .is_pointer = is_pointer });
}

fn checkArg(
    ast: *const std.zig.Ast,
    gpa: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    scopes: []Scope,
    arg: Range,
    file_path: []const u8,
) !void {
    const tags = ast.tokens.items(.tag);
    if (arg.start > arg.end) return;

    var start = arg.start;
    const is_addr = tags[start] == .ampersand;
    if (is_addr) start += 1;

    // Unwrap pointer-preserving builtins (max 4 deep):
    //   @ptrCast/@constCast/@alignCast/@volatileCast — into the argument.
    //   @as(T, value)                                — into the value.
    // Other builtins (e.g. @intFromPtr) convert away from pointers.
    var unwraps: usize = 0;
    while (unwraps < 4) : (unwraps += 1) {
        if (start > arg.end or tags[start] != .builtin) break;
        const bname = ast.tokenSlice(@intCast(start));
        if (std.mem.eql(u8, bname, "@as")) {
            if (start + 1 > arg.end or tags[start + 1] != .l_paren) break;
            var d: i32 = 0;
            var comma: ?usize = null;
            var j = start + 1;
            while (j <= arg.end) : (j += 1) {
                const jt = tags[j];
                if (jt == .l_paren or jt == .l_brace or jt == .l_bracket) {
                    d += 1;
                } else if (jt == .r_paren or jt == .r_brace or jt == .r_bracket) {
                    d -= 1;
                    if (d == 0) break;
                } else if (jt == .comma and d == 1 and comma == null) {
                    comma = j;
                }
            }
            if (d != 0 or comma == null) break;
            start = comma.? + 1;
        } else if (std.mem.eql(u8, bname, "@ptrCast") or
            std.mem.eql(u8, bname, "@constCast") or
            std.mem.eql(u8, bname, "@volatileCast") or
            std.mem.eql(u8, bname, "@alignCast"))
        {
            if (start + 1 > arg.end or tags[start + 1] != .l_paren) break;
            start = start + 2;
        } else {
            break;
        }
    }

    if (start > arg.end) return;

    const root = blk: {
        var i = start;
        while (i <= arg.end) : (i += 1) {
            if (tags[i] == .identifier) {
                if (i > 0 and tags[i - 1] == .period) continue;
                break :blk ast.tokenSlice(@intCast(i));
            }
        }
        break :blk null;
    };
    const root_name = root orelse return;

    var has_ptr_tail = false;
    {
        var i = start;
        while (i <= arg.end) : (i += 1) {
            if (tags[i] != .identifier) continue;
            const s = ast.tokenSlice(@intCast(i));
            if (std.mem.eql(u8, s, "ptr") or std.mem.eql(u8, s, "items")) has_ptr_tail = true;
        }
    }

    const kind = resolveRoot(scopes, root_name);
    var violation = false;
    var detail: []const u8 = "";
    switch (kind) {
        .by_value_param => {
            if (is_addr) {
                violation = true;
                detail = "address of a by-value parameter";
            } else if (has_ptr_tail) {
                violation = true;
                detail = "pointer-valued member of a by-value parameter";
            }
        },
        .pointer_param => {},
        .local => {
            if (is_addr) {
                const scope = &scopes[scopes.len - 1];
                for (scope.locals.items) |l| {
                    if (!std.mem.eql(u8, l.name, root_name)) continue;
                    violation = true;
                    detail = "address of a local not proven heap-resident";
                    break;
                }
            }
        },
        .unknown => {},
    }

    // Capture refinement: resolveRoot already unwrapped capture chains,
    // so `kind` reflects the capture's ultimate target. Addressed
    // captures are stack copies regardless of their target; bare
    // captures alias param storage when their controlling expression
    // roots in a by-value parameter (the BUG-334 shape).
    const scope = &scopes[scopes.len - 1];
    var is_capture = false;
    for (scope.captures.items) |c| {
        if (std.mem.eql(u8, c.name, root_name)) {
            is_capture = true;
            break;
        }
    }
    if (is_capture) {
        if (is_addr) {
            violation = true;
            detail = "address of a stack capture";
        } else if (kind == .by_value_param and !violation) {
            violation = true;
            detail = "capture aliasing a by-value parameter";
        }
    }

    if (!violation) return;

    const first_tok: std.zig.Ast.TokenIndex = @intCast(arg.start);
    const loc = ast.tokenLocation(0, first_tok);
    try diagnostics.append(gpa, .{
        .file_path = file_path,
        .line = loc.line + 1,
        .column = loc.column + 1,
        .rule_id = "TALYN-015/SQE_POINTER_LIFETIME",
        .bug_ref = "BUG-334, BUG-30",
        .message = try std.fmt.allocPrint(
            gpa,
            "SQE-prep pointer argument is {s} ('{s}').",
            .{ detail, root_name },
        ),
        .risk = "The kernel dereferences SQE pointer fields at submit time, and submission is deferred past the queuing frame — the SQE would be armed from reclaimed stack memory (dead-stack UAF).",
        .fix = "Copy the value into BlockingTask-owned storage (timer_storage / msg_storage / an iovec copy) or another heap-resident struct and pass its address, exactly as Timer.wait and the BUG-334 fix do.",
    });
}
