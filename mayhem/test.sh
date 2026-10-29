#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libsrtp's own test drivers (built by mayhem/build.sh in build-tests/).
# Each driver prints per-case "passed" lines / known-answer results; we count them and demand a
# minimum, so a neutered binary (no output) or a missing case fails.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


BUILD="$SRC/build-tests"
[ -d "$BUILD" ] || { echo "missing $BUILD — mayhem/build.sh did not build the tests" >&2; emit_ctrf libsrtp-drivers 0 1; exit 1; }
cd "$BUILD"

passed=0; failed=0
# check <name> <min-matching-lines> <egrep pattern> <driver> [args...]
check() {
  local name="$1" min="$2" pat="$3"; shift 3
  local out rc n
  out="$("$@" 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | grep -Ec "$pat")"
  if [ "$rc" -eq 0 ] && [ "$n" -ge "$min" ] && ! printf '%s\n' "$out" | grep -Eq 'FAILED|\.\.\.failed|\.\.\.FAILED'; then
    echo "ok   $name ($n lines matched $pat, need >= $min)"; passed=$((passed+1))
  else
    echo "FAIL $name (rc=$rc, $n lines matched $pat, need >= $min)"; failed=$((failed+1))
  fi
}

check srtp_driver                 300 'passed$'                          ./srtp_driver -v
check srtp_driver_not_in_place    300 'passed$'                          ./srtp_driver -v -n
check cipher_driver                13 '\.\.\.passed$'                    ./cipher_driver -v
check kernel_driver                 1 'srtp_crypto_kernel passed self-tests' ./kernel_driver -v
check rdbx_driver                  10 'passed$'                          ./rdbx_driver -v
check roc_driver                    1 '^passed$'                         ./roc_driver -v
check replay_driver                 1 '^done$'                           ./replay_driver -v
check test_srtp                     3 'All conditions have passed'       ./test_srtp -v
check test_srtp_policy             30 'All conditions have passed'       ./test_srtp_policy -v
check rcc_test                     25 'All conditions have passed'       ./rcc_test -v

# Known-answer: AES-128 GCM / CTR self-tests inside cipher_driver must be reported by name.
kat="$(./cipher_driver -v 2>&1)"
for want in 'running cipher self-test for AES-128 counter mode using openssl...passed' \
            'running cipher self-test for AES-128 GCM using openssl...passed'; do
  if printf '%s\n' "$kat" | grep -Fxq "$want"; then passed=$((passed+1)); else echo "FAIL missing: $want"; failed=$((failed+1)); fi
done

emit_ctrf libsrtp-drivers "$passed" "$failed" 0
