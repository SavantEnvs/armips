#!/usr/bin/env bash
#
# mayhem/build.sh — build armips fuzz harnesses + the upstream test suite.
#
# Targets:
#   armips        — the armips CLI assembler, fuzzed on a file input (@@) with Mayhem's own
#                   binary instrumentation (built WITHOUT sanitizers — see below).
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

# 1) Instrumented build: libarmips, with ASan/UBSan + DWARF-3 + SanCov (-fsanitize=fuzzer-no-link).
#    fuzzer-no-link is REQUIRED here even though this library is never linked with -fsanitize=fuzzer
#    itself: it is what makes libarmips carry SanCov edge instrumentation, which is what the
#    tolowercase libFuzzer harness (linked against libarmips.a below) actually records coverage
#    against. Without it the harness builds and iterates fine locally but records 0 edges under
#    Mayhem (the fuzzed library code has no coverage instrumentation) — a legacy gap fixed here.
FUZZ_LIB_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B build-fuzz -DCMAKE_BUILD_TYPE=Release \
  -DARMIPS_USE_STD_FILESYSTEM=ON \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_LIB_FLAGS" \
  -DCMAKE_CXX_FLAGS="$FUZZ_LIB_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target armips

# armips CLI (file-input fuzz target) — built with AFL instrumentation (afl-clang-fast), NOT ASan.
# armips busy-loops with unbounded allocation on trivial malformed input (a lone 'A' or newline,
# on the old revision too). Under ASan that giant-alloc is instantly fatal, killing an in-process
# libFuzzer harness and mayhem-fuzz's forkserver during smoketest; as an UNinstrumented file
# target Mayhem's binary-only tracer records 0 edges (documented for these C++ CLIs). AFL fixes
# both: compiled-in edge coverage (edges>0) and a per-exec forkserver whose own timeout absorbs
# the hangs. Keep DWARF-3 for source-line backtraces.
AFL_CC=afl-clang-fast ; AFL_CXX=afl-clang-fast++
cmake -S . -B build-afl -DCMAKE_BUILD_TYPE=Release \
  -DARMIPS_USE_STD_FILESYSTEM=ON \
  -DCMAKE_C_COMPILER="$AFL_CC" -DCMAKE_CXX_COMPILER="$AFL_CXX" \
  -DCMAKE_C_FLAGS="$DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$DEBUG_FLAGS"
# CLASSIC (vanilla-AFL) instrumentation with the fixed 64KB map: Mayhem's engine predates
# AFL++'s dynamic PCGUARD maps and records 0 edges with them.
AFL_LLVM_INSTRUMENT=CLASSIC AFL_MAP_SIZE=65536 \
  cmake --build build-afl -j"$MAYHEM_JOBS" --target armips-bin
cp build-afl/armips /mayhem/armips

# 2) tolowercase libFuzzer harness + standalone reproducer, linked against the sanitized lib.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 -I"$SRC" \
  "$SRC/mayhem/fuzz_toLowercase.cpp" $LIB_FUZZING_ENGINE \
  build-fuzz/libarmips.a -lpthread -o /mayhem/fuzz_toLowercase

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 -I"$SRC" \
  "$SRC/mayhem/fuzz_toLowercase.cpp" /tmp/standalone_main.o \
  build-fuzz/libarmips.a -lpthread -o /mayhem/fuzz_toLowercase-standalone

# 3) Test suite: build armipstests with the project's NORMAL flags (clean, no sanitizer) so
#    mayhem/test.sh only RUNS the upstream golden-diff suite over Tests/.
cmake -S . -B build-tests -DCMAKE_BUILD_TYPE=Release \
  -DARMIPS_USE_STD_FILESYSTEM=ON \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS" --target armipstests
