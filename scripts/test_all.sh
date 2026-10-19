#!/usr/bin/env bash
# Compatible with bash 3.x (macOS) and 4.x+
# Usage: bash scripts/test_all.sh [options]
set -eu

# Trap signals so child processes are cleaned up on CTRL-C
CLEANUP_LOGS=true
cleanup_pids() {
    local pids
    pids="$(jobs -p 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
    fi
    wait 2>/dev/null || true
}

cleanup() {
    cleanup_pids
    if [ -n "${LOG_DIR:-}" ] && [ -d "$LOG_DIR" ] && [ "${CLEANUP_LOGS:-true}" = true ]; then
        rm -rf "$LOG_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ulimit -n 4096 2>/dev/null || true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

OPTIMIZE_MODE="Debug"
SELECTED_PYTHONS="3.13 3.14 3.13t 3.14t"
VERBOSE=false
NO_BUILD=false
ZIG16="${ZIG16:-}"
ZIG17="${ZIG17:-}"
JOBS=""
SEQUENTIAL=false

while [ $# -gt 0 ]; do
    case "$1" in
        --starburst|--releasefast)
            OPTIMIZE_MODE="ReleaseFast"
            ;;
        --safe)
            OPTIMIZE_MODE="ReleaseSafe"
            ;;
        --no-build)
            # Use prebuilt talyn_zig*.so files already present in talyn/ and
            # skip all Zig compilation (including `zig build test`).
            NO_BUILD=true
            ;;
        --verbose)
            VERBOSE=true
            ;;
        --sequential)
            SEQUENTIAL=true
            ;;
        --jobs=*)
            JOBS="${1#--jobs=}"
            ;;
        --jobs)
            shift
            JOBS="$1"
            ;;
        -j)
            shift
            JOBS="$1"
            ;;
        -j*)
            JOBS="${1#-j}"
            ;;
        --zig16=*)
            ZIG16="${1#--zig16=}"
            ;;
        --zig16)
            shift
            ZIG16="$1"
            ;;
        --zig17=*)
            ZIG17="${1#--zig17=}"
            ;;
        --zig17)
            shift
            ZIG17="$1"
            ;;
        --python=*)
            raw="${1#--python=}"
            SELECTED_PYTHONS=""
            IFS=',' read -ra _parts <<< "$raw"
            for p in "${_parts[@]}"; do
                case "$p" in
                    3.13|3.14|3.13t|3.14t)
                        SELECTED_PYTHONS="${SELECTED_PYTHONS:+${SELECTED_PYTHONS} }$p"
                        ;;
                    *)
                        echo "Unknown Python in --python=: $p" >&2
                        echo "Valid values: 3.13, 3.14, 3.13t, 3.14t" >&2
                        exit 2
                        ;;
                esac
            done
            ;;
        --python)
            shift
            raw="$1"
            SELECTED_PYTHONS=""
            IFS=',' read -ra _parts <<< "$raw"
            for p in "${_parts[@]}"; do
                case "$p" in
                    3.13|3.14|3.13t|3.14t)
                        SELECTED_PYTHONS="${SELECTED_PYTHONS:+${SELECTED_PYTHONS} }$p"
                        ;;
                    *)
                        echo "Unknown Python in --python: $p" >&2
                        echo "Valid values: 3.13, 3.14, 3.13t, 3.14t" >&2
                        exit 2
                        ;;
                esac
            done
            ;;
        --help|-h)
            cat <<'EOF'
Usage: bash scripts/test_all.sh [options]

Options:
  --python=3.13,3.14t   Comma-separated list of Python versions to test
                        (subset of: 3.13, 3.14, 3.13t, 3.14t)
  -j, --jobs=N          Number of parallel test jobs (default: auto, capped at 4)
  --sequential          Run tests sequentially with live output (alias for -j 1)
  --starburst           Build with ReleaseFast
  --releasefast         Alias for --starburst
  --safe                Build with ReleaseSafe
  --no-build            Skip Zig compilation; use prebuilt talyn_zig*.so files
  --verbose             Show compiler and test output on failures
  --zig16=PATH          Path to Zig 0.16.x executable (or set ZIG16 env var)
  --zig17=PATH          Path to Zig 0.17.x executable (or set ZIG17 env var)
  -h, --help            Show this help
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$SEQUENTIAL" = true ]; then
    JOBS=1
fi

# ---- helpers ----

ensure_test_cert() {
    if [ ! -f /tmp/test_cert.pem ] || [ ! -f /tmp/test_key.pem ]; then
        openssl req -x509 -newkey rsa:4096 -keyout /tmp/test_key.pem \
            -out /tmp/test_cert.pem -days 365 -nodes \
            -subj "/CN=localhost" 2>/dev/null
    fi
}

clean() {
    rm -rf zig-out zig-cache .zig-cache .zig-cache16 .zig-cache17 .pytest_cache 2>/dev/null || true
    if [ "$NO_BUILD" != true ]; then
        rm -f talyn/talyn_zig*.so talyn/talyn_zig*.pyd 2>/dev/null || true
    fi
    find . -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    find . -name '*.pyc' -delete 2>/dev/null || true
}

get_python_lib() {
    local py="$1"
    local libdir soname
    libdir="$("$py" -c "import sysconfig; print(sysconfig.get_config_var('LIBDIR'))" 2>/dev/null)"
    soname="$("$py" -c "import sysconfig; print(sysconfig.get_config_var('INSTSONAME'))" 2>/dev/null)"
    echo "${libdir}/${soname}"
}

get_python_include() {
    local py="$1"
    "$py" -c "import sysconfig; print(sysconfig.get_config_var('INCLUDEPY'))" 2>/dev/null
}

is_free_threading() {
    local py="$1"
    "$py" -c "import sys; exit(0 if not sys._is_gil_enabled() else 1)" 2>/dev/null
}

has_timeout() {
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1
}

get_timeout_cmd() {
    if command -v timeout >/dev/null 2>&1; then echo "timeout"; else echo "gtimeout"; fi
}

# Per-test timeouts are calibrated for native speed:
#   TALYN_TEST_TIMEOUT   pytest suite per python (default 600s)
#   TALYN_STDLIB_TIMEOUT per standard-asyncio module (default 60s)
TALYN_TEST_TIMEOUT="${TALYN_TEST_TIMEOUT:-600}"
TALYN_STDLIB_TIMEOUT="${TALYN_STDLIB_TIMEOUT:-60}"

run_tests() {
    local py="$1" label="$2" cmd=""
    printf "${YELLOW}[%s]${NC} Running tests...\n" "$label"
    if has_timeout; then
        cmd="$(get_timeout_cmd) -k 5 $TALYN_TEST_TIMEOUT $py"
    else
        cmd="$py"
    fi
    if PYTHONPATH=. $cmd -m pytest tests/ -p no:cacheprovider -q; then
        printf "${GREEN}[%s] PASS${NC}\n" "$label"
        PASS=$((PASS + 1))
        return 0
    else
        local rc=$?
        if [ "$rc" -eq 139 ] 2>/dev/null; then
            printf "${YELLOW}[%s] SEGFAULT (pytest + free-threading — standalone tests pass)${NC}\n" "$label"
        else
            printf "${RED}[%s] FAIL${NC}\n" "$label"
        fi
        FAIL=$((FAIL + 1))
        return 1
    fi
}

run_std_tests() {
    local py="$1" label="$2" cmd=""
    printf "${YELLOW}[%s]${NC} Running standard asyncio tests...\n" "$label"

    local std_modules="
        test_futures        test_futures2
        test_transports     test_protocols
        test_streams        test_runners
        test_tasks
        test_locks
        test_queues
        test_timeouts       test_waitfor
        test_taskgroups
        test_pep492         test_threads
        test_staggered      test_graph
        test_tools          test_context
        test_eager_task_factory
        test_free_threading
        test_subprocess
        test_server
        test_sslproto
        test_sendfile       test_sock_lowlevel
    "

    local failed=0
    for mod in $std_modules; do
        if has_timeout; then
            cmd="$(get_timeout_cmd) -k 5 $TALYN_STDLIB_TIMEOUT $py"
        else
            cmd="$py"
        fi

        # Skip modules that don't exist in this Python version
        if ! PYTHONPATH=. $cmd -c "from test.test_asyncio import $mod" 2>/dev/null; then
            printf "  ${YELLOW}%s: SKIP (not in %s)${NC}\n" "$mod" "$py"
            continue
        fi

        if ( PYTHONPATH=. $cmd -c \
            "import talyn; talyn.install(); import unittest; from test.test_asyncio import $mod; unittest.main(module=$mod, exit=False, argv=['unittest', '-q'])"; exit $? ) \
            > /dev/null 2>&1; then
            printf "  ${GREEN}%s: PASS${NC}\n" "$mod"
        else
            local rc=$?
            if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
                printf "  ${YELLOW}%s: TIMEOUT${NC}\n" "$mod"
            elif [ "$rc" -eq 139 ]; then
                printf "  ${YELLOW}%s: SEGFAULT${NC}\n" "$mod"
            else
                printf "  ${RED}%s: FAIL${NC}\n" "$mod"
            fi
            failed=1
        fi
    done

    if [ "$failed" -eq 0 ]; then
        printf "${GREEN}[%s] STD PASS${NC}\n" "$label"
        PASS=$((PASS + 1))
        return 0
    else
        printf "${RED}[%s] STD FAIL${NC}\n" "$label"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

run_python_target() {
    local py="$1"
    local label="$2"
    local log_file="$3"
    local status_file="$4"

    local start_time=$SECONDS
    printf "${YELLOW}[%s]${NC} Running tests (pytest + standard asyncio)...\n" "$label"

    local rc_pytest=0
    run_tests "$py" "$label" >> "$log_file" 2>&1 || rc_pytest=$?

    local rc_std=0
    run_std_tests "$py" "$label" >> "$log_file" 2>&1 || rc_std=$?

    local elapsed=$((SECONDS - start_time))

    local pytest_summary
    pytest_summary="$(grep -E '[0-9]+ passed' "$log_file" | tail -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    if [ -z "$pytest_summary" ]; then
        if [ "$rc_pytest" -eq 0 ]; then
            pytest_summary="passed"
        else
            pytest_summary="failed"
        fi
    fi

    local std_summary
    if [ "$rc_std" -eq 0 ]; then
        std_summary="std passed"
    else
        std_summary="std failed"
    fi

    if [ "$rc_pytest" -eq 0 ]; then
        echo "PYTEST_STATUS=PASS" >> "$status_file"
    else
        echo "PYTEST_STATUS=FAIL" >> "$status_file"
    fi

    if [ "$rc_std" -eq 0 ]; then
        echo "STD_STATUS=PASS" >> "$status_file"
    else
        echo "STD_STATUS=FAIL" >> "$status_file"
    fi

    if [ "$rc_pytest" -eq 0 ] && [ "$rc_std" -eq 0 ]; then
        printf "${GREEN}[%s] PASS${NC} (%s; %s in %ds)\n" "$label" "$pytest_summary" "$std_summary" "$elapsed"
    else
        printf "${RED}[%s] FAIL${NC} (%s; %s in %ds)\n" "$label" "$pytest_summary" "$std_summary" "$elapsed"
    fi
}

run_zig_unit_tests() {
    local zig_bin="$1"
    local label="$2"
    local cache_dir="$3"
    local log_file="${4:-}"
    local status_file="${5:-}"

    local extra_flags=""
    if [ -n "$cache_dir" ]; then
        extra_flags="--cache-dir $cache_dir"
    fi

    local ver
    ver="$("$zig_bin" version 2>/dev/null || echo "unknown")"
    printf "${YELLOW}[%s]${NC} Running zig unit tests (%s)...\n" "$label" "$ver"

    if [ -n "$status_file" ]; then
        # Parallel mode
        local rc=0
        if $VERBOSE; then
            "$zig_bin" build test $extra_flags $ZIG_OPTS 2>&1 | grep -v 'failed command:' > "$log_file" 2>&1 || rc=$?
        else
            "$zig_bin" build test $extra_flags $ZIG_OPTS > "$log_file" 2>&1 || rc=$?
        fi

        if [ "$rc" -eq 0 ]; then
            local search_dir="${cache_dir:-.zig-cache}/o"
            local zig_bin_artifact
            zig_bin_artifact="$(ls -t "$search_dir"/*/talyn 2>/dev/null | head -n1 || true)"
            local summary="All tests passed"
            if [ -n "$zig_bin_artifact" ]; then
                local parsed
                parsed="$("$zig_bin_artifact" 2>&1 | grep -E "All .* tests passed" | tail -n1 || true)"
                if [ -n "$parsed" ]; then
                    summary="$parsed"
                fi
            fi
            echo "ZIG_STATUS=PASS" > "$status_file"
            printf "${GREEN}[%s] PASS${NC} (%s)\n" "$label" "$summary"
        else
            echo "ZIG_STATUS=FAIL" > "$status_file"
            printf "${RED}[%s] FAIL${NC}\n" "$label"
        fi
    else
        # Sequential mode
        local test_log
        test_log="$(mktemp)"
        local rc=0
        if $VERBOSE; then
            "$zig_bin" build test $extra_flags $ZIG_OPTS 2>&1 | grep -v 'failed command:' | tee "$test_log"
            rc=${PIPESTATUS[0]}
        else
            "$zig_bin" build test $extra_flags $ZIG_OPTS >"$test_log" 2>&1
            rc=$?
        fi

        if [ "$rc" -eq 0 ]; then
            local search_dir="${cache_dir:-.zig-cache}/o"
            local zig_bin_artifact
            zig_bin_artifact="$(ls -t "$search_dir"/*/talyn 2>/dev/null | head -n1 || true)"
            if [ -n "$zig_bin_artifact" ]; then
                local summary
                summary="$("$zig_bin_artifact" 2>&1 | grep -E "All .* tests passed" | tail -n1 || true)"
                if [ -n "$summary" ]; then
                    printf "   %s\n" "$summary"
                fi
            fi
            printf "${GREEN}[%s] PASS${NC}\n" "$label"
            PASS=$((PASS + 1))
        else
            printf "${RED}[%s] FAIL${NC}\n" "$label"
            if ! $VERBOSE; then
                tail -n 25 "$test_log"
            fi
            FAIL=$((FAIL + 1))
        fi
        rm -f "$test_log"
    fi
}

# ---- main ----

ensure_test_cert

echo "=== Talyn Test Suite ==="
echo ""

# Clean once at start — removes all stale build artifacts
clean

# Stage 1: Build extensions matrix
BUILT_PYTHONS=""
for ver in $SELECTED_PYTHONS; do
    py="python${ver}"
    if ! command -v "$py" >/dev/null 2>&1; then
        printf "${YELLOW}[%s]${NC} not found — skipping\n" "$py"
        continue
    fi

    lib="$(get_python_lib "$py")"
    inc="$(get_python_include "$py")"

    if [ ! -f "$lib" ]; then
        printf "${RED}[%s]${NC} lib not found at %s — skipping\n" "$py" "$lib"
        continue
    fi
    if [ ! -d "$inc" ]; then
        printf "${RED}[%s]${NC} include not found at %s — skipping\n" "$py" "$inc"
        continue
    fi

    if [ "$NO_BUILD" = true ]; then
        ext_suffix=$("$py" -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))")
        if [ ! -f "talyn/talyn_zig${ext_suffix}" ]; then
            printf "${RED}[%s]${NC} prebuilt extension talyn/talyn_zig${ext_suffix} not found (--no-build)\n" "$py"
            FAIL=$((FAIL + 1))
            continue
        fi
        BUILT_PYTHONS="${BUILT_PYTHONS:+${BUILT_PYTHONS} }$py"
    else
        printf "${YELLOW}[%s]${NC} Building extension...\n" "$py"

        # Clean zig-out between variants (different headers/libs)
        rm -rf zig-out 2>/dev/null || true

        gilflag=""
        if is_free_threading "$py"; then
            gilflag="-Dpython-gil-disabled=true"
        fi

        build_ok=true
        if $VERBOSE; then
            if ! zig build install -Doptimize=$OPTIMIZE_MODE \
                -Dpython-include-dir="$inc" \
                -Dpython-lib-dir="$(dirname "$lib")" \
                -Dpython-lib="$lib" \
                $gilflag; then
                build_ok=false
            fi
        else
            if ! zig build install -Doptimize=$OPTIMIZE_MODE \
                -Dpython-include-dir="$inc" \
                -Dpython-lib-dir="$(dirname "$lib")" \
                -Dpython-lib="$lib" \
                $gilflag >/dev/null 2>&1; then
                build_ok=false
            fi
        fi
        if [ "$build_ok" = false ]; then
            printf "${RED}[%s]${NC} BUILD FAILED\n" "$py"
            FAIL=$((FAIL + 1))
            continue
        fi

        ext_suffix=$("$py" -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))")
        cp zig-out/lib/libtalyn.so "talyn/talyn_zig${ext_suffix}"
        BUILT_PYTHONS="${BUILT_PYTHONS:+${BUILT_PYTHONS} }$py"
    fi
done

# Ensure no unversioned talyn_zig.so confuses Python imports
rm -f talyn/talyn_zig.so

# Zig compiler discovery
ZIG_016_BIN=""
ZIG_016_VER=""
ZIG_017_BIN=""
ZIG_017_VER=""
ZIG_FALLBACK_BIN=""

if [ "$NO_BUILD" != true ]; then
    check_zig_candidate() {
        local cand="$1"
        [ -z "$cand" ] && return
        if [ "${cand#/}" = "$cand" ]; then
            cand="$(command -v "$cand" 2>/dev/null || true)"
        fi
        [ -z "$cand" ] || [ ! -x "$cand" ] && return

        local ver
        ver="$("$cand" version 2>/dev/null || true)"
        case "$ver" in
            0.16.*)
                if [ -z "$ZIG_016_BIN" ]; then
                    ZIG_016_BIN="$cand"
                    ZIG_016_VER="$ver"
                fi
                ;;
            0.17.*)
                if [ -z "$ZIG_017_BIN" ]; then
                    ZIG_017_BIN="$cand"
                    ZIG_017_VER="$ver"
                fi
                ;;
        esac
    }

    # 1. User-specified CLI flag or environment variables
    check_zig_candidate "$ZIG16"
    check_zig_candidate "$ZIG17"

    # 2. PATH commands (default zig and versioned names)
    check_zig_candidate "zig"
    check_zig_candidate "zig-0.16.0"
    check_zig_candidate "zig-0.16"
    check_zig_candidate "zig-0.17.0"
    check_zig_candidate "zig-0.17"

    # 3. Well-known installation directories
    for p in \
        /opt/zig/0.16.0/zig /opt/zig/0.16/zig \
        /opt/zig/0.17.0/zig /opt/zig/0.17/zig \
        /usr/local/zig/0.16.0/zig /usr/local/zig/0.17.0/zig \
        "$HOME/.local/zig/0.16.0/zig" "$HOME/.local/zig/0.17.0/zig" \
        /opt/zig/zig; do
        check_zig_candidate "$p"
    done

    if [ -z "$ZIG_016_BIN" ] && [ -z "$ZIG_017_BIN" ]; then
        if command -v zig >/dev/null 2>&1; then
            ZIG_FALLBACK_BIN="zig"
        fi
    fi

    # Reference includes/libs for zig build test
    ref_py=""
    for p in python3.13 python3.14 $BUILT_PYTHONS; do
        if command -v "$p" >/dev/null 2>&1; then
            ref_py="$p"
            break
        fi
    done
    if [ -n "$ref_py" ]; then
        REF_INC="$(get_python_include "$ref_py")"
        REF_LIB="$(get_python_lib "$ref_py")"
        ZIG_OPTS="-Doptimize=$OPTIMIZE_MODE -Dpython-include-dir=$REF_INC -Dpython-lib-dir=$(dirname "$REF_LIB") -Dpython-lib=$REF_LIB"
    else
        ZIG_OPTS="-Doptimize=$OPTIMIZE_MODE"
    fi
fi

echo ""

# Stage 2: Test execution (sequential or parallel)
if [ "${JOBS:-0}" -eq 1 ] || [ "$SEQUENTIAL" = true ]; then
    echo "=== Running Tests Sequentially ==="
    echo ""
    for py in $BUILT_PYTHONS; do
        run_tests "$py" "$py" || true
        run_std_tests "$py" "$py" || true
        echo ""
    done

    if [ "$NO_BUILD" = true ]; then
        printf "${YELLOW}[zig]${NC} Skipping zig unit tests (--no-build)\n"
    else
        ran_any=false
        if [ -n "$ZIG_016_BIN" ]; then
            run_zig_unit_tests "$ZIG_016_BIN" "zig-0.16" ".zig-cache16" "" ""
            ran_any=true
        else
            printf "${YELLOW}[zig-0.16]${NC} SKIP (Zig 0.16.x compiler not found; install or set ZIG16)\n"
        fi

        if [ -n "$ZIG_017_BIN" ]; then
            run_zig_unit_tests "$ZIG_017_BIN" "zig-0.17" ".zig-cache17" "" ""
            ran_any=true
        else
            printf "${YELLOW}[zig-0.17]${NC} SKIP (Zig 0.17.x compiler not found; install or set ZIG17)\n"
        fi

        if [ "$ran_any" = false ]; then
            if [ -n "$ZIG_FALLBACK_BIN" ]; then
                run_zig_unit_tests "$ZIG_FALLBACK_BIN" "zig" "" "" ""
            else
                printf "${RED}[zig]${NC} FAIL (No zig compiler found in PATH)\n"
                FAIL=$((FAIL + 1))
            fi
        fi
    fi
else
    # Auto-calculate default JOBS if not explicitly specified
    # Sized against RLIMIT_MEMLOCK (ulimit -l) so concurrent io_uring rings never exceed pinned memory
    if [ -z "$JOBS" ]; then
        JOBS=0
        for _ in $BUILT_PYTHONS; do JOBS=$((JOBS + 1)); done
        [ -n "$ZIG_016_BIN" ] && JOBS=$((JOBS + 1))
        [ -n "$ZIG_017_BIN" ] && JOBS=$((JOBS + 1))
        [ -n "$ZIG_FALLBACK_BIN" ] && JOBS=$((JOBS + 1))

        memlock_kb="$(ulimit -l 2>/dev/null || echo 65536)"
        if [ "$memlock_kb" != "unlimited" ] && [ "$memlock_kb" -le 8192 ] 2>/dev/null; then
            # Under a tight 8MB locked memory ceiling, cap default concurrency at 2
            if [ "$JOBS" -gt 2 ]; then
                JOBS=2
            fi
        else
            if [ "$JOBS" -gt 4 ]; then
                JOBS=4
            fi
        fi
        if [ "$JOBS" -lt 1 ]; then
            JOBS=1
        fi
    fi

    echo "=== Running Tests in Parallel (jobs: $JOBS) ==="
    echo ""

    LOG_DIR="$(mktemp -d /tmp/talyn_test_logs_XXXXXX)"
    CLEANUP_LOGS=true

    running_pids=()
    target_names=()
    target_logs=()
    target_statuses=()

    dispatch_target() {
        local target_type="$1"
        shift
        local target_name="$1"
        shift

        local log_file="$LOG_DIR/${target_name}.log"
        local status_file="$LOG_DIR/${target_name}.status"

        target_names+=("$target_name")
        target_logs+=("$log_file")
        target_statuses+=("$status_file")

        if [ "$target_type" = "zig" ]; then
            local zbin="$1" zcache="$2"
            (
                trap - INT TERM
                run_zig_unit_tests "$zbin" "$target_name" "$zcache" "$log_file" "$status_file"
            ) &
        elif [ "$target_type" = "python" ]; then
            local py="$1"
            (
                trap - INT TERM
                run_python_target "$py" "$target_name" "$log_file" "$status_file"
            ) &
        fi
        local pid=$!
        running_pids+=("$pid")

        if [ "${#running_pids[@]}" -ge "$JOBS" ]; then
            wait "${running_pids[0]}" 2>/dev/null || true
            running_pids=("${running_pids[@]:1}")
        fi
    }

    # Dispatch fast zig unit tests first (finish in <1s, freeing job slots)
    if [ "$NO_BUILD" = true ]; then
        printf "${YELLOW}[zig]${NC} Skipping zig unit tests (--no-build)\n"
    else
        ran_any=false
        if [ -n "$ZIG_016_BIN" ]; then
            dispatch_target zig "zig-0.16" "$ZIG_016_BIN" ".zig-cache16"
            ran_any=true
        else
            printf "${YELLOW}[zig-0.16]${NC} SKIP (Zig 0.16.x compiler not found; install or set ZIG16)\n"
        fi

        if [ -n "$ZIG_017_BIN" ]; then
            dispatch_target zig "zig-0.17" "$ZIG_017_BIN" ".zig-cache17"
            ran_any=true
        else
            printf "${YELLOW}[zig-0.17]${NC} SKIP (Zig 0.17.x compiler not found; install or set ZIG17)\n"
        fi

        if [ "$ran_any" = false ]; then
            if [ -n "$ZIG_FALLBACK_BIN" ]; then
                dispatch_target zig "zig" "$ZIG_FALLBACK_BIN" ""
            else
                printf "${RED}[zig]${NC} FAIL (No zig compiler found in PATH)\n"
                FAIL=$((FAIL + 1))
            fi
        fi
    fi

    # Dispatch python targets
    for py in $BUILT_PYTHONS; do
        dispatch_target python "$py" "$py"
    done

    # Wait for all running background targets to complete
    wait 2>/dev/null || true

    # Results aggregation
    failed_targets=()
    for ((i=0; i<${#target_names[@]}; i++)); do
        name="${target_names[i]}"
        sfile="${target_statuses[i]}"
        lfile="${target_logs[i]}"

        if [ -f "$sfile" ]; then
            py_st="$(grep '^PYTEST_STATUS=' "$sfile" | cut -d= -f2 || true)"
            std_st="$(grep '^STD_STATUS=' "$sfile" | cut -d= -f2 || true)"
            z_st="$(grep '^ZIG_STATUS=' "$sfile" | cut -d= -f2 || true)"

            if [ -n "$py_st" ]; then
                if [ "$py_st" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); failed_targets+=("$name"); fi
            fi
            if [ -n "$std_st" ]; then
                if [ "$std_st" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); failed_targets+=("$name"); fi
            fi
            if [ -n "$z_st" ]; then
                if [ "$z_st" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); failed_targets+=("$name"); fi
            fi
        else
            FAIL=$((FAIL + 1))
            failed_targets+=("$name")
        fi
    done

    if [ "${#failed_targets[@]}" -gt 0 ]; then
        CLEANUP_LOGS=false
        printf "\n${RED}=== Test Failures Detected ===${NC}\n"
        seen_targets=""
        for t in "${failed_targets[@]}"; do
            case " $seen_targets " in
                *" $t "*) ;;
                *)
                    seen_targets="${seen_targets:+${seen_targets} }$t"
                    printf "\n${RED}--- [%s] Failure Log Tail ---${NC}\n" "$t"
                    tail -n 35 "$LOG_DIR/${t}.log" 2>/dev/null || true
                    ;;
            esac
        done
        printf "\nLogs preserved in: %s\n" "$LOG_DIR"
    fi
fi

mins=$((SECONDS / 60))
secs=$((SECONDS % 60))
echo ""
printf "=== Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC} (took %dm %ds) ===\n" "$PASS" "$FAIL" "$mins" "$secs"
exit $FAIL
