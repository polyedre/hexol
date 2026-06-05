# CMDB (as built)

A small configuration-management database on the same fold-of-ops kernel as the
inventory engine. **Why:** instead of storing current state behind a REST API
with bolted-on audit, every change is a **fact** appended to a log, and state
is the **fold** of those facts. Provenance, time-travel, and replay come for
free, and the *meaning* of a fact is itself versioned in the log.

This documents what ships in `cmdb/` and `bin/`. It is a POC.

## The fact log

A fact is one sexp on its own line in a log file (default `cmdb.log`):

```scheme
(region alpha5 ((region . alpha5) (dc . alpha) (geo . eu) (tier . prod) ...))
(promote alpha5 (apps ingress-nginx chart version) "4.11.3")
(bump-lib "v2")
```

To apply a fact, the store looks up its head symbol (`region`, `promote`, …) in
the **currently active library module**, calls that procedure with the fact's
args, and folds the ops it returns into in-memory state (`cmdb/store.scm`).
State is rebuilt by replaying the whole log — `cmdb-refold!`.

Append is log-first: the fact is written to disk, then applied. A bad fact
leaves the log consistent (the next refold fails at the same point).

## Versioned libraries — why a fact can mean different things over time

The active library is controlled *by a fact*. The reserved op

```scheme
(bump-lib "v2")
```

switches the active library to module `(cmdb libraries v2)` (file
`cmdb/libraries/v2.scm`) for every **subsequent** fact. Replay is
**contemporaneous**: each fact applies through whichever library was current
when it was appended. So bumping the library is an in-log event with an audit
trail — facts written before the bump keep their old rendering.

`cmdb/libraries/v1.scm` and `v2.scm` each export three ops:

| op | effect |
|----|--------|
| `(merge <subtree>)`            | `op:merge` a literal subtree into state |
| `(region <name> <attrs>)`      | render the whole per-region subtree and `op:set` it under `(regions <name>)` |
| `(promote <region> <path> <v>)`| `op:set` one path under `(regions <region> …)` — a surgical override |

`v2` differs from `v1` only in that `region` rewrites EU regions' NTP pool —
the canonical demo of evolving an op's meaning under audit.

## How `region` renders — reusing the engine

`region` doesn't store its attrs; it computes the region's full config by
`resolve`-ing a hexol inventory against them (`cmdb/region-render.scm` →
`cmdb/region-body.scm`). That body is an ordinary hexol inventory: `hx-case` on
the `geo` / `hw-profile` / `network-profile` axes, `hx-when` gating the Helm app
load (`cmdb/apps.scm`) and sovereign-region cross-cuts (`annotate-all` /
`label-all`). So facts stay ~100 bytes while the materialized subtree is large.

## Why the snapshot is the API

Every op writes directly to the canonical path a consumer reads —
`(regions <name> …)`. There is no per-query re-fold and no rendering layer: the
snapshot **is** the consumed shape. A tool like ArgoCD pulls a subtree
(`/state/regions.alpha5`) without knowing whether it was set by `region`, by
`promote`, or by hand. Adding a region is a data change (`sync-inventory`), not
a code change.

## HTTP server

`bin/cmdb-server [initial-library=v1] [log=cmdb.log] [port=8080]` boots
`cmdb/server.scm`:

| route | does |
|-------|------|
| `GET  /state`            | entire materialized state |
| `GET  /state/<dot.path>` | subtree/leaf at path (`regions.alpha5.apps`); 404 if missing |
| `GET  /facts`            | the full fact list |
| `POST /facts`            | body is one fact sexp; appended + applied |
| `GET  /health`           | `ok` |

Bodies are s-expressions (`application/scheme`); pass `?fmt=json` or
`Accept: application/json` for JSON out (`cmdb/json.scm`). Single-threaded; the
store is not safe for concurrent writes.

## Drivers

- **`bin/sync-inventory [regions=…] [url=…]`** — load a region table (a module
  exporting `regions`) and POST one `(region <name> <attrs>)` fact per entry.
  Seeds or refreshes the fleet.
- **`bin/promote app= tag= waves=<w1:w2:…> [kind=image|chart] [gate=<cmd>]`** —
  progressive rollout. For each wave it POSTs a `promote` fact per region,
  reads the path back to verify, then runs an optional shell `gate`; non-zero
  exit aborts. Waves are `:`-separated, regions within a wave `,`-separated.

```sh
./bin/cmdb-server &
./bin/sync-inventory regions=examples/regions.scm
./bin/promote app=ingress-nginx kind=chart tag=4.11.3 \
              waves=alpha5:bravo1,charlie6 gate='./smoke-test.sh'
curl -s localhost:8080/state/regions.alpha5.network.cni
```

## Layout

```
cmdb/
  store.scm          fact log, library lookup, refold (the kernel of the CMDB)
  server.scm         HTTP front-end
  json.scm           sexp -> JSON for the `?fmt=json` path
  region-render.scm  resolve the per-region body against a fact's attrs
  region-body.scm    the per-region hexol inventory (hx-case/hx-when)
  apps.scm           Helm releases per region, loaded by region-body
  libraries/
    v1.scm           merge / region / promote
    v2.scm           same, EU NTP pool patched (library-bump demo)
bin/cmdb-server      boot the server
bin/sync-inventory   push a region table as facts
bin/promote          waved image/chart rollouts
test/cmdb-store.scm  store + refold + bump-lib replay
test/cmdb-server.scm route + format tests
```
