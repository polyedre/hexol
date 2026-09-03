#!/usr/bin/env bash
# test/diff-cli.sh — `hexol diff` exit codes end to end, against the PATH shims
# in test/fixtures/bin (a fake kubectl whose `diff` exit is $FAKE_DIFF_EXIT).
# 0 clean, 1 drift, 2 error; `--explain` goes through `kubectl get` instead.
#
# Run: test/diff-cli.sh   (or `make test`)

set -u
cd "$(dirname "$0")/.." || exit 2

GUILE="${GUILE:-guile}"
export PATH="$PWD/test/fixtures/bin:$PATH"
export FAKE_LOG=/dev/null
hexol() { "$GUILE" -L . -e main -s bin/hexol "$@"; }
inv=examples/kubernetes.scm
failures=0

expect_exit() {  # DESC EXPECTED CMD…
  local desc=$1 want=$2; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" -eq "$want" ]; then printf '  ok   %s\n' "$desc"
  else failures=$((failures + 1)); printf '  FAIL %s (exit %d, want %d)\n' "$desc" "$got" "$want"; fi
}

echo
echo "diff: CLI exit codes"
FAKE_DIFF_EXIT=0 expect_exit "clean -> 0"            0 hexol diff -i "$inv"
FAKE_DIFF_EXIT=1 expect_exit "drift -> 1"            1 hexol diff -i "$inv"
FAKE_DIFF_EXIT=3 expect_exit "kubectl error -> 2"    2 hexol diff -i "$inv"
FAKE_DIFF_EXIT=1 expect_exit "--only kubernetes"     1 hexol diff --only kubernetes -i "$inv"
expect_exit "unknown flag -> 2"                      2 hexol diff --bogus -i "$inv"
# --explain: no live objects (fake `get` prints nothing) → every resource drifts
expect_exit "--explain, nothing live -> 1"           1 hexol diff --explain -i "$inv"
out=$(hexol diff --explain -i "$inv" 2>/dev/null)
if printf '%s' "$out" | grep -q '^+ Deployment/tintin (ns tintin) (not in cluster)' \
   && printf '%s' "$out" | grep -q 'set by: .*examples/kubernetes.scm:'; then
  echo "  ok   --explain names the resource and the op that set it"
else
  failures=$((failures + 1)); echo "  FAIL --explain output"; printf '%s\n' "$out" | head -5
fi
FAKE_DIFF_EXIT=1 expect_exit "apply --dry-run stays plan (exit 0)" 0 hexol apply --dry-run -i "$inv"

echo
if [ "$failures" -eq 0 ]; then echo "all diff CLI checks passed"; exit 0
else echo "$failures diff CLI check(s) failed"; exit 1; fi
