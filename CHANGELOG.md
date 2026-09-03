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
