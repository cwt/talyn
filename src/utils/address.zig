const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

pub const Address = extern union {
    any: std.posix.sockaddr,
    in: PosixAddress.IN,
    in6: PosixAddress.IN6,
    un: std.posix.sockaddr.un,

    pub fn initIp4(ip: [4]u8, port: u16) Address {
        return .{
            .in = .{
                .sa = .{
                    .addr = @as(u32, @bitCast(ip)),
                    .port = std.mem.nativeToBig(u16, port),
                    .zero = .{0} ** 8,
                },
            },
        };
    }

    pub fn initIp6(ip: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        return .{
            .in6 = .{
                .sa = .{
                    .port = std.mem.nativeToBig(u16, port),
                    .flowinfo = flowinfo,
                    .addr = ip,
                    .scope_id = scope_id,
                },
            },
        };
    }

    pub fn initPosix(sa_ptr: *const anyopaque) Address {
        const sa: *const std.posix.sockaddr = @alignCast(@ptrCast(sa_ptr));
        return switch (sa.family) {
            std.posix.AF.INET => .{
                .in = .{
                    .sa = @as(*const std.posix.sockaddr.in, @alignCast(@ptrCast(sa_ptr))).*,
                },
            },
            std.posix.AF.INET6 => .{
                .in6 = .{
                    .sa = @as(*const std.posix.sockaddr.in6, @alignCast(@ptrCast(sa_ptr))).*,
                },
            },
            std.posix.AF.UNIX => .{
                .un = @as(*const std.posix.sockaddr.un, @alignCast(@ptrCast(sa_ptr))).*,
            },
            else => .{ .any = sa.* },
        };
    }

    pub fn getPort(self: Address) u16 {
        return switch (self.any.family) {
            std.posix.AF.INET => std.mem.bigToNative(u16, self.in.sa.port),
            std.posix.AF.INET6 => std.mem.bigToNative(u16, self.in6.sa.port),
            else => 0,
        };
    }

    pub fn setPort(self: *Address, port: u16) void {
        switch (self.any.family) {
            std.posix.AF.INET => {
                self.in.sa.port = std.mem.nativeToBig(u16, port);
            },
            std.posix.AF.INET6 => {
                self.in6.sa.port = std.mem.nativeToBig(u16, port);
            },
            else => {},
        }
    }

    pub fn getOsSockLen(self: Address) std.posix.socklen_t {
        return switch (self.any.family) {
            std.posix.AF.INET => @sizeOf(std.posix.sockaddr.in),
            std.posix.AF.INET6 => @sizeOf(std.posix.sockaddr.in6),
            std.posix.AF.UNIX => @sizeOf(std.posix.sockaddr.un),
            else => @sizeOf(std.posix.sockaddr.storage),
        };
    }

    pub fn resolveIp(host: []const u8, port: u16) !Address {
        return parseIp4(host, port);
    }

    pub fn resolveIp6(host: []const u8, port: u16) !Address {
        return parseIp6(host, port);
    }

    pub fn parseIp(host: []const u8, port: u16) !Address {
        return parseIp4(host, port) catch |err| {
            if (err == error.InvalidIPAddressFormat) return parseIp6(host, port);
            return err;
        };
    }

    pub fn parseIp4(host: []const u8, port: u16) !Address {
        var bytes: [4]u8 = undefined;
        var octet_i: usize = 0;
        var i: usize = 0;
        while (i < host.len) {
            if (octet_i >= 4) return error.InvalidIPAddressFormat;
            // BUG-69: Reject leading zeros in octets (e.g., "010").
            // The previous code accepted "010" as decimal 10, but
            // some system parsers (and glibc since 2.34) treat it
            // as octal 8, leading to address mismatches. The
            // modern behavior (matching inet_pton and Python's
            // ipaddress) is to reject leading zeros to avoid
            // ambiguity. A single "0" is still valid.
            if (host[i] == '0' and i + 1 < host.len and host[i + 1] != '.') {
                return error.InvalidIPAddressFormat;
            }
            var val: u16 = 0;
            const octet_start = i;
            while (i < host.len and host[i] != '.') : (i += 1) {
                if (host[i] < '0' or host[i] > '9') return error.InvalidIPAddressFormat;
                val = val * 10 + (host[i] - '0');
            }
            if (i == octet_start) return error.InvalidIPAddressFormat;
            if (val > 255) return error.InvalidIPAddressFormat;
            bytes[octet_i] = @intCast(val);
            octet_i += 1;
            if (i < host.len) i += 1;
        }
        if (octet_i != 4) return error.InvalidIPAddressFormat;
        return initIp4(bytes, port);
    }

    pub fn parseIp6(host: []const u8, port: u16) !Address {
        var bytes: [16]u8 = .{0} ** 16;
        var groups: [8]u16 = .{0} ** 8;
        var group_i: usize = 0;
        var double_colon: bool = false;
        var i: usize = 0;

        if (host.len >= 2 and host[0] == ':' and host[1] == ':') {
            double_colon = true;
            i = 2;
        } else if (host.len > 0 and host[0] == ':') {
            return error.InvalidCharacter;
        }

        while (i < host.len and group_i < 8) {
            var val: u16 = 0;
            var digits: usize = 0;
            while (i < host.len and host[i] != ':') : (i += 1) {
                val <<= 4;
                val += switch (host[i]) {
                    '0'...'9' => @as(u16, host[i] - '0'),
                    'a'...'f' => @as(u16, host[i] - 'a' + 10),
                    'A'...'F' => @as(u16, host[i] - 'A' + 10),
                    else => return error.InvalidCharacter,
                };
                digits += 1;
                if (digits > 4) return error.InvalidCharacter;
            }
            groups[group_i] = val;
            group_i += 1;
            if (i < host.len) {
                if (double_colon) return error.InvalidCharacter;
                i += 1;
                if (i < host.len and host[i] == ':') {
                    double_colon = true;
                    i += 1;
                }
            }
        }

        var target_i: usize = 0;
        if (double_colon) {
            const before = group_i;
            for (0..before) |j| {
                const g = groups[j];
                bytes[target_i * 2] = @as(u8, @intCast(g >> 8));
                bytes[target_i * 2 + 1] = @as(u8, @intCast(g & 0xFF));
                target_i += 1;
            }
            target_i = 8 - (group_i - before);
            for (before..group_i) |j| {
                const g = groups[j];
                bytes[target_i * 2] = @as(u8, @intCast(g >> 8));
                bytes[target_i * 2 + 1] = @as(u8, @intCast(g & 0xFF));
                target_i += 1;
            }
        } else {
            // BUG-47: Without a `::` shorthand, the address must contain
            // exactly 8 groups. The original code would silently accept
            // incomplete addresses like `1:2:3:4:5:6:7` by writing only 7
            // groups to the 16-byte buffer and leaving the remaining 2
            // bytes as zero — effectively zero-padding the 8th group.
            // That's ambiguous (the user might have meant to write 8
            // groups) and silently transforms an invalid address into a
            // valid one, which can lead to connection attempts to
            // unexpected hosts. Now we reject the address explicitly.
            if (group_i != 8) {
                return error.IncompleteAddress;
            }
            for (0..group_i) |j| {
                const g = groups[j];
                bytes[target_i * 2] = @as(u8, @intCast(g >> 8));
                bytes[target_i * 2 + 1] = @as(u8, @intCast(g & 0xFF));
                target_i += 1;
            }
        }

        return initIp6(bytes, port, 0, 0);
    }

    pub fn toPyAddr(self: Address) !PyObject {
        switch (self.any.family) {
            std.posix.AF.INET => {
                const sa = self.in.sa;
                var buf: [16]u8 = undefined;
                const host_ptr = python_c._c.inet_ntop(std.posix.AF.INET, &sa.addr, &buf, 16) orelse return error.SystemResources;
                const host_len = std.mem.len(host_ptr);
                const port = self.getPort();

                const py_host = python_c.PyUnicode_FromStringAndSize(host_ptr, @intCast(host_len)) orelse return error.PythonError;
                defer python_c.py_decref(py_host);
                const py_port = python_c.PyLong_FromLong(port) orelse return error.PythonError;
                defer python_c.py_decref(py_port);
                return python_c.PyTuple_Pack(2, py_host, py_port) orelse error.PythonError;
            },
            std.posix.AF.INET6 => {
                const sa = self.in6.sa;
                var buf: [46]u8 = undefined;
                const host_ptr = python_c._c.inet_ntop(std.posix.AF.INET6, &sa.addr, &buf, 46) orelse return error.SystemResources;
                const host_len = std.mem.len(host_ptr);
                const port = self.getPort();

                const py_host = python_c.PyUnicode_FromStringAndSize(host_ptr, @intCast(host_len)) orelse return error.PythonError;
                defer python_c.py_decref(py_host);
                const py_port = python_c.PyLong_FromLong(port) orelse return error.PythonError;
                defer python_c.py_decref(py_port);

                const py_flow = python_c.PyLong_FromUnsignedLongLong(sa.flowinfo) orelse return error.PythonError;
                defer python_c.py_decref(py_flow);
                const py_scope = python_c.PyLong_FromUnsignedLongLong(sa.scope_id) orelse return error.PythonError;
                defer python_c.py_decref(py_scope);

                return python_c.PyTuple_Pack(4, py_host, py_port, py_flow, py_scope) orelse error.PythonError;
            },
            std.posix.AF.UNIX => {
                const sa = self.un;
                const path = std.mem.span(@as([*:0]const u8, @ptrCast(&sa.path)));
                return python_c.PyUnicode_FromStringAndSize(path.ptr, @intCast(path.len)) orelse error.PythonError;
            },
            else => return error.UnsupportedAddressFamily,
        }
    }

    pub fn toPyAddrWithPort(self: Address, port: u16) !PyObject {
        switch (self.any.family) {
            std.posix.AF.INET => {
                const sa = self.in.sa;
                var buf: [16]u8 = undefined;
                const host_ptr = python_c._c.inet_ntop(std.posix.AF.INET, &sa.addr, &buf, 16) orelse return error.SystemResources;
                const host_len = std.mem.len(host_ptr);

                const py_host = python_c.PyUnicode_FromStringAndSize(host_ptr, @intCast(host_len)) orelse return error.PythonError;
                defer python_c.py_decref(py_host);
                const py_port = python_c.PyLong_FromLong(port) orelse return error.PythonError;
                defer python_c.py_decref(py_port);
                return python_c.PyTuple_Pack(2, py_host, py_port) orelse error.PythonError;
            },
            std.posix.AF.INET6 => {
                const sa = self.in6.sa;
                var buf: [46]u8 = undefined;
                const host_ptr = python_c._c.inet_ntop(std.posix.AF.INET6, &sa.addr, &buf, 46) orelse return error.SystemResources;
                const host_len = std.mem.len(host_ptr);

                const py_host = python_c.PyUnicode_FromStringAndSize(host_ptr, @intCast(host_len)) orelse return error.PythonError;
                defer python_c.py_decref(py_host);
                const py_port = python_c.PyLong_FromLong(port) orelse return error.PythonError;
                defer python_c.py_decref(py_port);

                const py_flow = python_c.PyLong_FromUnsignedLongLong(sa.flowinfo) orelse return error.PythonError;
                defer python_c.py_decref(py_flow);
                const py_scope = python_c.PyLong_FromUnsignedLongLong(sa.scope_id) orelse return error.PythonError;
                defer python_c.py_decref(py_scope);

                return python_c.PyTuple_Pack(4, py_host, py_port, py_flow, py_scope) orelse error.PythonError;
            },
            std.posix.AF.UNIX => {
                const sa = self.un;
                const path = std.mem.span(@as([*:0]const u8, @ptrCast(&sa.path)));
                return python_c.PyUnicode_FromStringAndSize(path.ptr, @intCast(path.len)) orelse error.PythonError;
            },
            else => return error.UnsupportedAddressFamily,
        }
    }

    pub fn fromPyAddr(py_addr: PyObject, family: ?i32) !Address {
        if (python_c.unicode_check(py_addr)) {
            var size: python_c.Py_ssize_t = 0;
            const ptr = python_c.PyUnicode_AsUTF8AndSize(py_addr, &size) orelse return error.PythonError;
            const path = ptr[0..@intCast(size)];
            if (path.len >= 108) return error.NameTooLong;

            var sun: std.posix.sockaddr.un = undefined;
            @memset(std.mem.asBytes(&sun), 0);
            sun.family = std.posix.AF.UNIX;
            @memcpy(sun.path[0..path.len], path);
            sun.path[path.len] = 0;
            return .{ .un = sun };
        }

        if (python_c.PyTuple_Check(py_addr) <= 0) {
            python_c.raise_python_type_error("address must be a tuple\x00");
            return error.PythonError;
        }
        const py_size = python_c.PyTuple_Size(py_addr);

        const py_host = python_c.PyTuple_GetItem(py_addr, 0) orelse return error.PythonError;
        const py_port = python_c.PyTuple_GetItem(py_addr, 1) orelse return error.PythonError;

        var host_size: python_c.Py_ssize_t = 0;
        const host_ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &host_size) orelse return error.PythonError;
        const host = host_ptr[0..@intCast(host_size)];
        const port: u16 = @intCast(python_c.PyLong_AsInt(py_port));

        if (py_size == 2) {
            if (family == std.posix.AF.INET6 or std.mem.indexOfScalar(u8, host, ':') != null) {
                return Address.parseIp6(host, port);
            } else {
                return Address.parseIp4(host, port);
            }
        } else if (py_size == 4) {
            const py_flow = python_c.PyTuple_GetItem(py_addr, 2) orelse return error.PythonError;
            const py_scope = python_c.PyTuple_GetItem(py_addr, 3) orelse return error.PythonError;

            const flowinfo: u32 = @intCast(python_c.PyLong_AsUnsignedLong(py_flow));
            const scope_id: u32 = @intCast(python_c.PyLong_AsUnsignedLong(py_scope));

            var addr = try Address.parseIp6(host, port);
            addr.in6.sa.flowinfo = flowinfo;
            addr.in6.sa.scope_id = scope_id;
            return addr;
        }

        return error.InvalidAddress;
    }
};

const PosixAddress = struct {
    pub const IN = extern struct {
        sa: std.posix.sockaddr.in,
    };
    pub const IN6 = extern struct {
        sa: std.posix.sockaddr.in6,
    };
};
