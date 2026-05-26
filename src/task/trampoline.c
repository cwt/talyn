#include <Python.h>

PyObject* leviathan_task_step_trampoline(
    PyObject *enter_task_func,
    PyObject *leave_task_func,
    PyObject *loop,
    PyObject *task,
    PyObject *coro,
    PyObject *context,
    PyObject *send_val,
    int *send_result_out,
    PyObject **coro_ret_out
) {
    PyObject *args[2] = {loop, task};
    
    // 1. Enter task
    PyObject *enter_ret = PyObject_Vectorcall(enter_task_func, args, 2, NULL);
    if (!enter_ret) return NULL;
    Py_DECREF(enter_ret);

    // 2. Enter context
    if (PyContext_Enter(context) < 0) return NULL;

    // 3. Send
    PyObject *coro_ret = NULL;
    PySendResult gen_ret = PyIter_Send(coro, send_val, &coro_ret);

    // 4. Exit context
    if (PyContext_Exit(context) < 0) {
        Py_XDECREF(coro_ret);
        return NULL;
    }

    // Save active exception to avoid SystemError during _leave_task call
    PyObject *exc_type = NULL, *exc_val = NULL, *exc_tb = NULL;
    PyErr_Fetch(&exc_type, &exc_val, &exc_tb);

    // 5. Leave task
    PyObject *leave_ret = PyObject_Vectorcall(leave_task_func, args, 2, NULL);
    
    // Restore the exception
    PyErr_Restore(exc_type, exc_val, exc_tb);

    if (!leave_ret) {
        Py_XDECREF(coro_ret);
        return NULL;
    }
    Py_DECREF(leave_ret);

    *send_result_out = (int)gen_ret;
    *coro_ret_out = coro_ret;
    Py_RETURN_NONE;
}
