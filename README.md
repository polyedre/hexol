# hexol

*Configuration as code: build your config using a real programming language.*

YAML, JSON, and HCL hit their limits once configuration spans many
environments and stacks: no real abstraction, no logic, endless copy-paste.
hexol is a configuration engine built on Guile Scheme, so you get the full
power of a mature language where you need it.

The core is deliberately minimal: the engine builds configuration by
chaining *Operations* — functions that read the current state and return the
updated state. Yet the model is expressive enough that the same engine drives
full Kubernetes, Terraform, and Ansible alternatives — each just a small library
on top of the kernel.

And because every change is a labeled record rather than a string
substitution, **rendering is not opaque**: you can always ask which op
produced any value in the output.

## Why

DevOps tools propose hacky solutions to make configuration dynamic:
 - templating structured YAML files using templating engines (Helm, Ansible)
 - using hardcoded for loops (`for_each` in Terraform, `loop` in Ansible)
 - relying on "count" as the only way to conditionally execute a resource in Terraform
 
 This is not satisfying. We need to embrace using real programming languages.
 Here's what's possible:

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

Did you notice?

The Secret "loulou-secret" was attached to the Deployment without having to
write to the Volumes and VolumeMounts sections.

The resource block, which is often boring to type has been condensed into a
custom string. Here, "200m-*/256Mi" would expand to:

```json
{
    "cpu": {
        "requests": "200m"
    },
    "memory": {
        "requests": "256Mi",
        "limits": "256Mi"
    }
}
```

And the cherry on top: `checksum-config` runs *after* every resource is built,
reads the resource list back out of the state, finds each Deployment's
referenced ConfigMaps and Secrets, hashes their contents, and rewrites the pod
template with a `config/checksum` annotation. Checksums for all the workloads
comes for free!

In Helm you'd hand-write a `sha256sum` over a rendered template for each
Deployment; here it's one small library function that does it for *every*
Deployment automatically.

## Secrets

Secrets live **inline in the inventory**, encrypted at rest with
[sops](https://github.com/getsops/sops) — no separate `*.sops.yaml` files to
keep in sync. One `(secrets-store …)` form holds a single sops envelope (one
data key, one MAC) for every secret; `(secret-ref 'key)` references one at a
field, and a final `(resolve-secret-refs)` op decrypts the store *once*, at
render time, and substitutes the plaintext:

```scheme
(use-modules (hexol k8s) (hexol secrets))

(secrets-store
  (version "3.12.2") (lastmodified "…") (mac "ENC[…]")
  (keys (pgp (fp "…") (enc "-----BEGIN PGP MESSAGE-----" …)))
  (data (db/password . "ENC[AES256_GCM,data:…,type:str]")))

(hx-ops
  (resource
    `((apiVersion . "v1") (kind . "Secret")
      (metadata (name . "db"))
      (stringData (password . ,(secret-ref 'db/password)))))
  (resolve-secret-refs))   ; decrypts once, at render time only
```

`secret-ref` returns a cheap marker, so `tree`/`ops` never shell out to sops —
only `render` does (and if no key is available it degrades to a clearly-marked
placeholder rather than failing). Manage the store with the `hexol secret` CLI,
which decrypts, edits the plaintext, re-seals with sops, and rewrites *only*
the `(secrets-store …)` form in place:

```sh
./bin/hexol secret init             -i inventory.scm   # add an empty (secrets-store …)
./bin/hexol secret ls               -i inventory.scm   # list keys (no decrypt)
./bin/hexol secret set   db/password -i inventory.scm   # add/replace (value arg or stdin)
./bin/hexol secret edit  db/password -i inventory.scm   # $EDITOR round-trip
./bin/hexol secret get   db/password -i inventory.scm   # decrypt one to stdout
./bin/hexol secret rm    db/password -i inventory.scm
./bin/hexol secret rekey             -i inventory.scm   # re-seal to current recipients
```

See [`docs/authoring.md`](docs/authoring.md#secrets-inline-sops-backed) for the
load-time-vs-render-time model and the full CLI.

## Quick start

The inventory is never positional — pass it with `-i/--inventory FILE` (or set
`$HEXOL_INVENTORY` once for the session, then drop the flag):

```sh
./bin/hexol render -i examples/inventory.scm                          # whole state (sexp)
./bin/hexol render --path regions.alpha5 -i examples/inventory.scm    # one region's subtree

# the same CLI handles any inventory and any output format
./bin/hexol render -o yaml      -i examples/helm-kube-prometheus-stack.scm  # k8s manifest stream
./bin/hexol render -o terraform -i examples/terraform.scm                   # Terraform JSON
./bin/hexol render -o ansible   -i examples/ansible.scm                     # Ansible playbook JSON
./bin/hexol render -o sql       -i examples/database-schema.scm             # SQL DDL statements
./bin/hexol render -o ledger    -i examples/ledger.scm                      # ledger-cli journal text

# introspect: rendering is not opaque
./bin/hexol tree    -i examples/kubernetes.scm                            # op tree (with hashes)
./bin/hexol show    HASH -i examples/kubernetes.scm                       # one op: source + delta
./bin/hexol explain regions.alpha5.network.cni -i examples/inventory.scm  # what touched a path
```

`-o sql` and `-o ledger` are not built in: those two example files register
them with `renders-with` (database-schema.scm:26, ledger.scm:21). `-o
sexp|json|yaml|terraform|ansible` work on any inventory.

## Documentation

- [`docs/model.md`](docs/model.md) — the fold-of-ops engine model and its
  rationale.
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
