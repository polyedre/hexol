# Extending hexol

Everything beyond the kernel is user-space. This document covers the
extensibility model, the rule for what belongs in a library, two worked
target libraries (Terraform and a Helm-chart conversion), and the
introspection you get for free.

## The contract

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

## What goes in the library (and what doesn't)

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

## The two author surfaces

hexol has **two** value rules, chosen by the enclosing form — never ambiguous,
because the form head tells you which you're in:

- **The merge / config-tree layer** — `hx-merge`, `hx-append`, and
  `hx-when`/`hx-case` predicates. Bare symbols **auto-quote** (`(cni cilium)`
  → the symbol `cilium`), nesting is bare (`(network (mtu 9000))`), and a
  computed value uses the `($ …)` marker (deferred to fold time, where
  `attr`/`get` read accumulated state). This layer is enum- and
  attribute-heavy, and symbol values are routinely compared against the
  symbol-valued query attributes — so auto-quoting is the right default.

- **Typed library constructors** — everything built with `define-construct`
  (all of `(hexol k8s)`, the SQL column sugar, …). Values are **evaluated
  Scheme** (`(image "x")`, `(replicas (if prod? 3 1))`, `(uuid (ref …))`);
  strings are quoted, references and arithmetic are natural. No `$`.

The schema-less escapes (`terraform-resource`, the ansible `task`,
`custom-resource`'s `spec`) are also evaluate-by-default, but keep an explicit
`(block …)` nesting marker: with evaluated values and no per-field schema,
nothing else can tell a nested block from an attribute whose value is a call.

## Building a typed constructor: `define-construct`

`(hexol construct)` provides `define-construct`, the one mechanism every typed
library constructor is built on. It turns a positional `#:head` + a `#:fields`
schema + a `#:build` expression into a record-body constructor: defaults,
required fields, coercions, boolean flags, and unknown-key errors (with a
nearest-key suggestion) — everything the old `#:`-keyword `define*` surface
gave, minus the hand-quoted alists its argument values used to collapse into.

```scheme
(define-construct deployment
  #:head name                                   ; positional; (a b) for several
  #:fields ((image     #:required)              ; missing → compile error
            (port      #:default 8080)          ; default value (library scope)
            (replicas  #:default 1)
            (env       #:map)                   ; free-form nested alist
            (env-from  #:list)                  ; (k a b …) → (list a b …); ,@xs splices
            (resources #:coerce normalize-resources)  ; wrap the value in (P …)
            (privileged #:flag))                ; (privileged) → #t, absent → #f
  #:build (%deployment #:name name #:image image #:port port …))   ; any value/op
```

Field kinds: plain scalar, `#:flag` (valueless `(x)` ≡ `#t`), `#:list`,
`#:map` (free-form, string keys allowed for file-shaped data), and
`#:construct C` (each entry expands to `(C . args)`; with `#:repeated`, the
occurrences collect into a list — this is how RBAC `(rule …)` works). `#:build`
sees the head params and every field bound as locals and may return a plain
value (a column, a task) or an op (a resource) — the engine is agnostic.

`#:open? #t` lets unknown `(key value)` entries through into an `extra` local
(an alist) instead of erroring — for generic forms whose key set isn't fixed.

A `#:list` field accepts both literal entries and a spliced runtime list, via
the `,@` (unquote-splicing) marker — so a computed list of entries needs no
raw-alist escape:

```scheme
(deployment "api" (image "x:1")
  (env ,@base-env (FOO "1")))      ; base-env (a runtime list) ++ one literal entry
```

**This is not just for library authors.** `define-construct` (and
`construct-map-entries`) are re-exported from every target library, so an
inventory that already does `(use-modules (hexol k8s))` can define its *own*
typed constructors that read exactly like the built-in ones — no extra import.
This is how a homelab composes app bundles (`examples/homelab.scm`):

```scheme
(define-construct stateful-app                 ; PVC + Deployment + Service (+ route)
  #:head name
  #:fields ((image #:required) (port #:required)
            (storage #:default "5Gi") (mount-path #:default "/data")
            (env #:list) (route-host #:default #f))
  #:build
  (compose-ops 'stateful-app `(stateful-app ,name)
    (list (persistent-volume-claim name (size storage))
          (deployment name (image image) (port port) (replicas 1)
            (env ,@env)                        ; splice the caller's runtime env list
            (volumes (mount (pvc name) mount-path)))
          (service name (port port)))))

(stateful-app "gitea" (image "gitea/gitea:1.22") (port 3000) (storage "10Gi"))
```

Reach for it whenever a `define*`/`#:keyword` helper would otherwise make your
own abstractions read differently from the library's. Genuine procedures and
macros (appliers, `split-with`-style rule builders) stay `#:keyword` — that's
idiomatic Scheme, not a constructor surface.

Because the schema names each field's kind, a typed constructor needs **no**
nesting marker: `(deployment "api" (env (LOG_LEVEL "info")))` is unambiguous.
Composites and the alist-producing layer stay plain Scheme — a `define-construct`
`#:build` just calls them — so adding the record-body surface is additive and
leaves rendered output unchanged.

## What we built on top, without touching the kernel

The Kubernetes layer is **entirely user-space** — no kernel changes were
required for any of it. It now ships as the `(hexol k8s)` submodule
(`hexol/k8s.scm`), which `examples/kubernetes.scm` and the
kube-prometheus-stack conversion both consume via `(use-modules (hexol
k8s))`. It is still just Scheme procedures returning ops:

| Feature                           | How it's built                                                           |
|-----------------------------------|--------------------------------------------------------------------------|
| `(resource <alist>)`              | A procedure that returns `op:append` into `(kubernetes_resources)`.      |
| `app` / `public-app`              | Procedures that build N resource ops and bundle them via `compose-ops`.  |
| `configmap` / `secret`            | Same — methods returning resource ops.                                   |
| `tls-all`                         | A `transform-resources` walking Ingresses and deep-merging TLS sections. |
| `annotate-all` / `label-all`      | `transform-resources` over every resource.                              |
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

## Where extension lands, by shape of need

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

## Worked example: the Terraform target

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

## Worked example: converting a Helm chart

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
./bin/hexol render -o yaml examples/helm-kube-prometheus-stack.scm   # -> 30 manifests (multi-doc YAML)
./bin/hexol explain kubernetes_resources.10.spec.replicas \
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

## Introspection comes free

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
$ ./bin/hexol explain kubernetes_resources.10.spec.replicas \
              examples/kubernetes.scm
;; path:      (kubernetes_resources 10 spec replicas)
;; final:     2
;; 1 op(s) touched this path:

  step 13: resource Deployment/loulou
    at:     examples/kubernetes.scm:39     # the (app … #:replicas 2) call
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

## Use cases this shape unlocks

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
