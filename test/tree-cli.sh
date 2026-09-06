#!/usr/bin/env bash
# test/tree-cli.sh — `tree` folds by default, `tree --no-fold` must not.
#
# The contract (docs/model.md): a deferred construct only knows its head-arg
# label and the ops it produces by running, so `tree` folds once — the same
# effects `render` runs — and the addresses it reveals must work with `show`
# and `explain`. `--no-fold` (and `ops`) only load: nothing shells out,
# decrypts, or runs an op's effect, and a construct prints by name alone.
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
echo "tree: --no-fold is the opt-out"

out=$(hexol tree --no-fold -i "$inv" 2>/dev/null)
case "$out" in
  *"configmap cfg"*) check "--no-fold shows the construct's head arg" no "$out" ;;
  *"configmap"*) check "--no-fold shows the construct by name alone" yes ;;
  *) check "--no-fold shows the construct by name alone" no "$out" ;;
esac
case "$out" in
  *"resource ConfigMap/cfg"*) check "--no-fold shows no produced children" no "$out" ;;
  *) check "--no-fold shows no produced children" yes ;;
esac
if [ -e "$marker" ]; then
  check "--no-fold does not fold (no effect ran)" no "marker $marker exists"
else
  check "--no-fold does not fold (no effect ran)" yes
fi

out=$(hexol tree -i "$inv" 2>/dev/null)
case "$out" in
  *"configmap cfg"*) check "default tree labels the construct with its head arg" yes ;;
  *) check "default tree labels the construct with its head arg" no "$out" ;;
esac
case "$out" in
  *"resource ConfigMap/cfg"*) check "default tree shows produced children" yes ;;
  *) check "default tree shows produced children" no "$out" ;;
esac
if [ -e "$marker" ]; then
  check "default tree does fold" yes
else
  check "default tree does fold" no "marker $marker missing"
fi

# The hash of a produced op, as `tree` prints it.
child=$(printf '%s\n' "$out" | grep -E 'resource ConfigMap/cfg$' | awk '{print $1}')
check "tree prints an address for the produced op" \
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
  parent=$(printf '%s\n' "$out" | grep -E 'configmap cfg-late$' | awk '{print $1}')
  e=$(hexol explain "$parent" -i "$inv" 2>&1)
  case "$e" in
    *"this op changed"*"kubernetes_resources"*) check "explain <wrapper> shows the subtree delta" yes ;;
    *) check "explain <wrapper> shows the subtree delta" no "$e" ;;
  esac
fi

# A head arg read from state: the construct's label carries the resolved name.
case "$out" in
  *"configmap cfg-late"*) check "a head arg read from state labels the op" yes ;;
  *) check "a head arg read from state labels the op" no "$out" ;;
esac
case "$out" in
  *"resource ConfigMap/cfg-hx-late"*) check "hx-late resolves through (hexol) alone" yes ;;
  *) check "hx-late resolves through (hexol) alone" no "$out" ;;
esac

# A short (throw key subr msg) carries no message-args list; formatting it
# must not crash the note.
out=$(hexol tree -i test/fixtures/tree-throw.scm 2>&1)
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
