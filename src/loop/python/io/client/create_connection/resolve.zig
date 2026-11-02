const types = @import("types.zig");
const connect_mod = @import("connect.zig");
const set_future_exception = Future.Python.Result.set_future_exception;
const SocketCreationData = types.SocketCreationData;
const SocketConnectionData = types.SocketConnectionData;
const create_socket_connection = connect_mod.create_socket_connection;
const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");

const Loop = @import("../../../../main.zig");

const Future = @import("../../../../../future/main.zig");

pub fn get_host_slice(data: *SocketCreationData) ![]const u8 {
    const py_host = data.py_host orelse {
        python_c.raise_python_value_error("Host is required");
        return error.PythonError;
    };

    if (!python_c.unicode_check(py_host)) {
        python_c.raise_python_value_error("Host must be a valid string");
        return error.PythonError;
    }

    var host_ptr_lenght: python_c.Py_ssize_t = undefined;
    const host_ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &host_ptr_lenght) orelse return error.PythonError;

    return host_ptr[0..@intCast(host_ptr_lenght)];
}

pub fn z_try_resolv_host(creation_data: *SocketCreationData) !void {
    const hostname = try get_host_slice(creation_data);

    const loop_data = utils.get_data_ptr(Loop, creation_data.loop.?);
    const allocator = loop_data.allocator;

    const connection_data = try allocator.create(SocketConnectionData);
    errdefer allocator.destroy(connection_data);
    connection_data.* = .{
        .creation_data = creation_data,
        .address_list = null,
        .local_addr_list = null,
        .method = undefined,
        .python_payload = .{
            .module_ptr = @ptrCast(creation_data.loop.?),
            .callback_ptr = @ptrCast(creation_data.future.?),
            .traverse = &SocketConnectionData.traverse,
        },
        .dns_timeout = creation_data.dns_timeout,
    };

    const resolver_callback = CallbackManager.Callback{
        .func = &host_resolved_callback,
        .cleanup = null,
        .data = CallbackManager.CallbackData.init_python(connection_data, &connection_data.python_payload),
    };
    const address_list = try loop_data.dns.lookup(hostname, &resolver_callback, connection_data.dns_timeout) orelse return;

    connection_data.address_list = try allocator.dupe(utils.Address, address_list);
    errdefer allocator.free(connection_data.address_list.?);

    const callback = CallbackManager.Callback{
        .func = &create_socket_connection,
        .cleanup = null,
        .data = CallbackManager.CallbackData.init_python(connection_data, &connection_data.python_payload),
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

pub fn try_resolv_host(data: *const CallbackManager.CallbackData) !void {
    const socket_creation_data_ptr: *SocketCreationData = @ptrCast(@alignCast(data.user_data.?));

    // BUG-354: capture the future up front — the cleanup below frees the
    // creation data (dropping its own future reference), and
    // `set_future_exception` returns void so no `errdefer` runs.
    const future = socket_creation_data_ptr.future.?;

    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Event for trying host resolution cancelled");
        python_c.py_incref(@ptrCast(future));
        defer python_c.py_decref(@ptrCast(future));
        socket_creation_data_ptr.deinit();
        return set_future_exception(error.PythonError, future);
    }

    z_try_resolv_host(socket_creation_data_ptr) catch |err| {
        python_c.py_incref(@ptrCast(future));
        defer python_c.py_decref(@ptrCast(future));
        socket_creation_data_ptr.deinit();
        return set_future_exception(err, future);
    };
}

// -----------------------------------------------------------------
// Step#2: Process host resolution result

pub fn z_host_resolved_callback(connection_data: *SocketConnectionData) !void {
    const creation_data = connection_data.creation_data;
    const loop_data = utils.get_data_ptr(Loop, creation_data.loop.?);
    const allocator = loop_data.allocator;

    const host = try get_host_slice(creation_data);
    const address_list = try loop_data.dns.lookup(host, null, creation_data.dns_timeout) orelse {
        // BUG-354: report failure via error — the caller owns the
        // connection data and performs the cleanup before setting the
        // future exception.
        return error.DnsResolutionFailed;
    };

    connection_data.address_list = try allocator.dupe(utils.Address, address_list);
    const callback = CallbackManager.Callback{
        .func = &create_socket_connection,
        .cleanup = null,
        .data = CallbackManager.CallbackData.init_python(connection_data, &connection_data.python_payload),
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

pub fn host_resolved_callback(data: *const CallbackManager.CallbackData) !void {
    const connection_data: *SocketConnectionData = @ptrCast(@alignCast(data.user_data.?));

    if (data.cancelled()) {
        python_c.raise_python_runtime_error("Host resolution failed");
        // BUG-354: `set_future_exception` returns void, so the old
        // `errdefer connection_data.deinit()` never ran on this path,
        // leaking the heap structs and every owned PyObject reference.
        // Clean up explicitly, keeping the future alive across deinit.
        const future = connection_data.creation_data.future.?;
        python_c.py_incref(@ptrCast(future));
        defer python_c.py_decref(@ptrCast(future));
        connection_data.deinit();
        return set_future_exception(error.PythonError, future);
    }

    z_host_resolved_callback(connection_data) catch |err| {
        const future = connection_data.creation_data.future.?;
        python_c.py_incref(@ptrCast(future));
        defer python_c.py_decref(@ptrCast(future));
        connection_data.deinit();
        switch (err) {
            error.DnsResolutionFailed => python_c.raise_python_runtime_error("Failed to resolve host"),
            // error.PythonError already left an exception set; anything
            // else is mapped by handle_zig_function_error (and again,
            // idempotently, by set_future_exception below).
            else => utils.handle_zig_function_error(err, {}),
        }
        return set_future_exception(err, future);
    };
}

// -----------------------------------------------------------------
// STEP#3: Create socket and submit connect events

// -----------------------------------------------------------------
// STEP#3: Create socket and submit connect events
