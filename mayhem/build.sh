#!/usr/bin/env bash
#
# mayhem/build.sh — build the armips fuzz harness + the upstream test suite.
#
# Targets:
#   armips        — the armips CLI assembler, fuzzed on a file input (@@) with Mayhem's own
#                   binary instrumentation (built WITHOUT sanitizers — see below).
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

# 1) armips CLI (file-input fuzz target) — built with AFL instrumentation (afl-clang-fast), NOT ASan.
# armips busy-loops with unbounded allocation on trivial malformed input (a lone 'A' or newline,
# on the old revision too). Under ASan that giant-alloc is instantly fatal, killing an in-process
# libFuzzer harness and mayhem-fuzz's forkserver during smoketest; as an UNinstrumented file
# target Mayhem's binary-only tracer records 0 edges (documented for these C++ CLIs). AFL fixes
# both: compiled-in edge coverage (edges>0) and a per-exec forkserver whose own timeout absorbs
# the hangs. Keep DWARF-3 for source-line backtraces.
AFL_CC=afl-clang-fast ; AFL_CXX=afl-clang-fast++
# UBSan (no ASan) on top of the AFL instrumentation: the original mayhemheroes image ran this
# binary with UBSan and that is what surfaced the signed-integer-overflow in stringToInt
# (Util/Util.cpp) alongside the uncaught std::out_of_range. UBSan carries no shadow-memory
# allocator, so it does not reintroduce the ASan giant-alloc kill described above; halting
# (-fno-sanitize-recover) is what turns the UB into a crash Mayhem can triage.
UBSAN_FLAGS="-fsanitize=undefined -fno-sanitize-recover=all -fno-omit-frame-pointer"
# A halting UBSan exits 1 on Linux, which armips also does for any ordinary assembly error — so the
# hit has to be turned into SIGABRT to be visible to the fuzzer. mayhem/ubsan_default_options.c
# overrides the runtime's weak __ubsan_default_options; link it into the fuzz target.
# $DEBUG_FLAGS here too: afl-clang-fast defaults to plain -g (DWARF 5) and this object's CU sits
# first in .debug_info, where the DWARF<4 contract (SPEC §6.2 item 10) is read.
"$AFL_CC" $DEBUG_FLAGS -c mayhem/ubsan_default_options.c -o /tmp/ubsan_default_options.o
cmake -S . -B build-afl -DCMAKE_BUILD_TYPE=Release \
  -DARMIPS_USE_STD_FILESYSTEM=ON \
  -DCMAKE_C_COMPILER="$AFL_CC" -DCMAKE_CXX_COMPILER="$AFL_CXX" \
  -DCMAKE_C_FLAGS="$DEBUG_FLAGS $UBSAN_FLAGS" -DCMAKE_CXX_FLAGS="$DEBUG_FLAGS $UBSAN_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$UBSAN_FLAGS /tmp/ubsan_default_options.o"
# CLASSIC (vanilla-AFL) instrumentation with the fixed 64KB map: Mayhem's engine predates
# AFL++'s dynamic PCGUARD maps and records 0 edges with them.
AFL_LLVM_INSTRUMENT=CLASSIC AFL_MAP_SIZE=65536 \
  cmake --build build-afl -j"$MAYHEM_JOBS" --target armips-bin
cp build-afl/armips /mayhem/armips

# 2) Test suite: build armipstests with the project's NORMAL flags (clean, no sanitizer) so
#    mayhem/test.sh only RUNS the upstream golden-diff suite over Tests/.
cmake -S . -B build-tests -DCMAKE_BUILD_TYPE=Release \
  -DARMIPS_USE_STD_FILESYSTEM=ON \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS" --target armipstests
