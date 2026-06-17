# Hexol

*Write your config in a real programming language.*

An inventory is a program. You run it, and it builds one big JSON-compatible data structure — your whole config,
assembled dynamically. From there hexol renders it to whatever you need: Kubernetes manifests, Terraform JSON, Ansible
playbooks, SQL, plain YAML.

Hexol is both:
- a **library** — the Scheme you write inventories with, plus target libraries (Kubernetes, Terraform, …) layered on
  top, and
- a **CLI** — to act on an inventory: `render` it, `apply` it, `inspect` what it produced.

## Example

An inventory is a program that builds your config. Here's a Kubernetes one
([`examples/kubernetes.scm`](examples/kubernetes.scm)):

```scheme
(use-modules (hexol k8s))

(hx-ops
  (with-namespace "loulou"
    ;; A Deployment (+ its Service). Its ConfigMap and Secret are pulled in by
    ;; name — one becomes `envFrom`, the other a mounted volume. Positional
    ;; name, then `(key value)` entries; values are evaluated Scheme.
    (app "loulou"
         (image "secure.io/loulou:2.1") (port 9000) (replicas 2)
         (env-from (cm "loulou-config"))
         (volumes  (mount (sec "loulou-secret") "/etc/loulou/secret"))
         (resources "200m-*/256Mi"))

    ;; The config the Deployment above consumes — ordinary Scheme data.
    (configmap "loulou-config"
               (data (LOG_LEVEL "debug") (CACHE_SIZE "256")))
    (secret    "loulou-secret"
               (data (DB_PASSWORD "bG91bG91LXNlY3JldA=="))))

  ;; Cross-cutting pass: hash every Deployment's referenced ConfigMaps and
  ;; Secrets, and stamp the result onto the pod template as an annotation —
  ;; so a config change forces a rollout. No templating, just code.
  (checksum-config))
```

A few things this buys you over plain manifests:

- The Secret is attached to the Deployment without hand-writing the `volumes`
  and `volumeMounts` sections — `(mount …)` wires both ends.
- `"200m-*/256Mi"` expands to the full `resources` block (CPU request `200m`,
  memory request + limit `256Mi`).
- `checksum-config` runs *after* every resource is built, finds each
  Deployment's ConfigMaps and Secrets, hashes them, and stamps a
  `config/checksum` annotation onto the pod template — so a config change
  forces a rollout, for *every* workload, for free. In Helm you'd hand-write a
  `sha256sum` per Deployment.

## Install

Hexol runs on [Guile](https://www.gnu.org/software/guile/) 3.x — install that,
clone the repo, and run `./bin/hexol` (it auto-compiles on first use):

```sh
git clone https://github.com/Polyedre/hexol && cd hexol
./bin/hexol render -i examples/kubernetes.scm
```

The CLI itself shells out to nothing. Individual features do, and only when you
use them: `helm`/`yq` to expand charts, `sops` for inline secrets, and
`tofu`/`kubectl`/`talosctl` for `apply`. Install whichever you need.

## CLI Usage

```sh
./bin/hexol render -o json -i examples/kubernetes.scm

# act on it (appliers an inventory registers via `applies-with`)
./bin/hexol apply --list -i examples/kubernetes.scm                       # show the applier pipeline
./bin/hexol apply --dry-run -i examples/kubernetes.scm                    # delegate to each tool's dry-run

# introspect: rendering is not opaque
./bin/hexol tree -i examples/kubernetes.scm                               # op tree (with hashes)
./bin/hexol show OP_HASH -i examples/kubernetes.scm                       # one op: source + delta
./bin/hexol explain regions.alpha5.network.cni -i examples/inventory.scm  # what touched a path
```

## The Library

While the kernel is target-agnostic, the library provide a few syntaxic sugar helpers:

- **Kubernetes** — Deployments, Services, ConfigMaps, Secrets, and
  cross-cutting passes like `checksum-config`. Render to a manifest stream with
  `-o yaml`.
- **Terraform** — providers, resources, and data sources as Scheme, rendered to
  `terraform init`-ready JSON with `-o terraform`. See
  [`examples/terraform.scm`](examples/terraform.scm).
- **Ansible** — plays and tasks accumulated into a playbook, rendered with
  `-o ansible`. See [`examples/ansible.scm`](examples/ansible.scm).
- **Secrets (SOPS)** — secrets live inline in the inventory, encrypted at rest
  with [sops](https://github.com/getsops/sops): no separate `*.sops.yaml` files
  to keep in sync. `(secret-ref 'key)` is a cheap marker, so only `render`
  shells out to sops; manage the store with the `hexol secret` subcommands. See
  [`examples/homelab.scm`](examples/homelab.scm) and
  [`docs/authoring.md`](docs/authoring.md#secrets-inline-sops-backed).

Inventories can also register their own renderers via `renders-with` — the
[`database-schema.scm`](examples/database-schema.scm) and
[`ledger.scm`](examples/ledger.scm) examples add `-o sql` and `-o ledger` that
way.

## FAQ

**How is this different from Pulumi, CDK, jsonnet, or Dhall?**
Those build your config in memory and hand it off. Hexol keeps the *build
itself* around: resolving an inventory is a chain of small labeled steps over a
growing data structure, and every value remembers the step that set it — its
source, its file and line, the exact change it made. So you can point at any
value in the output and ask "what set this, and to what?" — `tree`, `show`, and
`explain` answer it. No other config tool does that.

**Is this a serious Kubernetes/Terraform tool, or a Scheme demo?**
The Kubernetes and Terraform libraries are the real ones —
[`examples/homelab.scm`](examples/homelab.scm) deploys a 3-node Talos cluster to
OVH for real, end to end. The SQL and Ledger renderers are tiny example-file
extensions, there to show the kernel doesn't care what it's building. Take them
as proof the engine is general, not as products.

**Is it production-ready?**
It's young: one author, no CI yet, no outside production users. It has a test
suite (`make test`) and it does run a live homelab. Kick the tires before you
bet a cluster on it.

## Documentation

- [`docs/model.md`](docs/model.md) — the engine model and its rationale.
- [`docs/authoring.md`](docs/authoring.md) — writing inventories: surface
  forms, helpers, file splitting, ordering, and the repository layout.
- [`docs/extending.md`](docs/extending.md) — building target libraries,
  the kernel/library/example boundary, worked Terraform and Helm
  conversions, and introspection.
- [`docs/cmdb.md`](docs/cmdb.md) — the event-sourced CMDB built on the same
  kernel (fact log + versioned libraries + HTTP server).

## License

Copyright (C) 2026 Polyedre. GNU General Public License v3.0 or later; see
[`LICENSE`](LICENSE) for the full text.
