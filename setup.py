import os
import platform
import shutil
import stat
import subprocess
import sys
import sysconfig

from setuptools import Command, Distribution, setup
from setuptools.command.build import build
from setuptools.command.build_ext import build_ext
from setuptools.command.develop import develop

if sys.version_info < (3, 13):
    raise RuntimeError("talyn requires Python 3.13 or later")

zig_mode = os.environ.get("TALYN_OPTIMIZE", "Debug")
zig_compiler_options = []

zig_target = os.environ.get("TALYN_TARGET")

# Detect cross-compilation (Zig cross-compiles the native extension to a
# different CPU architecture than the running Python). When cross-building,
# the host's libpython is the wrong ELF architecture and cannot be linked.
# Linux CPython extension modules do not need to link libpython: the
# interpreter exports the C API and the dynamic linker resolves those
# symbols at import time.
is_cross_build = False
if zig_target:
    zig_compiler_options.append(f"-Dtarget={zig_target}")
    guest_arch = zig_target.split("-")[0]
    host_arch = platform.machine()
    if guest_arch in ("arm64", "aarch64"):
        guest_arch = "aarch64"
    if host_arch == "arm64":
        host_arch = "aarch64"
    if host_arch != guest_arch:
        is_cross_build = True

zig_cpu = os.environ.get("TALYN_CPU")
if zig_cpu:
    zig_compiler_options.append(f"-Dcpu={zig_cpu}")

include_dir = sysconfig.get_config_var("INCLUDEPY")
zig_compiler_options.append(f"-Dpython-include-dir={include_dir}")

if is_cross_build:
    pass
else:
    so_path = sysconfig.get_config_var("LIBDIR")
    so_name = sysconfig.get_config_var("INSTSONAME")
    full_path = f"{so_path}/{so_name}"
    zig_compiler_options.append(f"-Dpython-lib-dir={so_path}")
    zig_compiler_options.append(f"-Dpython-lib={full_path}")

is_gil_enabled = sys._is_gil_enabled()  # type: ignore
if not is_gil_enabled:
    zig_compiler_options.append("-Dpython-gil-disabled")

# AddressSanitizer build: TALYN_ASAN=1 forwards -Dasan to the Zig build so the
# resulting extension is ASAN-instrumented (catches malloc-backed heap
# double-free / use-after-free regressions such as BUG-118/119/120).
if os.environ.get("TALYN_ASAN"):
    zig_compiler_options.append("-Dasan")

# Memory-safety checker build: TALYN_DEBUG_ALLOC=1 swaps talyn's heap allocator
# for std.heap.DebugAllocator(.{ .safety = true }), which detects double-free /
# invalid frees / leaks at runtime (the Zig-native equivalent of AddressSanitizer,
# which is unavailable in Zig 0.16). See `zig build -Ddebug-alloc`.
if os.environ.get("TALYN_DEBUG_ALLOC"):
    zig_compiler_options.append("-Ddebug-alloc")


def cross_ext_suffix(ext_suffix: str) -> str:
    """Rewrite EXT_SUFFIX for a cross build.

    EXT_SUFFIX encodes the running (host) interpreter's SOABI, e.g.
    ``.cpython-314t-x86_64-linux-gnu.so``. A wheel built for a foreign
    architecture must name its native module with the *guest* machine's SOABI,
    otherwise the target interpreter cannot find the extension at import time.
    """
    assert zig_target is not None
    host_machine = platform.machine()
    guest_machine = zig_target.split("-")[0]
    if guest_machine in ("arm64", "aarch64"):
        guest_machine = "aarch64"
    if host_machine in ("arm64", "aarch64"):
        host_machine = "aarch64"
    if host_machine == guest_machine:
        return ext_suffix
    return ext_suffix.replace(host_machine, guest_machine, 1)


class BinaryDistribution(Distribution):
    """Distribution which always forces a binary package"""

    def has_ext_modules(self) -> bool:
        return True


class TalynBench(Command):
    def initialize_options(self) -> None:
        pass

    def finalize_options(self) -> None:
        pass

    def run(self) -> None:
        global zig_mode
        zig_mode = "ReleaseFast"

        self.run_command("build")

        build_lib_path = os.path.join("build", "lib")
        benchmarks_path = os.path.join(build_lib_path, "benchmarks")
        benchmark_py_path = os.path.join(build_lib_path, "benchmark.py")
        shutil.copytree("./benchmarks", benchmarks_path, dirs_exist_ok=True)
        shutil.copyfile("./benchmark.py", benchmark_py_path)

        errno = subprocess.call([sys.executable, "benchmark.py"], cwd=build_lib_path)

        shutil.rmtree(benchmarks_path)
        os.remove(benchmark_py_path)

        raise SystemExit(errno)


class TalynTest(Command):
    def initialize_options(self) -> None:
        pass

    def finalize_options(self) -> None:
        pass

    def run(self) -> None:
        subprocess.check_call(["zig", "build", "test", *zig_compiler_options])
        self.run_command("build")

        errno = subprocess.call(
            [
                sys.executable,
                "-m",
                "pytest",
                "-s",
                "-x",
                "--verbose",
                "--full-trace",
                "--cov=talyn",
                "--cov-report=term",
                "--cov-report=html",
                "--cov-config=.coveragerc",
            ],
            cwd=os.path.join("build", "lib"),
        )
        raise SystemExit(errno)


class ZigBuildExtCommand(build_ext):
    def run(self) -> None:
        subprocess.check_call(
            ["zig", "build", "install", f"-Doptimize={zig_mode}", *zig_compiler_options]
        )
        self.copy_zig_files()

    def copy_zig_files(self) -> None:
        build_dir = "./zig-out/lib"

        ext_suffix = sysconfig.get_config_var("EXT_SUFFIX")
        if is_cross_build:
            ext_suffix = cross_ext_suffix(ext_suffix)
        src_path = os.path.join(build_dir, "libtalyn.so")
        dest_path = os.path.join(self.build_lib, "talyn", f"talyn_zig{ext_suffix}")
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        shutil.copyfile(src_path, dest_path)

        st = os.stat(dest_path)
        os.chmod(dest_path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class ZigBuildCommand(build):
    def run(self) -> None:
        self.run_command("build_py")

        tests_path = os.path.join(self.build_lib, "tests")
        shutil.copytree("./tests", tests_path, dirs_exist_ok=True)

        self.run_command("build_ext")


class ZigDevelopCommand(develop):
    def run(self) -> None:
        self.run_command("build")
        super().run()


# Setuptools execution with custom build commands
setup(
    distclass=BinaryDistribution,
    cmdclass={
        "build_ext": ZigBuildExtCommand,
        "build": ZigBuildCommand,
        "develop": ZigDevelopCommand,
        "bench": TalynBench,
        "test": TalynTest,
    },
)
