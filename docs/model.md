# The model

The inventory is a **list of operations**; resolution is a **left fold** over
that list, seeded with the query's attributes. That is the whole engine —
roughly a page of Scheme in `hexol/kernel.scm`. Everything else (the merge
macro, `attrs`, the CLI, `explain`) is ergonomics on top.

## Primitives

- **State** is a nested alist. The top-level key `attributes` holds the query;
  sibling keys hold accumulated config.
  ```
  ((attributes (dc . gra) (role . web))
   (nginx      (workers . 8)))
  ```
- **An op** is an endomorphism `state -> state`: pure, total, deterministic.
- **The inventory** is a list of ops in source order.
- **Resolution** is `(fold apply-op ((attributes . <query>)) inventory)`.

The algebra is the Endo monoid: identity is the no-op, composition is the
binary op, associativity is free. No monad, no priorities, no specificity
scoring — **order is execution order**.

## Why attributes-are-seed

Attributes aren't a separate concept outside the inventory; they *are* the
initial state. Reading `(attributes dc)` reads the query; reading
`(nginx workers)` reads partial result — same mechanism, same address space.
This collapses an axis Hiera keeps separate.

## Why `when`/`case` are recursive folds

`hx-when`/`hx-case` are the only branching. Their body is itself a list of ops,
and resolution recurses with the *same* fold. Consequences:

- Nested `when` reads as AND; indentation mirrors logical conjunction.
- A `when` body is structurally identical to a top-level inventory — one
  dispatcher handles both, there is no second language.
- A statically-`#f` predicate is trivially dead code.

## Why ops are records, not bare closures

Behaviour is `state -> state`, but an op is *stored* as a record carrying the
effect **and** its source form, label, and children:

```
<op> = (kind, source, effect : state -> state, label, children)
```

The fold runs `effect`; tooling (`explain`, `tree`, `ops`) reads `source`
without executing anything — **loading an inventory has no side effects**, so
`tree`/`ops` never shell out, curl, or decrypt.

A construct discovers the ops it produces only by running, so an op also
carries them (`op-realized-children`) — filled in on fire and excluded from the
content hash. Seeing that layer therefore costs a fold, which is why it is
opt-in: `hexol tree --realize`. This is the price that buys back introspection —
without it the inventory would be an opaque black box. It is the property that
separates this from Helm/Kustomize: **rendering is not opaque**, every effect
is a labelled record, not a string substitution buried in a template.

## Two value rules, one seam

The surface has two layers with opposite rules about what a value in a body
position means:

- **Config tree** (`hx-merge`/`hx-append`/`hx-when`/`hx-case`): nothing in
  value position is evaluated. Symbols self-quote, and any parenthesised form
  is a nested map — so *every* computed value takes the `$` marker, which
  defers it to fold time where `attr`/`get` exist.
- **Typed constructors** (`define-construct`: `(deployment …)`, `(varchar …)`,
  …): the schema names each field, so values are ordinary Scheme. No `$` —
  the constructor call *is* an op, and its fields evaluate when that op fires,
  so `attr`/`get` are already in scope.

```scheme
(hx-merge (nginx (workers ($ (* 2 (attr 'cores))))))   ; needs $
(deployment "api" (image (get '(cfg image))) (replicas (if prod? 3 1)))
```

So `$` is a marker the *config-tree* layer needs and nothing else: the seam is
which layer you are in, not when things run. Two things still evaluate where
they are written — a constructor's positional head args (they label the op
before the fold) and a `#:value` construct (it returns data for the construct
around it).

## Why ordering is load-bearing

A computed value (`($ (* 1024 (get '(nginx workers))))`) sees whatever state
exists *at that point in the fold*. So order matters twice:

1. Later ops override earlier ones on conflicting paths (DC fragment beats
   service baseline).
2. A derivation placed before the writes it depends on silently reads a stale
   value. Mitigation belongs in a lint pass, not in the model.

## Deliberately *not* in the model

- No priorities or specificity scoring — order is execution order.
- No result type system — shape validation is a separate opt-in contract layer.
- No named "features" primitive — reusable predicates are ordinary procedures.
- No reverse index ("all nodes with feature X") — predicates are arbitrary
  functions, decidable only by running them against a concrete query.

See the [README](../README.md) for the shipping API.
