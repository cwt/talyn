pub const LinkedList = @import("linked_list.zig").LinkedList;
pub const BTree = @import("btree.zig").BTree;
pub const PythonImports = @import("python_imports.zig");
pub const PseudoSocket = @import("pseudosocket.zig");
pub const LRUCache = @import("lru.zig").LRUCache;
pub const address_mod = @import("address.zig");
pub const Address = address_mod.Address;

const std = @import("std");
const builtin = @import("builtin");

const python_c = @import("python_c");
pub const gpa = struct {
    pub fn allocator(_: @This()) std.mem.Allocator {
        return std.heap.c_allocator;
    }
    pub fn deinit(_: @This()) void {}
}{};

pub fn init_gpa() void {}

pub inline fn get_data_ptr2(comptime T: type, comptime field_name: []const u8, talyn_pyobject: anytype) *T {
    const type_info = @typeInfo(@TypeOf(talyn_pyobject));
    if (type_info != .pointer) {
        @compileError("talyn_pyobject must be a pointer");
    }

    if (type_info.pointer.size != .one) {
        @compileError("talyn_pyobject must be a single pointer");
    }

    if (!@hasField(type_info.pointer.child, field_name)) {
        @compileError("Field not available");
    }

    return @as(*T, @ptrFromInt(@intFromPtr(talyn_pyobject) + @offsetOf(type_info.pointer.child, field_name)));
}

pub inline fn get_data_ptr(comptime T: type, talyn_pyobject: anytype) *T {
    return get_data_ptr2(T, "data", talyn_pyobject);
}

pub inline fn get_parent_ptr(comptime T: type, talyn_object: anytype) *T {
    const type_info = @typeInfo(@TypeOf(talyn_object));
    if (type_info != .pointer) {
        @compileError("talyn_pyobject must be a pointer");
    }

    if (type_info.pointer.size != .one) {
        @compileError("talyn_pyobject must be a single pointer");
    }
    
    return @as(*T, @ptrFromInt(@intFromPtr(talyn_object) - @offsetOf(T, "data")));
}

fn get_func_return_type(func: anytype) type {
    const func_type_info = @typeInfo(@TypeOf(func));
    if (func_type_info != .@"fn") {
        @compileError("func argument must be a function");
    }

    const return_type_info = func_type_info.@"fn".return_type orelse @compileError("func must have a return type");
    const return_type = @typeInfo(return_type_info);
    if (return_type != .error_union) {
        @compileError("return type must be an error union");
    }

    const return_payload = return_type.error_union.payload;
    return switch (@typeInfo(return_payload)) {
        .int, .@"enum" => return_payload,
        .noreturn => @compileError("return type must not be noreturn"),
        else => ?return_payload
    };
}

pub inline fn handle_zig_function_error(@"error": anyerror, return_value: anytype) @TypeOf(return_value) {
    switch (@"error") {
        error.PythonError => {},
        error.OutOfMemory => python_c.raise_python_error(python_c.PyExc_MemoryError.?, null),
        error.AddressNotAvailable, error.SystemResources => {
            python_c.raise_python_error(python_c.PyExc_OSError.?, @errorName(@"error"));
        },
        error.SignalInterrupt => {
            // Silently raise this as a RuntimeError. It should be caught by the loop retry logic
            // but if it escapes to Python, we don't want to crash.
            python_c.raise_python_runtime_error(@errorName(@"error"));
        },
        else => {
            // In release/production we might want to be more quiet, but for now
            // let's just raise the exception without the messy/crashing stack dump.
            python_c.raise_python_runtime_error(@errorName(@"error"));
        }
    }

    return return_value;
}

pub inline fn execute_zig_function(func: anytype, args: anytype) get_func_return_type(func) {
    return @call(.auto, func, args) catch |err| {
        const return_value = blk: {
            const ret_type = get_func_return_type(func);
            const ret_type_info = @typeInfo(ret_type);
            if (ret_type_info == .int) {
                if (ret_type_info.int.signedness == .signed) {
                    break :blk -1;
                }else{
                    break :blk 0;
                }
            }
            break :blk null;
        };

        return handle_zig_function_error(err, return_value);
    };
}

pub fn getSyscallErrno(rc: usize) std.posix.E {
    const signed = @as(isize, @bitCast(rc));
    if (signed > -4096 and signed < 0) {
        return @enumFromInt(-signed);
    }
    return .SUCCESS;
}

test {
    std.testing.refAllDecls(@This());
}
