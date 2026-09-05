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

> **Two surfaces, one rule each.** The auto-quoting above is the
> *config-tree* layer (`hx-merge`/`hx-append`/`hx-when`/`hx-case`), where
> symbol values pair naturally with the symbol-valued query attributes.
> **Typed library constructors** (`(hexol k8s)`, the SQL column sugar, …)
> use the opposite, evaluate-by-default rule: a record body of `(key value)`
> entries where values are ordinary Scheme — `(deployment "api" (image "x")
> (replicas (if prod? 3 1)))`. Which rule applies is always decided by the
> form you're in. See [`extending.md`](extending.md) for `define-construct`.

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

## Migrating: `hexol import`

An existing deployment is the inventory's first draft. `hexol import` wraps
what you have instead of asking for a rewrite:

```sh
./bin/hexol import -f manifests.yaml > app.scm        # k8s manifest stream (or `-` for stdin)
./bin/hexol import -f main.tf.json --from terraform > infra.scm
./bin/hexol render -o yaml -i app.scm                 # renders back to the same objects
```

The YAML import emits `(use-modules (hexol k8s))` and one op per document, in
order — by default a generic `(resource '((apiVersion . "v1") (kind . …) …))`
holding the object as a quoted alist. Plain scalars are typed (`replicas: 2`
is the number 2), quoted ones stay strings (`PORT: "8080"` stays `"8080"`),
so a ConfigMap survives the trip. Fields the API server fills in on a
`kubectl get` dump — `status`, `metadata.managedFields`, `uid`,
`resourceVersion`, `creationTimestamp`, `generation`, the
last-applied-configuration annotation — are stripped; `--no-clean` keeps
them. A `kind: List` envelope is unwrapped.

`--sugar` lifts an object to its typed construct — `namespace`, `configmap`,
`secret`, `service`, `deployment` — when the object is *exactly* what that
construct would build. The check is by construction: the candidate form is
evaluated and its resource compared to the imported object (maps
order-insensitively). Anything the construct can't express — a second
container, an extra annotation — stays a `resource`, so `--sugar` never
changes what renders; it only makes the file shorter where it can.

The Terraform import reads JSON config (`*.tf.json`, the format `render -o
terraform` writes) and emits `terraform-settings` / `terraform-provider` /
`terraform-resource` / `terraform-data` / `terraform-output` forms, with
`terraform-block` for anything else (`variable`, `locals`, `module`). HCL
text is not parsed — there is no HCL reader here.

Either way the result is a plain inventory. Refactor from there: pull the
repeated `resource` into a helper, gate a block with `hx-when`, replace a
verbatim alist with the construct once you're ready.

## Ordering matters

Resolution is a left fold in source order. Two consequences:

1. **Later ops override earlier ones on conflicting paths.** This is
   how a DC fragment overrides a service baseline.
2. **A `$` expression sees whatever state exists *at that point in the
   fold***. If you derive `(nginx max-connections)` from
   `(nginx workers)`, place the derivation *after* every op that may
   write `workers`, otherwise you'll see a stale value.

`hexol lint -i INVENTORY` catches the second case: it folds the inventory
once, recording what each op reads (`get`/`attr`) and writes, and warns
`path P read by op X (file:line) before its last write by op Y (file:line)`
for every read that precedes the last write to that path (or to a parent or
child of it). Exit status is 1 when anything is reported, 0 otherwise, so it
slots into CI. Paths under `hx-each` are reported at their full outer path.

See [`model.md`](model.md) for the "load-bearing ordering" discussion.

## Secrets (inline, sops-backed)

`(hexol secrets)` keeps secrets **in the inventory file**, encrypted at rest
with [sops](https://github.com/getsops/sops), rather than in separate
`*.sops.yaml` files. There are three pieces:

```scheme
(use-modules (hexol) (hexol k8s) (hexol secrets))

;; 1. Declare the encrypted store once, at the top level. This is the literal
;;    sops document, rewritten as a Scheme alist: one envelope (one data key,
;;    one MAC) covering every secret. You don't hand-write this — the
;;    `hexol secret` CLI seals it for you (see below).
(secrets-store
  (version "3.12.2")
  (lastmodified "2026-06-08T13:58:43Z")
  (mac "ENC[AES256_GCM,data:…,type:str]")
  (keys
    (pgp
      (fp "0000000000000000000000000000000000000000")
      (created-at "2026-06-08T13:58:43Z")
      (enc
        "-----BEGIN PGP MESSAGE-----"
        ""
        "hQIMA0byVIlLr1maAQ//…"
        "-----END PGP MESSAGE-----")))
  (data
    (db/password . "ENC[AES256_GCM,data:…,type:str]")
    (api/token   . "ENC[AES256_GCM,data:…,type:str]")))

(hx-ops
  ;; 2. Reference a secret wherever its plaintext belongs. `secret-ref`
  ;;    returns a cheap marker — it does NOT decrypt. Here the plaintext is a
  ;;    Secret's `stringData` (k8s base64-encodes it); the `secret` sugar's
  ;;    `#:data` expects already-base64 values, so use the `resource` form for
  ;;    `stringData`.
  (resource
    `((apiVersion . "v1") (kind . "Secret")
      (metadata (name . "db"))
      (stringData (password . ,(secret-ref 'db/password)))))

  ;; 3. Resolve. Place this op LAST: during `resolve` it walks the final
  ;;    state, decrypts the store once (memoized), and replaces every marker
  ;;    with its plaintext.
  (resolve-secret-refs))
```

### Why a marker plus a terminal op

Inventory resources are built at *load* time — the quasiquoted
`,(secret-ref …)` runs when the resource alist is constructed. But you only
want to shell out to `sops` at *render* time, never for `tree` / `ops` (which
load the file but never fold). So `secret-ref` bakes a cheap `<secret-ref>`
marker into the resource, and `resolve-secret-refs` — running only inside
`resolve` — does the one decryption and substitution. `tree` and `ops` stay
sops-free.

Decryption is **lazy and memoized**: the first marker resolved forces one
`sops -d`, and the plaintext is cached for the rest of the render. If `sops`
is absent, or the decrypt fails because your key isn't present, every marker
resolves to a `<unresolved secret: KEY>` placeholder with a warning — so the
inventory still renders into a structurally-valid stream for anyone without
the secrets (the same graceful skip the old per-file approach had).

### Managing the store: `hexol secret`

You don't edit the `(secrets-store …)` form by hand. Every verb takes the
inventory as its last argument; the mutating ones decrypt, change the
plaintext, re-seal with sops, and rewrite **only** the store form's span in
the file (everything else stays byte-for-byte identical):

```sh
hexol secret ls               inventory.scm   # list keys — no decrypt
hexol secret get   db/password inventory.scm   # decrypt one secret to stdout
hexol secret set   db/password inventory.scm   # add/replace; value from a 3rd arg or stdin
hexol secret edit  db/password inventory.scm   # decrypt into $EDITOR; reseal on change
hexol secret rm    db/password inventory.scm   # drop a key
hexol secret rekey             inventory.scm   # re-seal to the current recipients
hexol secret init              inventory.scm   # insert an empty (secrets-store (data)) form
```

Sealing reuses the `sops` creation rule from the nearest `.sops.yaml` found by
walking up from the inventory's directory — so recipients (PGP keys, age
recipients) and `encrypted_regex` are configured there, exactly as a normal
sops project. `set`/`edit`/`rm`/`rekey` need `sops` on `PATH` and a key that
can decrypt the existing store; `ls` needs neither.

Typical first-time flow for a fresh inventory:

```sh
hexol secret init inventory.scm                          # add the empty form
pass db/password | hexol secret set db/password inventory.scm   # seal a value from stdin
hexol secret ls inventory.scm                            # confirm
```

## Discovering a library's constructs

Every typed constructor (`deployment`, `app`, `varchar`, …) is a
`define-construct`, and its schema — positional head, fields, which are
required, their defaults, flags and one-line docs — is recorded when the
module loads. `hexol doc` prints it: `hexol doc` alone lists every construct
of the built-in libraries (name, module, one-line doc); `hexol doc app`
prints `app`'s signature, a fields table and a minimal example built from its
required fields; add `-i inventory.scm` to document whatever that inventory
loads, its own `define-construct`s included. No need to read `k8s.scm`.

## Repository layout

The engine ships as a Guile module named `hexol`; target libraries are
submodules (`(hexol k8s)`, …). Example inventories are plain consumers —
`(use-modules (hexol) (hexol k8s))`.

```
hexol.scm           # umbrella: (use-modules (hexol)) -> kernel + surface
hexol/
  kernel.scm        # (hexol kernel)  — op record, apply-op, resolve, op:* constructors
  surface.scm       # (hexol surface) — hx-ops/hx-merge/hx-when/hx-case/hx-append/attrs/$ macros
  construct.scm     # (hexol construct)— define-construct: schema-driven record-body
                    #                   constructor engine every typed target library uses
  k8s.scm           # (hexol k8s)     — deployment/service/ingress/configmap/secret/
                    #                   daemonset/custom-resource/service-monitor sugar,
                    #                   service-account + cluster-rbac, expose (derive a
                    #                   Service from a workload), with-namespace scope,
                    #                   `res` compact limits, app/public-app,
                    #                   tls-all, checksum, compliance
  yaml.scm          # (hexol yaml)     — state -> YAML emitter (the k8s render back-end)
  import.scm        # (hexol import)   — `hexol import`: k8s YAML / Terraform JSON ->
                    #                    inventory file (resource ops, --sugar lifts)
  terraform.scm     # (hexol terraform)— terraform-resource/-provider/-settings/-output
                    #                   (macros w/ block/ref body), tf-ref/tf-output,
                    #                   transform-terraform-resources + *.tf.json emitter
  ledger.scm        # (hexol ledger)   — personal-ledger writing UX + ledger-cli render
  sql.scm           # (hexol sql)      — table/column/constraint/index DSL + SQL DDL render
  doc.scm           # (hexol doc)      — `hexol doc`: formats the define-construct schema registry
  ansible.scm       # (hexol ansible)  — inventory.yml bridge + state helpers, play-body
                    #                    forms (tasks/as/each/only/handlers), `play` sink op
  secrets.scm       # (hexol secrets)  — inline sops-backed store: (secrets-store …),
                    #                    (secret-ref 'k), (resolve-secret-refs) render op
  secret-tool.scm   # (hexol secret-tool) — engine behind `hexol secret`: position-aware
                    #                    reader + sops seal/decrypt + in-place form rewrite
bin/hexol           # the CLI: render / tree / ops / explain / secret / doc / lint / import
examples/                          # one self-contained file each
  inventory.scm    # region table + per-region body + hx-each (the engine itself)
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
```
