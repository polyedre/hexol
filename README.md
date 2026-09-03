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

**Status:** 0.1.0 (`hexol --version`); see [CHANGELOG.md](CHANGELOG.md) for
what's in it and what's coming.

Hexol runs on [Guile](https://www.gnu.org/software/guile/) 3.x and needs two
Guile libraries: **guile-json** (the `(json)` module) and **guile-libyaml**
(the `(yaml)` module). It also uses `jq`. All of these are declared in
[`manifest.scm`](manifest.scm), which is the source of truth for dependencies.
Three ways to get them:

**From source** — install Guile 3.x, guile-json, guile-libyaml, and jq however
your distro provides them (or let [Guix](https://guix.gnu.org/) read the
manifest), then run from the checkout:

```sh
git clone https://github.com/Polyedre/hexol && cd hexol
./bin/hexol render -i examples/kubernetes.scm                                 # auto-compiles on first use
guix shell -m manifest.scm -- ./bin/hexol render -i examples/kubernetes.scm   # with Guix
```

(The repo's `.envrc` runs the `guix shell` for you under
[direnv](https://direnv.net/).)

**Container** — an OCI image built from [`Containerfile`](Containerfile)
(`make image` builds it locally); mount your inventories in:

```sh
podman run --rm -v "$PWD:/w" -w /w ghcr.io/polyedre/hexol render -i examples/kubernetes.scm
```

**Nix** — [`flake.nix`](flake.nix) packages the CLI and provides a dev shell:

```sh
nix run github:Polyedre/hexol -- render -i examples/kubernetes.scm
nix develop github:Polyedre/hexol   # guile + deps in a shell
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
./bin/hexol diff -i examples/kubernetes.scm                               # drift vs the world: exit 0 clean, 1 drift, 2 error
./bin/hexol diff --explain -i examples/kubernetes.scm                     # each changed field + the op that set it (kubectl)
./bin/hexol render -o yaml --validate -i examples/kubernetes.scm          # pipe the stream through kubeconform (if on PATH)

# introspect: rendering is not opaque
./bin/hexol tree -i examples/kubernetes.scm                               # op tree (with hashes)
./bin/hexol show OP_HASH -i examples/kubernetes.scm                       # one op: source + delta
./bin/hexol explain regions.alpha5.network.cni -i examples/inventory.scm  # what touched a path

# discover the library: which (key value) entries a construct accepts
./bin/hexol doc                                                           # every construct (built-in libs)
./bin/hexol doc app -i examples/kubernetes.scm                            # one construct: fields + example
```

**Migrating.** You don't rewrite what you already have — you wrap it.
`hexol import -f manifests.yaml > app.scm` turns a k8s manifest stream (or a
`kubectl get -o yaml` dump; server-populated fields are stripped) into an
inventory with one `(resource …)` per document that renders back to the same
YAML; `--sugar` lifts objects to the typed constructs (`deployment`,
`service`, `configmap`, …) wherever they fit exactly. `hexol import -f
main.tf.json --from terraform` does the same for a Terraform JSON config
(HCL text is out of scope). From there you refactor at your own pace. See
[`docs/authoring.md`](docs/authoring.md#migrating-hexol-import).

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
  shells out to sops; manage the store with the `hexol secret` subcommands.
  [`examples/secrets.scm`](examples/secrets.scm) is self-contained — it ships a
  throwaway age key, so `hexol render -o yaml -i examples/secrets.scm` decrypts
  and substitutes real plaintext on a fresh clone. See also
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
It's young: one author, no outside production users. It has a test suite
(`make test`, run on every push and PR via GitHub Actions) and it does run a
live homelab. Kick the tires before you bet a cluster on it.

## Documentation

- [`docs/model.md`](docs/model.md) — the engine model and its rationale.
- [`docs/authoring.md`](docs/authoring.md) — writing inventories: surface
  forms, helpers, file splitting, ordering, and the repository layout.
- [`docs/extending.md`](docs/extending.md) — building target libraries,
  the kernel/library/example boundary, worked Terraform and Helm
  conversions, and introspection.
- The event-sourced CMDB prototype lives on the `cmdb` branch.

## License

Copyright (C) 2026 Polyedre. GNU General Public License v3.0 or later; see
[`LICENSE`](LICENSE) for the full text.
