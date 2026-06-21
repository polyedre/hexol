#!/usr/bin/env bash
# test/examples.sh — smoke-test the standalone example inventories.
#
# Renders each example through the renderer it's meant for and checks the
# CLI exits 0. This is a smoke test (does it render at all?), not a golden
# snapshot — it catches breakage in the showcase inventories without pinning
# their exact output, which the surface is still churning.
#
# Excluded on purpose:
#   homelab.scm / homelab.secrets.scm   need sops + tofu (live deploy)
#   helm-kube-prometheus-stack.scm      needs helm + yq (chart expansion)
#   regions.scm                         a fragment included by inventory.scm,
#                                       not a standalone inventory
#
# Run: test/examples.sh   (or `make test-examples`)

set -u
cd "$(dirname "$0")/.." || exit 2

# Invoke hexol through $GUILE rather than ./bin/hexol directly: CI may have
# the binary as `guile-3.0`, which the script's `#!…guile` shebang won't find.
GUILE="${GUILE:-guile}"
hexol() { "$GUILE" -L . -e main -s bin/hexol "$@"; }
failures=0

# "example.scm  output-format"
cases=(
  "examples/inventory.scm        sexp"
  "examples/kubernetes.scm       yaml"
  "examples/secrets.scm          yaml"
  "examples/terraform.scm        terraform"
  "examples/ansible.scm          ansible"
  "examples/database-schema.scm  sql"
  "examples/ledger.scm           ledger"
)

for c in "${cases[@]}"; do
  read -r file fmt <<<"$c"
  # discard the (large) rendered output on stdout; capture only stderr.
  out=$(hexol render -o "$fmt" -i "$file" 2>&1 1>/dev/null)
  err=$?
  if [ "$err" -eq 0 ]; then
    printf '  ok   %-30s -o %s\n' "$file" "$fmt"
  else
    failures=$((failures + 1))
    printf '  FAIL %-30s -o %s  (exit %d)\n' "$file" "$fmt" "$err"
    printf '       %s\n' "$(printf '%s' "$out" | tail -3)"
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "all example renders passed"
  exit 0
else
  echo "$failures example render(s) failed"
  exit 1
fi
