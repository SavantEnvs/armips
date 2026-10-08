#!/usr/bin/env bash
#
# mayhem/build.sh — build armips fuzz harnesses + the upstream test suite.
#
# Targets:
#   armips        — the armips CLI assembler, fuzzed on a file input (@@). Built with AFL edge
#                   instrumentation AND the full $SANITIZER_FLAGS (ASan+UBSan, halting) — see below.
#   tolowercase   — in-process libFuzzer harness over Util/Util.cpp toLowercase().
# Plus the upstream functional test suite (armipstests) with NORMAL flags for mayhem/test.sh.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# All CMake build trees live under mayhem/ (mayhem/build-{fuzz,afl,tests}), which mayhem/.gitignore
# ignores: the grader's `git clean -ffdX` must remove their configure state (SPEC §6.2 item 16), and
# the upstream root .gitignore stays untouched (the layer is additive-only).

# Build-time LeakSanitizer opt-out, linked into every ASan-built binary below.
LSAN_OFF_O=/tmp/armips_lsan_off.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF_O"

# 1) Instrumented build: libarmips, with ASan/UBSan + DWARF-3 + SanCov (-fsanitize=fuzzer-no-link).
#    fuzzer-no-link is REQUIRED here even though this library is never linked with -fsanitize=fuzzer
#    itself: it is what makes libarmips carry SanCov edge instrumentation, which is what the
#    tolowercase libFuzzer harness (linked against libarmips.a below) actually records coverage
#    against. Without it the harness builds and iterates fine locally but records 0 edges under
#    Mayhem (the fuzzed library code has no coverage instrumentation) — a legacy gap fixed here.
FUZZ_LIB_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B mayhem/build-fuzz -DCMAKE_BUILD_TYPE=Release \
  -DARMIPS_USE_STD_FILESYSTEM=ON \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_LIB_FLAGS" \
  -DCMAKE_CXX_FLAGS="$FUZZ_LIB_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS"
cmake --build mayhem/build-fuzz -j"$MAYHEM_JOBS" --target armips

# armips CLI (file-input fuzz target): AFL edge instrumentation (afl-clang-fast) for Mayhem's
# coverage — as an uninstrumented file target Mayhem's binary-only tracer records 0 edges on this
# C++ CLI — PLUS the full $SANITIZER_FLAGS so the fuzzed assembler itself is ASan+UBSan checked
# (halting). Earlier this tree was built WITHOUT sanitizers on the belief that ASan made armips'
# runaway-read hang on trivial malformed input (a lone 'A' or newline) instantly fatal; measured at
# this revision it is not: the sanitized binary loops exactly like the plain one (no ASan report,
# RSS grows ~40 MB/s) and the Mayhemfile's per-exec timeout absorbs it. The upstream test oracle
# stays a separate, unsanitized build (mayhem/build-tests, step 3). Keep DWARF-3 for source-line backtraces.
AFL_CC=afl-clang-fast ; AFL_CXX=afl-clang-fast++
CLI_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake -S . -B mayhem/build-afl -DCMAKE_BUILD_TYPE=Release \
  -DARMIPS_USE_STD_FILESYSTEM=ON \
  -DCMAKE_C_COMPILER="$AFL_CC" -DCMAKE_CXX_COMPILER="$AFL_CXX" \
  -DCMAKE_C_FLAGS="$CLI_FLAGS" -DCMAKE_CXX_FLAGS="$CLI_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $LSAN_OFF_O"
# CLASSIC (vanilla-AFL) instrumentation with the fixed 64KB map: Mayhem's engine predates
# AFL++'s dynamic PCGUARD maps and records 0 edges with them.
AFL_LLVM_INSTRUMENT=CLASSIC AFL_MAP_SIZE=65536 \
  cmake --build mayhem/build-afl -j"$MAYHEM_JOBS" --target armips-bin
cp mayhem/build-afl/armips /mayhem/armips

# 2) tolowercase libFuzzer harness + standalone reproducer, linked against the sanitized lib.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 -I"$SRC" \
  "$SRC/mayhem/fuzz_toLowercase.cpp" $LIB_FUZZING_ENGINE \
  mayhem/build-fuzz/libarmips.a "$LSAN_OFF_O" -lpthread -o /mayhem/fuzz_toLowercase

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 -I"$SRC" \
  "$SRC/mayhem/fuzz_toLowercase.cpp" /tmp/standalone_main.o \
  mayhem/build-fuzz/libarmips.a "$LSAN_OFF_O" -lpthread -o /mayhem/fuzz_toLowercase-standalone

# 3) Test suite: build armipstests with the project's NORMAL flags (clean, no sanitizer) so
#    mayhem/test.sh only RUNS the upstream golden-diff suite over Tests/.
cmake -S . -B mayhem/build-tests -DCMAKE_BUILD_TYPE=Release \
  -DARMIPS_USE_STD_FILESYSTEM=ON \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build mayhem/build-tests -j"$MAYHEM_JOBS" --target armipstests
