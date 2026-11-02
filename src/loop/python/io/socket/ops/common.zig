const python_c = @import("python_c");
const utils = @import("utils");

/// BUG-356: `set_future_exception` STEALS the pending Python exception
/// (`PyErr_GetRaisedException`); if none is set it silently does nothing
/// and the future stays pending forever (infinite hang on `await`).
pub fn ensure_exception(err: anyerror) void {
    if (python_c.PyErr_Occurred() == null) {
        if (err == error.PythonError) {
            python_c.raise_python_runtime_error("Socket operation failed");
        } else {
            utils.handle_zig_function_error(err, {});
        }
    }
}
