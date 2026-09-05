#!/usr/bin/env bash
# test/render-buffer.sh — `hexol render` is all-or-nothing on stdout.
#
# A renderer that dies halfway used to leave a truncated stream on stdout
# (fatal for `hexol render -o yaml … | kubectl apply -f -`). stdout must be
# empty on failure, and the diagnostic must go to stderr.
#
# Run: test/render-buffer.sh   (or `make test`)

set -u
cd "$(dirname "$0")/.." || exit 2

GUILE="${GUILE:-guile}"
hexol() { "$GUILE" -L . -e main -s bin/hexol "$@"; }
failures=0
out=$(mktemp); err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT

ok()   { printf '  ok   %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf '  FAIL %s\n' "$1"; }

echo
echo "render: buffered output"

hexol render -o boom -i test/fixtures/failing-renderer.scm >"$out" 2>"$err"
code=$?
[ "$code" -eq 1 ] && ok "failing renderer exits 1" || fail "failing renderer exit $code, want 1"
[ -s "$out" ] && fail "stdout not empty on failure: $(cat "$out")" || ok "stdout empty on failure"
grep -q "boom" "$err" && ok "error reported on stderr" || fail "no error on stderr"
grep -q "PARTIAL-OUTPUT" "$out" && fail "partial output reached stdout" || ok "no partial output"

# A successful render still writes everything.
hexol render -o json -i test/fixtures/nginx.scm >"$out" 2>/dev/null
[ -s "$out" ] && ok "successful render writes stdout" || fail "successful render wrote nothing"

# -o ansible is pretty-printed, like -o terraform (not one giant line).
hexol render -o ansible -i examples/ansible.scm >"$out" 2>/dev/null
if [ "$(wc -l < "$out")" -gt 1 ]; then ok "-o ansible is pretty-printed"
else fail "-o ansible is a single line"; fi

echo
[ "$failures" -eq 0 ] || { echo "render-buffer: $failures failure(s)"; exit 1; }
