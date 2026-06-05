# hexol

A Guile-based inventory engine: configuration is built by *folding a list
of operations over state*, with the query's attributes as the initial
seed. Inspired by Hiera's role in Puppet, but dynamic instead of static
and with Kubernetes-style features (computed predicates over attributes)
in place of a rigid directory hierarchy.

For the design rationale and engine semantics, see:

- [`docs/model.md`](docs/model.md) — the fold-of-ops engine model.
- [`docs/cmdb.md`](docs/cmdb.md) — the event-sourced CMDB built on the same
  kernel (fact log + versioned libraries + HTTP server).

## Quick start

```sh
# enter the dev environment (Guix + direnv)
direnv allow

# run the smoke tests (kernel, surface, the `res` parser, and the CMDB)
make test

# resolve examples/inventory.scm (a small region fleet) and view it
./bin/hexol render examples/inventory.scm                       # whole state (sexp)
./bin/hexol render --path regions.alpha5 examples/inventory.scm   # one region's subtree
./bin/hexol render --path regions.bravo1.network examples/inventory.scm

# the same CLI handles any inventory and any output format
./bin/hexol render -o yaml examples/helm-kube-prometheus-stack.scm   # k8s manifest stream
./bin/hexol render -o terraform examples/terraform.scm               # Terraform JSON
./bin/hexol render -o ansible examples/ansible.scm                   # Ansible playbook JSON
./bin/hexol render -o sql     examples/database-schema.scm           # SQL DDL statements
./bin/hexol render -o ledger  examples/ledger.scm                    # ledger-cli journal text
./bin/hexol tree    examples/kubernetes.scm                          # op tree
./bin/hexol ops     examples/inventory.scm                           # top-level ops + source
./bin/hexol explain regions.alpha5.network.cni examples/inventory.scm  # what touched a path
```

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

All author ops are `hx-`-prefixed so they never shadow Guile's own `when`,
`append`, `case`, `load`, or srfi-1's `merge`. They compose freely; the
result of `resolve` is a nested alist.

## Writing an inventory

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

### Surface forms inside `hx-merge`

- `(key literal)` — scalar:    `(port 22)`
- `(key l1 l2 ...)` — list:     `(servers "a" "b")`
- `(key (sub ...) ...)` — map:  `(nginx (workers 4) (user "nginx"))`
- `(key ($ expr))` — computed:  `(mirror ($ (str "rpm." (attr 'dc))))`

Unquoted symbols in value position are auto-quoted: `(encryption at-rest)`
yields the symbol `at-rest`. The `$` marker is required only when a
value's syntactic shape could be mistaken for a nested map (e.g. an
arithmetic expression like `(* 1024 ...)`).

### Helpers inside `$` and inside predicates

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

See `docs/model.md` for the "load-bearing ordering" discussion.

## Layout

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

## Extensibility

The kernel exposes a small set of op constructors — `op:merge`, `op:set`,
`op:append`, `op:when`, `op:case` (plus `compose-ops` and `for-each-into`) —
surfaced to authors as the `hx-`-prefixed ops `hx-merge` / `hx-append` /
`hx-when` / `hx-case`, assembled with the `hx-ops` wrapper. And one record
type:

```
<op> = (kind, source, effect : state -> state, label, children)
```

That's the entire contract. Everything else is **user-space**: any
procedure that returns an `<op>` (or a list of them) is a first-class
extension. There is no plugin API, no lifecycle, no DSL escape hatch —
just Scheme procedures that close over `make-op` + `apply-op` + `fold`.

### What goes in the library (and what doesn't)

Four layers, each more specific than the last:

| Layer | Module | Holds | Knows about |
|-------|--------|-------|-------------|
| **kernel**  | `hexol/kernel.scm`  | op record, `resolve`, state/path helpers | nothing — domain-agnostic |
| **surface** | `hexol/surface.scm` | author syntax for kernel ops (`hx-ops`/`hx-merge`/`hx-when`/`hx-case`/`hx-append`/`$`/`resource`/`transform`) | nothing — 1:1 sugar over kernel ops |
| **target libraries** | `(hexol k8s)` / `(hexol terraform)` / `(hexol ledger)` / `(hexol ansible)` | domain vocabulary | Deployments / Terraform resources / journal entries / Ansible tasks |
| **examples** | `examples/*.scm` | one concrete artifact each (ideally one self-contained file) | the actual resources / journal / role |

**The rule.** A binding belongs in a library iff it is **(1) reusable**
across more than one inventory *and* **(2) free of any specific artifact's
content or organizing structure** — it defines a *kind of thing*, never
*which* things exist or how this particular fleet/journal/playbook is laid
out. Everything else is an example.

This rule cuts *through* a feature, not just between them. Enumerating a
table and stashing each element's result under a key is a general
capability — map a body over a keyed table, resolving each element in
isolation — so that combinator, `for-each-into`, is in the kernel (with the
body-splicing author surface `hx-each` over it in `(hexol surface)`).
But *which* table, the base path `(regions)`, and the per-region body are
the OpenStack fleet's organizing structure, so they stay in
`examples/inventory.scm` as the one-line `(hx-each regions #:into regions
(region-body))`. The primitive is reusable and content-free; the call
is content. Contrast `with-namespace` in `(hexol k8s)`, which
*is* general: it scopes whatever resources you nest in it and names
nothing specific. The same test draws the line *within* a single domain:
`terraform-resource` (emit any resource for any provider) is a reusable
kind, so it's in `(hexol terraform)`; `aws-rds` — one provider's one
service, with its specific attributes — is content, so it stays in
`examples/terraform.scm`. Likewise `deployment` / `tx` / `as`/`task` are
library kinds, while a region table, a journal, or a firewall role are
example content.

### What we built on top, without touching the kernel

The Kubernetes layer is **entirely user-space** — no kernel changes were
required for any of it. It now ships as the `(hexol k8s)` submodule
(`hexol/k8s.scm`), which `examples/kubernetes.scm` and the
kube-prometheus-stack conversion both consume via `(use-modules (hexol
k8s))`. It is still just Scheme procedures returning ops:

| Feature                           | How it's built                                                           |
|-----------------------------------|--------------------------------------------------------------------------|
| `(resource <alist>)`              | A procedure that returns `op:append` into `(kubernetes_resources)`.      |
| `app` / `public-app` / `worker`   | Procedures that build N resource ops and bundle them via `compose-ops`.  |
| `configmap` / `secret`            | Same — methods returning resource ops.                                   |
| `tls-all`                         | A `transform-resources` walking Ingresses and deep-merging TLS sections. |
| `annotate-all` / `label-all`      | `transform-resources` over every resource.                               |
| `checksum-config`                 | A `make-op` that reads the resource list, hashes referenced CM/Secret data, and re-writes Deployments with a `config/checksum` annotation. |
| `compliance-check name predicate` | A `make-op` walking resources, appending findings to `(compliance_findings)`. |
| `compliance-all`                  | A `compose-ops` bundle of five named checks (resources set, mem limit = req, cpu limit ≥ req, image registry, no privileged). |

`compose-ops` itself is ~6 lines, and because every target library leans
on it, it lives in the kernel beside the `op:*` constructors:

```scheme
(define (compose-ops kind source ops)
  (make-op kind source
           (lambda (state) (fold (lambda (op s) (apply-op op s)) state ops))
           #f
           ops))
```

That single combinator is what lets `app` (or `aws-rds`, or an Ansible
`fleet`) look like one "operation" while being just a fold of smaller ops
underneath — and because it stashes its child ops in `op-children`, the
introspection tools descend through it transparently.

### Where extension lands, by shape of need

- **"I want a new noun" (Deployment, Ingress, custom CRD, IAM policy,
  Terraform module, Ansible task…)** — write a procedure that returns
  a `resource`-shaped op. No kernel change.
- **"I want a new cross-cutting transform" (mutate every X, attach Y to
  all Z)** — use `transform-resources`, or write your own `make-op`
  walking whatever state shape you care about.
- **"I want a new control flow" (loops, parallel branches, retries…)**
  — write a procedure that builds child ops and folds them; expose them
  via `op-children` so `hexol tree` can see inside.
- **"I want a new assertion / lint / audit"** — same as a transform,
  but write findings to a sibling accumulator (we use
  `(compliance_findings)`); the renderer / CI gate reads them.
- **"I want a new surface syntax"** — add a `syntax-rules` macro in
  `hexol/surface.scm` (the k8s sugar lives in `hexol/k8s.scm`) that expands to an existing op constructor.

### The Terraform target, worked example

`examples/terraform.scm` renders one `terraform init`-ready `*.tf.json`
spanning two providers from a single inventory: AWS infrastructure (an RDS
instance + a network load balancer) and an OpenStack web fleet (a
keypair, a private network, N VMs), with both providers declared in one
`terraform {}` block.

`(hexol terraform)` provides only the provider-agnostic vocabulary — the
Terraform *language*: `terraform-resource` / `terraform-provider` /
`terraform-settings` / `terraform-output` (the top-level blocks), the
`block` / `ref` body helpers, plus `tf-ref`, `tf-output`,
`transform-terraform-resources` (a cross-cutting walk over the resource
tree), and the `*.tf.json` emitter. The block constructors are **macros**
with an HCL-ish body — `(key <expr>)` attributes (the value is ordinary,
evaluated Scheme), `(block key …)` nesting, `(list …)`, and
`(ref type name attr)` for an interpolation string from bare symbols:

```scheme
(terraform-resource "openstack_compute_instance_v2" name
  (flavor_name flavor)                          ; attribute, value evaluated
  (security_groups (list (ref … web name)))     ; list attribute
  (block network                                ; nested block
    (uuid (ref openstack_networking_network_v2 internal id))))
```

No quasiquote, no dotted pairs, no paren-counting. Each constructor
deep-merges its body into a `(terraform_config)` tree shaped exactly like
Terraform's `*.tf.json` object model, so the emitter is just a pretty-print
of that subtree — no regrouping.

What the example shows that hand-written HCL can't do cheaply: the fleet's
size/flavor/region flip dev↔prod from one symbol; VMs are generated by
`(map app-vm (iota vm-count))` with per-VM static IPs as index arithmetic
and cloud-init from a string function; `aws-rds` / `aws-lb` /
`web-security-group` are functions returning *bundles* of resources (HCL's
unit of reuse is a whole module); a one-line `metadata-all` (built on
`transform-terraform-resources`) stamps every instance's `metadata` in a
single pass; and the keypair's `public_key` is read from `~/.ssh` at render
time.

```
HEXOL_ENV=prod ./bin/hexol render -o terraform examples/terraform.scm > main.tf.json && terraform init && terraform apply
# AWS creds via the usual env/profile; OpenStack via OS_* / clouds.yaml
```

The provider names, resource types, and fleet shape are content in the
example; the language blocks and the generic resource-tree walk are the
library. No kernel change.

### Worked example: converting a Helm chart

The usual Helm way treats a chart as an **opaque release** — a chart URL, a
version, and a `values` blob passed through untouched. You cannot ask
"which resource gets this label?" or "what does `grafana.enabled=#f`
actually remove?"; the templating happens inside Helm, off to one side.

`examples/helm-kube-prometheus-stack.scm` is the chart `kube-prometheus-stack`
**converted to native ops**, built on the shared `(hexol k8s)` library. Every object the chart
renders (the operator, a Prometheus + Alertmanager CR, Grafana,
kube-state-metrics, node-exporter, their Services / ServiceMonitors, a
default PrometheusRule) is a sugar call — `(deployment …)`, `(service …)`,
`(daemonset …)`, `(custom-resource …)`, `(service-monitor …)` — the same
library `examples/kubernetes.scm` uses. The chart's `values.yaml` becomes
a plain Scheme `values` alist; each `{{- if .Values.x.enabled }}` becomes a
`(hx-when ...)`; the `_helpers.tpl` common labels become a single `label-all`
transform.

```scheme
(use-modules (hexol k8s))
;; ... values alist + helpers (vget / fullname / on?) ...
(hx-ops
 (with-namespace ns                     ; one scope for the whole release
  ;; prometheus-operator: resources listed inline, gated like `{{- if }}`
  (hx-when (on? '(prometheusOperator enabled))
    (deployment #:name (fullname "operator") #:image (vget '(prometheusOperator image))
                #:replicas (vget '(prometheusOperator replicas))
                #:service-account (fullname "operator")
                #:resources "100m-*/128Mi-256Mi")   ; cpu req / mem req-limit
    (service #:name (fullname "operator") #:port 8080)
    (service-monitor #:name (fullname "operator")))
  ;; ... other components ...
  (label-all (common-labels))))
```

`with-namespace` binds the namespace for every resource constructed in its
body (inner scopes win; an explicit `#:namespace` still overrides), and
`#:resources` accepts the compact string `"<cpu-req>-<cpu-lim>/<mem-req>-<mem-lim>"`
— `*` omits a bound, a single memory value sets request = limit, a single
cpu value leaves the limit unset. `(res "…")` returns the same alist for use
inside a raw `custom-resource` spec.

`(expose (deployment …))` folds the workload, then reads the resource it
produced and appends a matching `Service` — selector `(app . <name>)`, one
Service port per distinct container port (single → `http`, several →
`port-<n>`). `(cluster-rbac #:name … #:rules …)` bundles a ServiceAccount +
ClusterRole + ClusterRoleBinding so a `#:service-account` you reference
actually exists.

`examples/helm-kube-prometheus-stack.scm` is just an inventory — a single
self-contained file, like every other example — so the *one* CLI handles
it. Because it bottoms out in the same op record as everything else, the
tooling works unchanged, and the gating is no longer opaque:

```
./bin/hexol tree examples/helm-kube-prometheus-stack.scm   # op tree: each when -> its resources
./bin/hexol render -o yaml examples/helm-kube-prometheus-stack.scm   # -> 35 manifests (multi-doc YAML)
./bin/hexol explain kubernetes_resources.3.spec.replicas \
            examples/helm-kube-prometheus-stack.scm   # which op set this? the Prometheus CR
```

Plain `render` (and `-o json`) prints the whole resolved state; `-o yaml`
emits the manifest stream a `helm template` would — it extracts the
top-level `kubernetes_resources` list and streams it as multi-doc YAML
(use `--path` to target any subtree). Flip `grafana.enabled` /
`alertmanager.enabled` to `#f` in the `values` alist and the render drops
resources — the ConfigMap, Ingress, Grafana Deployment/Service and the
Alertmanager CR + Service vanish, because the gate is a real fold
predicate, not a string template.

### Introspection comes free

Because every op carries its own `source` form and (optionally) a
`label` plus `children`, the engine state is fully walkable:

```
hexol ops     INVENTORY   # flat list of top-level ops with kinds + source forms
hexol tree    INVENTORY   # full nested tree, box-drawn, descending compose-ops + when/case bodies
hexol explain PATH INVENTORY   # which ops touched a given path in the final state?
```

This is the property that distinguishes the model from Kustomize/Helm:
**rendering is not opaque**. You can ask "which op produced this
annotation?" because every effect is a labeled record, not a string
substitution buried in a template.

Each op also carries the **authored source line** that produced it — the
`at:` field below. This works even when the op is built deep inside a
library helper: the body-taking macros (`hx-ops` / `hx-when` / `hx-case` /
`with-namespace`) bind the line of each form they
evaluate, so a `resource` op emitted by `(app #:replicas 2 …)` is blamed on
the `app` call, not on a line inside `hexol/k8s.scm`.

```
$ ./bin/hexol explain kubernetes_resources.8.spec.replicas \
              examples/kubernetes.scm
;; path:      (kubernetes_resources 8 spec replicas)
;; final:     2
;; 1 op(s) touched this path:

  step 11: resource Deployment/loulou
    at:     examples/kubernetes.scm:36     # the (app … #:replicas 2) call
    before: #f
    after:  2
```

A few resources are *derived at fold time* rather than at author time —
e.g. the `Service` that `(expose …)` synthesizes from a workload — and
show `at: unknown (no source info)`, because no authored form is on the
stack when they are built.

The trace is filtered to leaf ops (those with no children), so compose
wrappers like `app` or `aws-rds` don't clutter the output — you see
the actual mutator that produced each change.

### Use cases this shape unlocks

A non-exhaustive list of things that fit naturally into the fold-of-ops
model — most are a few dozen lines of user code each:

- **Multi-target rendering** — same inventory, different effects: K8s
  resources, Terraform JSON, Ansible playbooks, systemd units. The
  state is just an alist; what you do with it is the renderer's choice.
- **Policy-as-code gates** — `compliance-all` is already this; extend
  with org-specific rules (PSP, NetworkPolicy presence, namespace
  conventions, image SBOM hashes).
- **Drift detection** — fold the live cluster into state, fold the
  desired inventory, diff.
- **Progressive delivery** — `(hx-when (attrs (canary? #t)) ...)` swaps a
  Deployment's image tag and replica count for one slice of the fleet.
- **Cost / quota budgeting** — a transform sums CPU/memory requests
  across resources, writes a `(budget)` block, and a compliance check
  fails the build if the per-namespace budget is exceeded.
- **Secret materialization** — a method reads from Vault / SOPS at
  fold time and emits `Secret` resources; the checksum op already
  annotates dependent Deployments.
- **Multi-cluster fan-out** — one `(load-inventory-file ...)` per cluster
  inside a `(hx-when (attrs (cluster ...)))`, with shared baselines above.
- **Migration scaffolding** — bundle "rename API group X → Y" as a
  named op; ship it, see it in `make tree`, delete it after one
  release.
- **Dry-run diffs across queries** — render two queries, diff the
  resulting alists; the model guarantees both are pure functions of
  the inventory + attributes.
- **Per-team plugins as Guile modules** — each team ships
  `(team-foo extensions)` exporting their own ops; the top-level
  inventory imports and uses them.

## Status

POC. The kernel and surface are functional; the Kubernetes example
covers ~10 user-space extensions; tests cover the visible behavior. The CLI
ships `render` / `ops` / `tree` / `explain` (the last is per-path change
tracing via `resolve-with-trace`). **Not yet implemented:** the rest of the
introspection consumer surface — diff between two queries, a stepper, a
dead-code linter — and the schema/contract layer for result validation.

## License

Copyright (C) 2026 Polyedre.

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version. See [`LICENSE`](LICENSE) for the full text.
