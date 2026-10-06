#define PY_SSIZE_T_CLEAN
#define _FORTIFY_SOURCE 0
#define __USE_FORTIFY_LEVEL 0
#include <Python.h>
#include <arpa/inet.h>
#undef Py_INCREF
#undef Py_DECREF
