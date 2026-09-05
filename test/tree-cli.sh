#!/usr/bin/env bash
# test/tree-cli.sh — `tree` must not fold, `tree --realize` must.
#
# The contract (docs/model.md, hexol/secrets.scm): loading an inventory is
# side-effect free, so `tree`/`ops` never shell out, decrypt, or run an op's
# effect. Deferred constructs only know the ops they produce by running, so
# that layer is opt-in behind --realize — and the addresses it reveals must
# work with `show` and `explain`.
#
# Run: test/tree-cli.sh   (or `make test`)

set -u
cd "$(dirname "$0")/.." || exit 2

GUILE="${GUILE:-guile}"
hexol() { "$GUILE" -L . -e main -s bin/hexol "$@"; }
failures=0
inv=test/fixtures/tree-realize.scm

check() {
  local desc=$1 ok=$2 got=${3:-}
  if [ "$ok" = yes ]; then printf '  ok   %s\n' "$desc"
  else failures=$((failures + 1)); printf '  FAIL %s\n' "$desc"
       [ -n "$got" ] && printf '       got: %s\n' "$got"
  fi
}

marker=$(mktemp -u); export HEXOL_TEST_MARKER="$marker"
trap 'rm -f "$marker"' EXIT

echo
echo "tree: fold is opt-in"

out=$(hexol tree -i "$inv" 2>/dev/null)
case "$out" in
  *"configmap cfg"*) check "default tree shows the construct node" yes ;;
  *) check "default tree shows the construct node" no "$out" ;;
esac
case "$out" in
  *"resource ConfigMap/cfg"*) check "default tree shows no produced children" no "$out" ;;
  *) check "default tree shows no produced children" yes ;;
esac
if [ -e "$marker" ]; then
  check "default tree does not fold (no effect ran)" no "marker $marker exists"
else
  check "default tree does not fold (no effect ran)" yes
fi

out=$(hexol tree --realize -i "$inv" 2>/dev/null)
case "$out" in
  *"resource ConfigMap/cfg"*) check "tree --realize shows produced children" yes ;;
  *) check "tree --realize shows produced children" no "$out" ;;
esac
if [ -e "$marker" ]; then
  check "tree --realize does fold" yes
else
  check "tree --realize does fold" no "marker $marker missing"
fi

# The hash of a produced op, as `tree --realize` prints it.
child=$(printf '%s\n' "$out" | grep -E 'resource ConfigMap/cfg$' | awk '{print $1}')
check "tree --realize prints an address for the produced op" \
      "$([ -n "$child" ] && echo yes || echo no)" "$out"

if [ -n "$child" ]; then
  s=$(hexol show "$child" -i "$inv" 2>&1)
  case "$s" in
    *"did not fire"*) check "show <child> reports a real delta" no "$s" ;;
    *"state delta ("*) check "show <child> reports a real delta" yes ;;
    *) check "show <child> reports a real delta" no "$s" ;;
  esac
  e=$(hexol explain "$child" -i "$inv" 2>&1)
  case "$e" in
    *"resource ConfigMap/cfg"*) check "explain <child> resolves the hash" yes ;;
    *) check "explain <child> resolves the hash" no "$e" ;;
  esac
fi

out=$(hexol tree --realize -i "$inv" 2>/dev/null)
case "$out" in
  *"resource ConfigMap/cfg-late"*) check "hx-late resolves through (hexol) alone" yes ;;
  *) check "hx-late resolves through (hexol) alone" no "$out" ;;
esac

# A short (throw key subr msg) carries no message-args list; formatting it
# must not crash the note.
out=$(hexol tree --realize -i test/fixtures/tree-throw.scm 2>&1)
case "$out" in
  *"the fold went wrong"*) check "a short throw form is reported, not crashed on" yes ;;
  *) check "a short throw form is reported, not crashed on" no "$out" ;;
esac
case "$out" in
  *"boom"*) check "the tree still prints after a failed fold" yes ;;
  *) check "the tree still prints after a failed fold" no "$out" ;;
esac

echo
if [ "$failures" -eq 0 ]; then
  echo "all tree-cli checks passed"; exit 0
else
  echo "$failures tree-cli check(s) failed"; exit 1
fi
