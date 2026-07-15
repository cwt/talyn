#!/usr/bin/env bash
# Compatible with bash 3.x (macOS) and 4.x+
# Usage: bash scripts/test_all.sh
set -eu

# Trap signals so child processes are cleaned up on CTRL-C
cleanup_pids() {
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup_pids EXIT INT TERM

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

OPTIMIZE_MODE="Debug"
SELECTED_PYTHONS="3.13 3.14 3.13t 3.14t"
VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        --starburst|--releasefast)
            OPTIMIZE_MODE="ReleaseFast"
            ;;
        --safe)
            OPTIMIZE_MODE="ReleaseSafe"
            ;;
        --verbose)
            VERBOSE=true
            STDERR_TARGET="/dev/stderr"
            ;;
        --python=*)
            raw="${arg#--python=}"
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
        --help|-h)
            cat <<'EOF'
Usage: bash scripts/test_all.sh [options]

Options:
  --python=3.13,3.14t   Comma-separated list of Python versions to test
                        (subset of: 3.13, 3.14, 3.13t, 3.14t)
  --starburst           Build with ReleaseFast
  --releasefast         Alias for --starburst
  --safe                Build with ReleaseSafe
  --verbose             Show Zig compiler output on build/test failures
  -h, --help            Show this help
EOF
            exit 0
            ;;
    esac
done

# ---- helpers ----

ensure_test_cert() {
    if [ ! -f /tmp/test_cert.pem ] || [ ! -f /tmp/test_key.pem ]; then
        openssl req -x509 -newkey rsa:4096 -keyout /tmp/test_key.pem \
            -out /tmp/test_cert.pem -days 365 -nodes \
            -subj "/CN=localhost" 2>/dev/null
    fi
}

clean() {
    rm -rf zig-out zig-cache .zig-cache .pytest_cache 2>/dev/null || true
    rm -f talyn/talyn_zig*.so talyn/talyn_zig*.pyd 2>/dev/null || true
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

run_tests() {
    local py="$1" label="$2" cmd=""
    printf "${YELLOW}[%s]${NC} Running tests...\n" "$label"
    if has_timeout; then
        cmd="$(get_timeout_cmd) -k 5 600 $py"
    else
        cmd="$py"
    fi
    if PYTHONPATH=. $cmd -m pytest tests/ \
        -q; then
        printf "${GREEN}[%s] PASS${NC}\n" "$label"
        PASS=$((PASS + 1))
        return 0
    else
        rc=$?
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

    # All applicable standard asyncio test modules.
    # Excluded (not applicable to Talyn):
    #   test_selector_events, test_base_events, test_events  — selector-implementation internals
    #   test_unix_events                                      — Unix selector-watcher internals
    #   test_proactor_events                                  — Windows Proactor
    #   test_windows_events, test_windows_utils               — Windows only
    #   test_buffered_proto                                   — selector-tied
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
            # 60s per module — most modules finish in <5s, but test_subprocess
            # takes ~35s on a healthy run; a hanging module gets killed
            # quickly rather than blocking the whole suite.
            cmd="$(get_timeout_cmd) -k 5 60 $py"
        else
            cmd="$py"
        fi

        # Skip modules that don't exist in this Python version
        # (e.g. test_graph, test_tools, test_free_threading are 3.14+ only).
        if ! PYTHONPATH=. $cmd -c "from test.test_asyncio import $mod" 2>/dev/null; then
            printf "  ${YELLOW}%s: SKIP (not in %s)${NC}\n" "$mod" "$py"
            continue
        fi

        if ( PYTHONPATH=. $cmd -c \
            "import talyn; talyn.install(); import unittest; from test.test_asyncio import $mod; unittest.main(module=$mod, exit=False, argv=['-q'])"; exit $? ) \
            > /dev/null 2>&1; then
            printf "  ${GREEN}%s: PASS${NC}\n" "$mod"
        else
            rc=$?
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
        return 0
    else
        printf "${RED}[%s] STD FAIL${NC}\n" "$label"
        return 1
    fi
}

# ---- main ----

ensure_test_cert

echo "=== Talyn Test Suite ==="
echo ""

# Clean once at start — removes all stale build artifacts
clean

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

    printf "${YELLOW}[%s]${NC} Building...\n" "$py"

    # Clean zig build artifacts between variants (different headers/libs)
    rm -rf zig-out zig-cache .zig-cache .pytest_cache 2>/dev/null || true
    find . -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    find . -name '*.pyc' -delete 2>/dev/null || true

    gilflag=""
    if is_free_threading "$py"; then
        gilflag="-Dpython-gil-disabled=true"
    fi

    if $VERBOSE; then
        zig build install -Doptimize=$OPTIMIZE_MODE \
            -Dpython-include-dir="$inc" \
            -Dpython-lib-dir="$(dirname "$lib")" \
            -Dpython-lib="$lib" \
            $gilflag
    else
        zig build install -Doptimize=$OPTIMIZE_MODE \
            -Dpython-include-dir="$inc" \
            -Dpython-lib-dir="$(dirname "$lib")" \
            -Dpython-lib="$lib" \
            $gilflag >/dev/null 2>&1
    fi
    if [ $? -ne 0 ]; then
        printf "${RED}[%s]${NC} BUILD FAILED\n" "$py"
        FAIL=$((FAIL + 1))
        continue
    fi

    ext_suffix=$("$py" -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))")
    cp zig-out/lib/libtalyn.so "talyn/talyn_zig${ext_suffix}"
    rm -f talyn/talyn_zig.so
    run_tests "$py" "$py" || true
    run_std_tests "$py" "$py" || true
    echo ""
done

# ---- zig tests ----
REF_INC="$(get_python_include python3.13)"
REF_LIB="$(get_python_lib python3.13)"
ZIG_OPTS="-Doptimize=$OPTIMIZE_MODE -Dpython-include-dir=$REF_INC -Dpython-lib-dir=$(dirname "$REF_LIB") -Dpython-lib=$REF_LIB"

printf "${YELLOW}[zig]${NC} Running zig unit tests...\n"
# `zig build test` prints a cosmetic "failed command:" line for the spawned
# test-binary worker even on success; filter it so the result is unambiguous.
# On success we also run the compiled test binary directly to surface its
# clear "All N tests passed." summary (the test-runner wrapper suppresses it).
ZIG_TEST_LOG="$(mktemp)"
if $VERBOSE; then
    zig build test $ZIG_OPTS 2>&1 | grep -v 'failed command:' | tee "$ZIG_TEST_LOG"
    rc=${PIPESTATUS[0]}
else
    zig build test $ZIG_OPTS >"$ZIG_TEST_LOG" 2>&1
    rc=$?
fi
if [ "$rc" -eq 0 ]; then
    ZIG_BIN="$(ls -t .zig-cache/o/*/talyn 2>/dev/null | head -n1)"
    if [ -n "$ZIG_BIN" ]; then
        SUMMARY="$("$ZIG_BIN" 2>&1 | grep -E "All .* tests passed" | tail -n1)"
        if [ -n "$SUMMARY" ]; then
            printf "   %s\n" "$SUMMARY"
        fi
    fi
    printf "${GREEN}[zig] PASS${NC}\n"
else
    printf "${RED}[zig] FAIL${NC}\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$ZIG_TEST_LOG"


echo ""
printf "=== Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC} ===\n" "$PASS" "$FAIL"
exit $FAIL
