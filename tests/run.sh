#!/usr/bin/env bash
# Run the module test suite with the StreamTree and StreamDoc structural audit
# gates on.
#
# Each test is a standalone script that prints PASS/FAILED and exits with its
# failure count. With STREAMTREE_AUDIT / STREAMDOC_AUDIT set, every engine
# mutation also checks its mark invariant and, on the first desync, latches and
# writes an "INVARIANT @ ..." line to stderr. A test can desync a mark yet still
# print PASS (it never inspects the latch), so a green test is not enough: this
# runner fails the suite on a non-zero test exit OR on any INVARIANT line.
#
# A Tk test runs under wish9.0 on a private Xvfb (never an existing display,
# where its windows would land over someone's work). The Tk detection is
# word-bounded so `package require tkdown` does not read as Tk. A test with no
# Tk requirement runs under tclsh9.0: under wish it would fall off the script
# end into the event loop and hang, since only failing CLI tests call exit.
#
# bench-*.tcl are benchmarks, not tests; the test-*.tcl glob leaves them out.
set -u
cd "$(dirname "$0")/.."

# Pick a free display: :99 by convention, probing upward past any X server
# already holding a lock.
disp=99
while [ -e "/tmp/.X${disp}-lock" ] || [ -e "/tmp/.X11-unix/X${disp}" ]; do
    disp=$((disp+1))
done

Xvfb ":$disp" -screen 0 1500x1150x24 >/tmp/teatotal-tests-xvfb.log 2>&1 &
xvfb=$!
sleep 2

export STREAMTREE_AUDIT=1
export STREAMDOC_AUDIT=1
fails=0
for t in modules/*/test-*.tcl tests/test-*.tcl; do
    if grep -qE '^[[:space:]]*package require (Tk|Ttk|tk|ttk)\b' "$t"; then
        err=$(DISPLAY=":$disp" timeout 90 wish9.0 "$t" 2>&1 >/dev/null); code=$?
    else
        err=$(timeout 90 tclsh9.0 "$t" 2>&1 >/dev/null); code=$?
    fi
    status="ok"
    if [ "$code" -eq 124 ]; then status="TIMEOUT"; fails=$((fails+1)); fi
    if [ "$code" -ne 0 ] && [ "$code" -ne 124 ]; then status="FAIL(exit $code)"; fails=$((fails+1)); fi
    if printf '%s' "$err" | grep -q 'INVARIANT @'; then
        status="INVARIANT"; fails=$((fails+1))
        printf '%s\n' "$err" | grep 'INVARIANT @'
    fi
    printf '%-52s %s\n' "$t" "$status"
done

kill "$xvfb" 2>/dev/null
echo "----"
[ "$fails" -eq 0 ] && echo "SUITE PASS" || echo "SUITE FAILED ($fails)"
exit "$fails"
