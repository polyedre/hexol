# Changelog

All notable changes to hexol are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the version is the one
`hexol --version` prints (`%hexol-version` in `hexol/version.scm`).

## [Unreleased]

### Added
- `diff` verb: compare two renders (or a render against live state).
- `doc` verb: documentation for the constructs an inventory uses.
- `import` verb: turn existing manifests/config into an inventory.
- `lint` verb: static checks over an inventory.
- `--validate` flag: schema-check the resolved state before rendering.
- `explain` reports the fix location for ops generated under `hx-each`.
- `explain <hash>` shows the op's delta as a unified diff, one file per
  changed path — a list of k8s resources becomes one file per resource
  (`<path>/<ns>/<Kind>/<name>.<ext>`), so file names say what changed.
  `-o FORMAT` picks the rendering (any built-in or inventory-registered
  renderer); `--diff CMD` / `$HEXOL_DIFF` swap in another differ (difftastic).
  A composition (`app`, `stateful-app`, `compose-ops`) reads as one op: its
  delta spans the whole subtree, for `show` too.
- `-o pretty-json` output format (indented JSON) for `render` and `explain`.
- `-i INVENTORY` may precede the verb: `hexol -i FILE tree`.
- `#:value` marks a `define-construct` whose `#:build` returns a value for an
  enclosing construct instead of an op; `hexol doc` shows it.
- `current-state` is exported from `(hexol kernel)`, so an extension's own
  `make-op` effect can bind it and make `get`/`attr` work inside it.
- `(hx-late LABEL body …)`: one op whose body is *built* at fold time, with
  the state bound. The escape hatch for the one surface field deferral does
  not reach — the schema-less `body`/`block` forms (`terraform-resource`, the
  ansible `task`).
- `op-realized-label` / `op-display-label` in `(hexol kernel)`: a label an
  op's effect computed while firing (a construct's head args), kept out of
  the content hash like the realized children.
- `tree --no-fold` only loads the inventory: no effect runs, nothing shells
  out or decrypts, and a construct prints by its name alone.
- The YAML and JSON emitters refuse an op in value position (`cannot render an
  op as a value … must be marked #:value`) instead of writing `#<op …>` into a
  manifest, and a `#:construct` sub-field rejects one up front.
- `op:late` in `(hexol kernel)`: the primitive both of those are built on.

### Changed
- Constructor fields (`define-construct`) are evaluated at fold time, so
  `get`/`attr` work bare inside any field —
  `(deployment "api" (image (str (get '(cfg registry)) "/api")))`. So are the
  positional head args, so a name can be read from state:
  `(custom-resource (str "vault-" (get '(env))) …)`. Only `#:value`
  constructs still evaluate where they are written. `$` remains a merge-layer
  marker.
- `label-all` and `annotate-all` are constructs with one `#:map` field —
  `(label-all (labels (env (get '(cfg env))) ,@computed))` — so a cross-cutting
  label set can be read from resolved state. The old form took an already-built
  alist: `(label-all '((k . "v")))` becomes `(label-all (labels (k "v")))`.
  `transform-resources` stays a procedure; it takes a procedure, not data.
- Scope forms (`with-namespace`, `with-schema`, `in-year`, …) bind their
  parameter at fold time as well as at build time, so a field defaulting to
  `(current-k8s-namespace)` still sees the scope. **A hand-rolled scope macro
  that `parameterize`s around a `compose-ops` no longer works** — the binding
  is gone by the time a field evaluates, and a default like
  `(current-k8s-namespace)` silently falls back to `"default"` instead of
  erroring. Build such macros on `scope-ops`, which binds at both times;
  `compose-ops` binds nothing and now says so.
- A construct's tree line now sits above the resources it produces and carries
  its head args (`configmap app-config`). Both the label and those produced
  ops only exist once the inventory folds, so **`hexol tree` now folds once by
  default**, running the same effects `render` runs (curl, sops, helm); `show`
  and `explain` always have. `tree --no-fold` and `ops` keep the old
  load-only behaviour: no effect runs, and a construct prints by its name
  alone (`configmap`). The content hash is unaffected by the fold.
- Constructs' content hashes changed (their source form is now the authored
  call), so `explain`/`show` addresses noted from an older tree no longer
  resolve — re-read them from `hexol tree`. Two textually identical construct
  calls share a hash, as any two identical ops always have.

### Fixed
- `checksum-config` annotates every `spec.template` workload (Deployment,
  DaemonSet, StatefulSet, Job), not Deployments alone.

## [0.1.0] - 2026-09-03

First tagged release: the engine, the author surface, the target libraries,
and the CLI as they exist today.

### Added
- Kernel: inventories resolve as a fold of labeled ops (`merge`, `set`,
  `append`, `when`, `case`) over one state; every value keeps the op that set
  it, so `tree`, `show`, and `explain` can answer "what set this?".
- Author surface: `hx-ops`, `hx-each`, `hx-merge`, `hx-when`, `hx-case`,
  `hx-append`; `define-construct` for record-body constructs.
- CLI verbs: `render` (`-o sexp|json|yaml|terraform|ansible`, `--path`),
  `apply` (`--only`, `--dry-run`, `--list`), `tree` (`-v` with per-op fold
  time), `explain PATH|HASH`, `show HASH`, `secret`, and `--version`.
  Inventories add verbs with `defines-action`; global `--color`.
- Inventory is `-i/--inventory` or `$HEXOL_INVENTORY`, never a positional.
- Kubernetes library: standard resources (Deployment, Service, ConfigMap,
  Secret, ...), Helm chart expansion, `checksum-config` rollout pass, a
  `kubectl` applier.
- Terraform library: providers/resources/data sources rendered to Terraform
  JSON; `tofu` applier with output reporting and a `validate` action.
- Ansible library: plays and tasks accumulated into a playbook.
- Inline SOPS/age secrets, path-keyed, with `(secret-ref 'k)` markers;
  managed with `hexol secret ls|get|set|edit|rm|rekey|init`.
- Inventory-registered renderers (`renders-with`) and appliers
  (`applies-with`); SQL and Ledger renderers as example extensions.
- Render cache for `helm template` / remote-manifest shell-outs.
- Examples: kubernetes, terraform, ansible, secrets, helm
  kube-prometheus-stack, database-schema, ledger, and the homelab (3-node
  Talos on OVH, deployed end to end).
- Docs: `docs/model.md`, `docs/authoring.md`, `docs/extending.md`.
- Packaging: `manifest.scm` (Guix dev shell, CI), `guix.scm` (Guix package),
  `Containerfile` (OCI image), `flake.nix` (Nix package + devShell).
- CI: GitHub Actions runs build, tests, and example renders under Guix, and
  builds the container image.

[Unreleased]: https://github.com/Polyedre/hexol/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Polyedre/hexol/releases/tag/v0.1.0
