# Writing an inventory

This is the practical guide to authoring hexol inventories. For the engine
model behind it, see [`model.md`](model.md).

## How a query works

1. You call `(resolve <ops> <attributes>)` (or `./bin/hexol render`).
2. The engine seeds state with `((attributes . <your-query>))`.
3. It folds each op in the inventory over the state, top-to-bottom.
4. The final state is the merged config — including the attributes it
   started from.

An "op" is one of:

| form                        | what it does                                |
|-----------------------------|---------------------------------------------|
| `(hx-merge ...)`            | deep-merge a config tree into state         |
| `(hx-when pred body ...)`   | recursively fold `body` if `pred` holds     |
| `(hx-case expr arm ...)`    | fold the first matching arm's body          |
| `(hx-append path value)`    | append value to list at path                |
| `(hx-copy src dst)`         | copy the value at `src` to `dst`            |
| `(hx-move src dst)`         | move the value at `src` to `dst` (delete `src`) |
| `(hx-delete path)`          | remove the entry at `path`                  |

All author ops are `hx-`-prefixed so they never shadow Guile's own `when`,
`append`, `case`, `load`, or srfi-1's `merge`. They compose freely; the
result of `resolve` is a nested alist.

### Moving and pruning paths

`hx-copy`, `hx-move`, and `hx-delete` operate on whole paths rather than
merging values in. Each path is a bare symbol (`legacy`) or a segment list
(`(db host)`), auto-quoted like `hx-append`'s path:

```scheme
(hx-ops
  (hx-merge (db (host "localhost") (port 5432) (legacy_password "x")))
  (hx-copy   (db host) (app db_host))   ; duplicate; src stays
  (hx-move   (db port) (app db_port))   ; relocate; src removed
  (hx-delete (db legacy_password)))     ; prune
```

Because they fold like any other op, **order matters** (a later `hx-merge`
can re-create a path a `hx-delete` removed, and a `hx-copy` sees whatever
value exists at `src` *at that point* in the fold). `hx-copy`/`hx-move` on a
missing `src` are a no-op — they don't create `dst` — and `hx-delete` of a
missing path leaves the state unchanged. They prune only the named entry,
nothing else.

## A worked inventory

```scheme
(use-modules (hexol))

(define my-inv
  (hx-ops

    ;; literal config (deep-merged into state)
    (hx-merge
      (ssh (port 22))
      (ntp (servers "0.pool.ntp.org" "1.pool.ntp.org")))

    ;; computed from query attributes — applies in every DC. `str` concats
    ;; (coercing the symbol attr); `fmt` would do the same with a template.
    (hx-merge
      (mirror ($ (str "rpm." (attr 'dc) ".internal"))))

    ;; conditional block — `attrs` is shorthand for attribute equality
    (hx-when (attrs (role web))
      (hx-merge (nginx (workers 4)))
      (hx-append packages nginx))

    ;; pull in a fragment — load-inventory-file returns its list of ops, and
    ;; hx-when flattens + folds them when the predicate holds
    (hx-when (attrs (dc alpha))
      (load-inventory-file "dcs/alpha.scm"))

    ;; the predicate is any expression read against accumulated state
    (hx-when (pair? (get '(packages)))
      (hx-merge (provisioning (package-count ($ (length (get '(packages))))))))))

;; resolve
(resolve my-inv '((dc . alpha) (role . web)))
```

## Surface forms inside `hx-merge`

- `(key literal)` — scalar:    `(port 22)`
- `(key l1 l2 ...)` — list:     `(servers "a" "b")`
- `(key (sub ...) ...)` — map:  `(nginx (workers 4) (user "nginx"))`
- `(key ($ expr))` — computed:  `(mirror ($ (str "rpm." (attr 'dc))))`

Unquoted symbols in value position are auto-quoted: `(encryption at-rest)`
yields the symbol `at-rest`. The `$` marker is required only when a
value's syntactic shape could be mistaken for a nested map (e.g. an
arithmetic expression like `(* 1024 ...)`).

## Helpers inside `$` and inside predicates

- `(attr key)`  — read `(attributes key)` from the current fold state.
- `(get path)`  — read any path from the current fold state.
- `(str part ...)` — concatenate parts into a string, coercing symbols and
  numbers (so no `symbol->string` / `string-append`): `(str "k8s-" (attr 'region))`.
- `(fmt template arg ...)` — fill a format string's `~a`/`~s` holes:
  `(fmt "https://api.~a:6443" (attr 'region))`.

`attr`/`get` are bound during op evaluation, not at file load.

An `hx-when` / `hx-case` predicate is just an expression evaluated against
the current state, so `attr`/`get` work in it directly. `(attrs (k v) …)` is
equality shorthand; any other expression (`(semver> (get …) …)`,
`(pair? (get …))`) works too. A predicate that yields a procedure is applied
to the state — so `(attrs …)` and an explicit `(lambda (s) …)` both still work.

## File splitting

Split an inventory across files with `load-inventory-file`, which reads a
fragment and returns its list of ops. Because `hx-when` (like `hx-ops` and
`hx-case`) flattens a list of ops in body position, the fragment folds in
wherever you call it:

```scheme
(hx-when (attrs (role web))
  (load-inventory-file "examples/services/nginx.scm"))
```

Each fragment file is itself an `(hx-ops ...)` form evaluating to a list of
ops. The read is eager — it happens when the enclosing form is built — but
the *effect* is still gated: the fragment's ops only fold when the predicate
holds. (This is the one thing the removed lazy `load` op did that this
doesn't: defer the file *read* itself.)

For an inventory embedded in a larger Guile program rather than run through
the CLI, the idiomatic split is a normal module exposing a procedure that
returns ops, called inside the parent `hx-ops` — no hexol-specific loader
needed, since `hx-ops`/`hx-when` already flatten the returned list.

See `examples/inventory.scm` for a worked split: it pulls in
`examples/kubernetes.scm` via `load-inventory-file`, gated by an `hx-when`.

## Ordering matters

Resolution is a left fold in source order. Two consequences:

1. **Later ops override earlier ones on conflicting paths.** This is
   how a DC fragment overrides a service baseline.
2. **A `$` expression sees whatever state exists *at that point in the
   fold***. If you derive `(nginx max-connections)` from
   `(nginx workers)`, place the derivation *after* every op that may
   write `workers`, otherwise you'll see a stale value.

See [`model.md`](model.md) for the "load-bearing ordering" discussion.

## Repository layout

The engine ships as a Guile module named `hexol`; target libraries are
submodules (`(hexol k8s)`, …). Example inventories are plain consumers —
`(use-modules (hexol) (hexol k8s))`.

```
hexol.scm           # umbrella: (use-modules (hexol)) -> kernel + surface
hexol/
  kernel.scm        # (hexol kernel)  — op record, apply-op, resolve, op:* constructors
  surface.scm       # (hexol surface) — hx-ops/hx-merge/hx-when/hx-case/hx-append/attrs/$ macros
  k8s.scm           # (hexol k8s)     — deployment/service/ingress/configmap/secret/
                    #                   daemonset/custom-resource/service-monitor sugar,
                    #                   service-account + cluster-rbac, expose (derive a
                    #                   Service from a workload), with-namespace scope,
                    #                   `res` compact limits, app/public-app/worker,
                    #                   tls-all, checksum, compliance
  yaml.scm          # (hexol yaml)     — state -> YAML emitter (the k8s render back-end)
  terraform.scm     # (hexol terraform)— terraform-resource/-provider/-settings/-output
                    #                   (macros w/ block/ref body), tf-ref/tf-output,
                    #                   transform-terraform-resources + *.tf.json emitter
  ledger.scm        # (hexol ledger)   — personal-ledger writing UX + ledger-cli render
  sql.scm           # (hexol sql)      — table/column/constraint/index DSL + SQL DDL render
  ansible.scm       # (hexol ansible)  — inventory.yml bridge + state helpers, task/handler
                    #                    (macros over block/body) / as, `play` sink op
bin/hexol           # the CLI: render / tree / ops / explain
examples/                          # one self-contained file each
  inventory.scm    # region table + per-region body + hx-each (the engine itself)
  regions.scm      # the region table as an importable module (CMDB sync source)
  kubernetes.scm   # consumer of (hexol k8s): namespaced apps + compliance demo
  helm-kube-prometheus-stack.scm  # the Helm chart converted to (hexol k8s) ops
  terraform.scm    # consumer of (hexol terraform): AWS + OpenStack, one combined config
  ansible.scm      # consumer of (hexol ansible): a web/db/cache fleet (inline inventory)
  ledger.scm       # consumer of (hexol ledger): a journal (render -o ledger)
  database-schema.scm  # consumer of (hexol sql): a blog/commerce schema (render -o sql)
test.scm            # kernel + surface smoke tests
test/k8s-res.scm    # unit tests for the `res` resources-spec parser
docs/
  model.md          # the fold-of-ops engine model
  authoring.md      # this guide
  extending.md      # building target libraries + worked examples
  cmdb.md           # the event-sourced CMDB (as built)
cmdb/               # the event-sourced CMDB built on the same kernel (see docs/cmdb.md)
  store.scm         # fact log, library lookup, refold
  server.scm        # HTTP front-end
  json.scm          # sexp -> JSON
  region-render.scm # resolve the per-region body against a fact's attrs
  region-body.scm   # the per-region hexol inventory
  apps.scm          # Helm releases per region
  libraries/        # versioned op vocabularies (v1, v2 — the library-bump demo)
bin/cmdb-server     # boot the CMDB HTTP server
bin/sync-inventory  # push a region table as facts
bin/promote         # waved image/chart rollouts
test/cmdb-store.scm  test/cmdb-server.scm  # CMDB tests
```
