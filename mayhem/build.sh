#!/usr/bin/env bash
# Builds the sanitized libsrtp + srtp-fuzzer (libFuzzer and -standalone), and the project's own
# test drivers with normal flags for mayhem/test.sh. Re-runnable and offline: no fetches.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Sanitized, SanCov-instrumented library (the fuzzed code).
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1"
cmake -S . -B build-fuzz -G Ninja \
  -DCMAKE_BUILD_TYPE= \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DENABLE_WARNINGS_AS_ERRORS=OFF -DLIBSRTP_TEST_APPS=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target srtp3

# 2) Harness objects, then link the libFuzzer binary and the standalone reproducer.
OBJ=build-fuzz/mayhem-obj
mkdir -p "$OBJ"
INC="-I$SRC/include -I$SRC/crypto/include -I$SRC/build-fuzz -I$SRC/fuzzer -DHAVE_CONFIG_H"
$CC  $FUZZ_FLAGS $INC -c fuzzer/fuzzer.c  -o "$OBJ/fuzzer.o"
$CC  $FUZZ_FLAGS $INC -O0 -c fuzzer/testmem.c -o "$OBJ/testmem.o"
$CXX $FUZZ_FLAGS -std=c++11 -c fuzzer/mt19937.cpp -o "$OBJ/mt19937.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OBJ/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

OBJS="$OBJ/fuzzer.o $OBJ/testmem.o $OBJ/mt19937.o $OBJ/lsan_off.o"
$CXX $FUZZ_FLAGS $LIB_FUZZING_ENGINE $OBJS build-fuzz/libsrtp3.a -lcrypto -lpthread -o /mayhem/srtp-fuzzer
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $OBJS "$OBJ/standalone_main.o" build-fuzz/libsrtp3.a \
  -lcrypto -lpthread -o /mayhem/srtp-fuzzer-standalone

# 3) Upstream's own test drivers with the project's NORMAL flags (no sanitizers, no -gdwarf-3).
cmake -S . -B build-tests -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DENABLE_WARNINGS_AS_ERRORS=OFF -DLIBSRTP_TEST_APPS=ON -DBUILD_SHARED_LIBS=OFF
cmake --build build-tests -j"$MAYHEM_JOBS"
