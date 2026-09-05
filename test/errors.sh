#!/usr/bin/env bash
# test/errors.sh — error reporting: a failing inventory must be blamed on its
# own file and line, and a leaked list of ops must not dump the whole op tree.
#
# Run: test/errors.sh   (or `make test`)

set -u
cd "$(dirname "$0")/.." || exit 2

GUILE="${GUILE:-guile}"
hexol() { "$GUILE" -L . -e main -s bin/hexol "$@"; }
failures=0

check() {  # DESC  <<< test expression already evaluated by caller
  local desc=$1 ok=$2
  if [ "$ok" = yes ]; then printf '  ok   %s\n' "$desc"
  else failures=$((failures + 1)); printf '  FAIL %s\n' "$desc"; fi
}

echo
echo "errors: blame line and message size"

err=$(hexol render -i test/fixtures/bad-type.scm 2>&1 >/dev/null)
case "$err" in
  *"test/fixtures/bad-type.scm:4"*) check "type error names FILE:LINE" yes ;;
  *) check "type error names FILE:LINE" no; printf '       got: %s\n' "$err" ;;
esac

err=$(hexol render -i test/fixtures/bad-type-late.scm 2>&1 >/dev/null)
case "$err" in
  *"test/fixtures/bad-type-late.scm:6"*) check "fold-time error names the authored op line" yes ;;
  *) check "fold-time error names the authored op line" no; printf '       got: %s\n' "$err" ;;
esac

# Nested apply-op layers must annotate the message only once.
err=$(hexol render -i test/fixtures/nested-loc.scm 2>&1 >/dev/null)
n=$(printf '%s\n' "$err" | head -1 | command grep -o "nested-loc\.scm:[0-9]*:" | wc -l)
if [ "$n" = 1 ]; then check "nested ops annotate the line exactly once" yes
else check "nested ops annotate the line exactly once" no; printf '       got: %s\n' "$err"; fi
case "$err" in
  *"  at "*) check "no redundant 'at' line when the message is located" no ;;
  *) check "no redundant 'at' line when the message is located" yes ;;
esac

err=$(hexol render -i test/fixtures/leaked-list.scm 2>&1 >/dev/null)
case "$err" in
  *"expected an op"*) check "leaked list explains the splice" yes ;;
  *) check "leaked list explains the splice" no; printf '       got: %s\n' "$err" ;;
esac
lines=$(printf '%s\n' "$err" | wc -l)
if [ "$lines" -lt 5 ]; then check "leaked-list error is < 5 lines" yes
else check "leaked-list error is < 5 lines" no; printf '       %s lines\n' "$lines"; fi

# --backtrace opts back into the full Guile backtrace.
err=$(hexol render --backtrace -i test/fixtures/bad-type.scm 2>&1 >/dev/null)
case "$err" in
  *"In hexol/kernel.scm"*|*"In ice-9/"*) check "--backtrace prints a backtrace" yes ;;
  *) check "--backtrace prints a backtrace" no ;;
esac

echo
if [ "$failures" -eq 0 ]; then echo "all error-reporting checks passed"; else
  echo "$failures check(s) failed"; fi
exit $((failures > 0))
