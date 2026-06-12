;;; hexol/kernel.scm — the whole engine.
;;;
;;; State is a nested alist with `attributes` at the root holding the query.
;;; An op is a record (kind, source, effect) where effect : state -> state.
;;; Resolution is a left fold of apply-op over a list of ops, seeded with
;;; the query.
;;;
;;; This module is the kernel only. No surface macros (`merge`, `when`,
;;; `attrs`) live here — those come in a separate module and expand to
;;; calls to `op:merge`, `op:when`, etc.

(define-module (hexol kernel)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:export (;; ops
            make-op op? op-kind op-source op-effect op-label op-children op-loc
            current-author-loc stamp-loc relabel
            op-content-hash op-short-hash
            apply-op resolve compose-ops scope-ops for-each-into
            op:merge op:set op:append op:when op:case
            op:copy op:move op:delete
            ;; state helpers
            state-get state-set state-append state-delete deep-merge deep-merge-with
            path->string
            ;; tracing (explain support)
            current-trace resolve-with-trace path-get
            ;; loader (exposed so other modules can override path resolution)
            load-inventory-file
            ;; optional per-file render adapters
            current-renderers renders-with
            ;; optional per-file apply adapters (effects)
            current-appliers applies-with))

;; ---------- op record ----------

(define-record-type <op>
  (%make-op kind source effect label children loc)
  op?
  (kind   op-kind)
  (source op-source)
  (effect op-effect)
  ;; Optional human-friendly one-line label for debug/listing tools.
  ;; #f means "fall back to the kind". Set at construction by ops
  ;; that have meaningful identity (e.g. (load "path"), (resource
  ;; "Deployment/api")). `merge` and other content-shaped ops typically
  ;; leave it #f because their source is the better description.
  (label    op-label)
  ;; Optional list of nested op records. Ops that conditionally or
  ;; unconditionally fold sub-ops (when, case, user-defined compose
  ;; helpers) put them here so introspection can descend past the
  ;; closure boundary. Empty for leaf ops.
  (children op-children)
  ;; Optional (file . line) of the authored inventory form responsible for
  ;; this op — even when the op is built deep inside a library helper
  ;; (e.g. `(public-app ...)` -> several `resource` ops, all blamed on the
  ;; one `public-app` call). #f when no source info is available. Captured
  ;; from `current-author-loc`, which the body-taking surface macros bind
  ;; to each authored form's `syntax-source` while it is evaluated.
  (loc      op-loc))

;; Bound by the body-taking surface macros (inventory / when / case /
;; with-namespace) to a (file . line) pair around evaluating each authored
;; body form. `make-op` snapshots it, so every op — including ones built by
;; ordinary library *functions* called from that form — inherits the line
;; the author actually wrote. Inner forms shadow outer ones, so the most
;; specific authored location wins.
(define current-author-loc (make-parameter #f))

(define* (make-op kind source effect #:optional (label #f) (children '()))
  "Construct an op of KIND whose EFFECT is a (state -> state) procedure.
SOURCE is the authored form for debugging, LABEL an optional one-line
description (#f falls back to KIND), and CHILDREN the nested ops for
introspection.  The op's source location is snapshotted from
`current-author-loc'."
  (%make-op kind source effect label children (current-author-loc)))

;; Return OP with only its human-friendly LABEL changed, preserving kind,
;; source, effect, children, and source location. The combinator that
;; target libraries (and surface) use to stamp a domain identity —
;; "resource Deployment/api", "tx Rent", "table users" — onto an op built
;; by a generic constructor (op:append / op:merge), which otherwise carries
;; the bland "append kubernetes_resources" label. Unlike rebuilding via
;; `make-op`, this keeps the original `op-loc` rather than re-snapshotting
;; `current-author-loc`, so it is correct to call any time, not just
;; immediately after construction.
(define (relabel op label)
  "Return OP with its LABEL replaced, preserving kind, source, effect,
children, and source location."
  (%make-op (op-kind op) (op-source op) (op-effect op)
            label (op-children op) (op-loc op)))

;; (stamp-loc form) evaluates `form` with `current-author-loc` bound to
;; `form`'s own source location, so any ops built while it runs are blamed
;; on the line the author wrote. The body-taking surface macros wrap each
;; of their sub-forms in this. When `form` carries no source info (REPL,
;; macro-generated) it is evaluated unchanged. Line numbers from
;; `syntax-source` are 0-based; we store them 1-based to match editors.
(define-syntax stamp-loc
  (lambda (x)
    (syntax-case x ()
      ((_ form)
       (let* ((s    (syntax-source #'form))
              (file (and s (assq-ref s 'filename)))
              (line (and s (assq-ref s 'line))))
         (if (and file line)
             #`(parameterize ((current-author-loc
                                '#,(datum->syntax #'form (cons file (+ line 1)))))
                 form)
             #'form))))))

;; ---------- content hashing ----------
;;
;; A stable, content-derived hash for each op — the addressable identity
;; `hexol tree` prints and `hexol show <hash>` resolves. It is a Merkle hash:
;; an op's hash folds in its kind, its captured source form, its label, and
;; the hashes of its children, so editing any op changes its own hash and
;; its ancestors' (like a git tree) while leaving siblings untouched. The
;; op's *effect* (an opaque closure) and its source *location* are
;; deliberately excluded — the hash names what an op DOES structurally, not
;; where it was written, so moving code between lines does not churn hashes.
;;
;; Genuinely identical sibling subtrees (same kind/source/label/children)
;; share a hash; that is honest — there is nothing to tell them apart — and
;; `show` reports the ambiguity rather than guessing. The hash is FNV-1a/64
;; (no crypto needed for addressing, no external dependency); swap
;; `fnv1a-64` for a gcrypt digest if collision resistance is ever required.

(define %fnv-offset 14695981039346656037)
(define %fnv-prime  1099511628211)
(define %u64-mask   (- (expt 2 64) 1))

(define (fnv1a-64 str)
  "FNV-1a 64-bit hash of STR's UTF-8 bytes, as an exact integer."
  (let ((bytes (string->utf8 str)))
    (let loop ((i 0) (h %fnv-offset))
      (if (>= i (bytevector-length bytes))
          h
          (loop (+ i 1)
                (logand %u64-mask
                        (* %fnv-prime
                           (logxor h (bytevector-u8-ref bytes i)))))))))

(define (%hex16 n)
  "N (a 0..2^64-1 integer) as a 16-char zero-padded lowercase hex string."
  (let ((s (number->string n 16)))
    (string-append (make-string (max 0 (- 16 (string-length s))) #\0) s)))

(define (op-content-hash op)
  "Return OP's stable content hash, a 16-char lowercase hex string, derived
from its kind, source form, label, and the content hashes of its children."
  (let* ((child-hashes (map op-content-hash (op-children op)))
         (canonical (string-append
                     (symbol->string (op-kind op)) "\x00;"
                     (format #f "~s" (op-source op)) "\x00;"
                     (or (op-label op) "") "\x00;"
                     (string-join child-hashes ","))))
    (%hex16 (fnv1a-64 canonical))))

(define* (op-short-hash op #:optional (n 8))
  "The first N (default 8) characters of OP's content hash."
  (substring (op-content-hash op) 0 n))

;; ---------- tracing ----------
;;
;; `current-trace`, when bound to a mutable box (a one-element list),
;; collects every apply-op call's (op . after-state) tuple. The trace
;; is recorded in *fire order*, which means nested ops inside compose
;; wrappers / when / case appear before the wrapper itself. Wrappers
;; don't change state independently of their children, so explain-like
;; tools typically filter the trace to leaves (ops with empty children).

(define current-trace (make-parameter #f))

(define (apply-op op state)
  "Apply OP's effect to STATE and return the new state.  When
`current-trace' is bound to a box, records the (op . after-state) pair."
  (let ((new-state ((op-effect op) state)))
    (let ((box (current-trace)))
      (when box
        (set-car! box (cons (cons op new-state) (car box)))))
    new-state))

(define (resolve ops attributes)
  "Fold OPS left-to-right over a seed state holding ATTRIBUTES (the query)
under the `attributes' root key, returning the final resolved state."
  (fold (lambda (op state) (apply-op op state))
        `((attributes . ,attributes))
        ops))

;; Returns two values: the final state and the trace as a list of
;; (op . after-state) pairs in fire order.
(define (resolve-with-trace ops attributes)
  "Like `resolve', but return two values: the final state and the trace as
a list of (op . after-state) pairs in fire order."
  (let ((box (list '())))
    (let ((result (parameterize ((current-trace box))
                    (resolve ops attributes))))
      (values result (reverse (car box))))))

;; Walk a nested state by a path of symbols (alist keys) and integers
;; (list indices). Returns #f if any step is missing.
;;
;; A symbol step looks the key up in an alist (a map); an integer step
;; indexes into a list. List-valued fields are stored as a plain list of
;; their elements, so `(... rules 0 host)` reads the host of the first
;; rule with no special-casing.
(define (path-get state path)
  "Walk STATE by PATH, a list of symbol alist-keys and integer list
indices, returning the value found or #f if any step is missing."
  (cond
    ((null? path) state)
    ((integer? (car path))
     (and (list? state) (>= (car path) 0) (< (car path) (length state))
          (path-get (list-ref state (car path)) (cdr path))))
    ((alist? state)
     (let ((entry (assq (car path) state)))
       (and entry (path-get (cdr entry) (cdr path)))))
    (else #f)))

;; ---------- state helpers ----------

(define (alist? x)
  (and (list? x) (every pair? x)))

(define (state-get state path)
  "Look up the value at PATH (a list of symbol keys) in the nested alist
STATE, returning #f if any key along the way is missing."
  (cond
    ((null? path) state)
    ((not (alist? state)) #f)
    (else
     (let ((entry (assq (car path) state)))
       (if entry
           (state-get (cdr entry) (cdr path))
           #f)))))

(define (state-set state path value)
  "Return STATE with VALUE stored at PATH (a list of symbol keys),
creating intermediate alists as needed and overwriting any non-alist
subtree found where one was expected."
  (cond
    ((null? path) value)
    ((not (alist? state))
     ;; not an alist where we expected one — overwrite the subtree.
     (state-set '() path value))
    (else
     (let* ((key      (car path))
            (rest     (cdr path))
            (entry    (assq key state))
            (existing (if entry (cdr entry) '()))
            (new-val  (state-set existing rest value)))
       (if entry
           (map (lambda (e)
                  (if (eq? (car e) key) (cons key new-val) e))
                state)
           (append state (list (cons key new-val))))))))

(define (state-append state path value)
  "Return STATE with VALUE appended to the list at PATH, treating a
missing path as the empty list."
  (let ((current (or (state-get state path) '())))
    (state-set state path (append current (list value)))))

(define (state-delete state path)
  "Return STATE with the entry at PATH (a list of symbol keys) removed,
pruning nothing else.  A missing PATH — at any step — leaves STATE
unchanged.  Deleting the empty path is a no-op (the root has no key)."
  (cond
    ((null? path) state)
    ((not (alist? state)) state)
    ((null? (cdr path))
     (filter (lambda (e) (not (eq? (car e) (car path)))) state))
    (else
     (let ((entry (assq (car path) state)))
       (if entry
           (map (lambda (e)
                  (if (eq? (car e) (car path))
                      (cons (car path) (state-delete (cdr e) (cdr path)))
                      e))
                state)
           state)))))

(define (deep-merge target incoming)
  "Recursively merge INCOMING into TARGET.  Scalars and non-alist lists in
INCOMING win outright; two alists are merged key-by-key, recursing on
shared keys.  This is `deep-merge-with' with no per-path strategy
overrides, so the two share one algorithm."
  (deep-merge-walk target incoming '() '()))

;; ---------- deep-merge-with: per-path strategy overrides ----------
;;
;; `deep-merge-with target incoming strategies` is `deep-merge` with an
;; alist of (path . strategy) overrides. At each recursion step the
;; current path is matched against the strategies alist; if matched,
;; the strategy decides; otherwise the default alist-merge applies.
;;
;; Strategies:
;;   replace                — incoming wins outright (skip the recursion)
;;   append                 — list-concat target and incoming
;;   (replace-by-key K)     — both are lists of alists; for each incoming
;;                            entry, replace the target entry whose K
;;                            field matches; otherwise append.
;;
;; The default behavior at unmatched paths is identical to `deep-merge`,
;; so this is a strict superset.

(define (deep-merge-with target incoming strategies)
  "Like `deep-merge', but STRATEGIES is an alist of (path . strategy)
overrides consulted at each step.  A strategy may be `replace' (incoming
wins), `append' (list-concat), or (replace-by-key K) (replace list-of-alist
entries matching field K).  Unmatched paths behave exactly like
`deep-merge', making this a strict superset."
  (deep-merge-walk target incoming strategies '()))

(define (deep-merge-walk target incoming strategies path)
  (let ((strat (assoc-ref strategies path)))
    (cond
      ((eq? strat 'replace) incoming)
      ((eq? strat 'append)
       (append (if (list? target) target '())
               (if (list? incoming) incoming (list incoming))))
      ((and (pair? strat) (eq? (car strat) 'replace-by-key))
       (merge-by-key target incoming (cadr strat)))
      ;; default: same as deep-merge, but recurse with strategy table.
      ((not (alist? incoming)) incoming)
      ((not (alist? target))   incoming)
      (else
       (fold (lambda (entry acc)
               (let* ((k (car entry))
                      (v (cdr entry))
                      (existing (state-get acc (list k))))
                 (state-set acc (list k)
                            (deep-merge-walk existing v strategies
                                             (append path (list k))))))
             target
             incoming)))))

(define (merge-by-key target incoming key)
  ;; target and incoming are lists of alists. For each incoming entry,
  ;; replace the target entry with a matching `key` value, or append.
  (fold (lambda (new acc)
          (let ((k-val (assq-ref new key)))
            (if (any (lambda (rec) (equal? (assq-ref rec key) k-val)) acc)
                (map (lambda (rec)
                       (if (equal? (assq-ref rec key) k-val) new rec))
                     acc)
                (append acc (list new)))))
        (if (list? target) target '())
        (if (list? incoming) incoming '())))

;; ---------- op constructors ----------

(define (op:merge alist source)
  "Return an op that deep-merges ALIST into the state.  SOURCE is the
authored form recorded for debugging."
  (make-op 'merge source
           (lambda (state) (deep-merge state alist))))

(define (path->string path)
  (string-join (map (lambda (k) (if (symbol? k) (symbol->string k) (format #f "~a" k)))
                    path)
               "."))

(define (op:set path value source)
  "Return an op that sets PATH to VALUE in the state.  SOURCE is the
authored form recorded for debugging."
  (make-op 'set source
           (lambda (state) (state-set state path value))
           (string-append "set " (path->string path))))

(define (op:append path value source)
  "Return an op that appends VALUE to the list at PATH in the state.
SOURCE is the authored form recorded for debugging."
  (make-op 'append source
           (lambda (state) (state-append state path value))
           (string-append "append " (path->string path))))

(define (op:copy src dst source)
  "Return an op that copies the value at path SRC to path DST.  A missing
SRC (resolving to #f) leaves the state unchanged.  SRC and DST are lists of
symbol keys; SOURCE is the authored form."
  (make-op 'copy source
           (lambda (state)
             (let ((v (state-get state src)))
               (if v (state-set state dst v) state)))
           (string-append "copy " (path->string src) " -> " (path->string dst))))

(define (op:move src dst source)
  "Return an op that moves the value at path SRC to path DST (set DST, then
delete SRC).  A missing SRC leaves the state unchanged.  SRC and DST should
be disjoint paths; SOURCE is the authored form."
  (make-op 'move source
           (lambda (state)
             (let ((v (state-get state src)))
               (if v (state-delete (state-set state dst v) src) state)))
           (string-append "move " (path->string src) " -> " (path->string dst))))

(define (op:delete path source)
  "Return an op that removes the entry at PATH (a list of symbol keys) from
the state, leaving a missing PATH unchanged.  SOURCE is the authored form."
  (make-op 'delete source
           (lambda (state) (state-delete state path))
           (string-append "delete " (path->string path))))

(define (op:when pred body source)
  "Return an op that folds BODY (a list of ops) into the state only when
PRED, a (state -> bool) procedure, holds.  SOURCE is the authored form;
BODY is exposed as the op's children for introspection."
  ;; body is a list of ops; pred is (state -> bool).
  (make-op 'when source
           (lambda (state)
             (if (pred state)
                 (fold (lambda (op s) (apply-op op s)) state body)
                 state))
           #f
           body))

(define (op:case thunk arms source)
  "Return an op that evaluates THUNK against the state and folds in the
op-list of the first matching arm in ARMS.  Each arm is (vals . op-list)
where `vals' is the symbol `else' or a list of literals matched with eqv?.
SOURCE is the authored form."
  ;; arms is a list of (vals . op-list). `vals` is either the symbol 'else
  ;; or a list of literals matched with eqv?. First matching arm wins.
  (make-op 'case source
           (lambda (state)
             (let ((v (thunk state)))
               (let loop ((arms arms))
                 (cond
                   ((null? arms) state)
                   ((let ((head (car (car arms))))
                      (or (eq? head 'else) (memv v head)))
                    (fold (lambda (op s) (apply-op op s)) state (cdr (car arms))))
                   (else (loop (cdr arms)))))))
           #f
           ;; Flatten all arm bodies as children. Loses arm-association
           ;; but exposes the inner ops to introspection tools.
           (concatenate (map cdr arms))))

;; Bundle a list of ops into ONE op whose effect folds them in order, and
;; whose children are those ops — so introspection (tree/explain) descends
;; through it. This is the combinator every target library leans on to make
;; a builder (an `app`, an `aws-rds`, a `fleet`) look like one operation
;; while being a fold of smaller ops underneath. Domain-agnostic, hence here.
(define (compose-ops kind source ops)
  "Bundle OPS into a single op of KIND whose effect folds them in order and
whose children are OPS, so introspection descends through it.  This is the
combinator target libraries use to make a builder look like one operation.
SOURCE is the authored form."
  (make-op kind source
           (lambda (state) (fold (lambda (op s) (apply-op op s)) state ops))
           #f
           ops))

;; Build-time *scope*: bind a dynamic PARAM to VAL while the body's ops are
;; *constructed* (so the value bakes into each op), then bundle them into one
;; composing op of KIND whose label is LABEL-PREFIX followed by VAL. Each body
;; form is `stamp-loc`'d so the most specific authored line wins. This is the
;; combinator behind k8s `with-namespace`, sql `with-schema`, and ledger's
;; `in-year` / `in-currency` / … — same shape, one definition. It is
;; `compose-ops` plus a `parameterize` plus a value-stamped label.
(define-syntax scope-ops
  (syntax-rules ()
    ((_ kind (param val) label-prefix body ...)
     (let* ((v   val)
            (ops (parameterize ((param v))
                   (list (stamp-loc body) ...))))
       (make-op kind (list kind v)
                (lambda (state) (fold apply-op state ops))
                (string-append label-prefix (format #f "~a" v))
                ops)))))

;; Map a body over a keyed table, isolating each element. `table` is an
;; alist `((key . seed) …)`; for each entry we run a FRESH `resolve` of
;; `body` (a list of ops) seeded with that entry's attributes, and stash
;; the resulting sub-state under `(base… key)`. So a list/mapping of seeds
;; becomes a mapping of resolved sub-states — the combinator behind
;; enumerations like the region fleet. `body` is exposed as children so
;; introspection descends through it.
(define (for-each-into base table body)
  "Return an op that maps BODY (a list of ops) over TABLE, an alist of
(key . seed).  For each entry it runs a fresh `resolve' of BODY seeded with
that entry's attributes and stashes the result under (base… key), turning a
table of seeds into a mapping of resolved sub-states.  BODY is exposed as
children for introspection."
  (make-op 'for-each-into
           `(for-each-into ,base ,(map car table))
           (lambda (state)
             (fold (lambda (entry s)
                     (state-set s (append base (list (car entry)))
                                (resolve body (cdr entry))))
                   state table))
           (format #f "for-each-into ~a (~a)"
                   (string-join (map symbol->string base) ".")
                   (length table))
           body))

;; ---------- optional per-file render adapters ----------
;;
;; The resolved state IS the output; the builtin formats (sexp / json /
;; yaml) render it generically. A target library that also wants a domain
;; text view (SQL DDL, ledger-cli text) provides a (state -> writes text)
;; procedure, and the *inventory file* registers it under a name with
;; `renders-with`. The CLI binds `current-renderers` to a collector box
;; around the load and exposes each registration as `hexol render -o NAME`.
;; Outside that (e.g. a bare `(load-inventory-file …)`), the parameter is
;; #f and `renders-with` is a harmless no-op — so the ops contract is
;; unchanged and `op:load` / introspection keep seeing a plain list of ops.

(define current-renderers (make-parameter #f))

(define (renders-with name proc)
  "Register PROC, a (state -> writes text) renderer, under string NAME for
the inventory file currently being loaded.  The CLI exposes it as `hexol
render -o NAME`.  A no-op when no collector is bound."
  (let ((box (current-renderers)))
    (when box (set-car! box (cons (cons name proc) (car box)))))
  *unspecified*)

;; ---------- optional per-file apply adapters (effects) ----------
;;
;; The mirror of `renders-with`, but for *effects* rather than text. Where a
;; renderer is a (state -> writes text) view, an applier is a (state dry? ->
;; performs effects) procedure: it reads its slice of the resolved state and
;; pushes it to the world (a `tofu apply`, a `kubectl apply`). The *inventory*
;; registers each one under a NAME with `applies-with`, and `hexol apply` runs
;; them in *registration order* — the order the `applies-with` calls appear in
;; the file — against a single `resolve`. An explicit ORDER may be passed to
;; override that placement. Selecting a subset (`--only NAME`) is just a filter
;; on the registered set (order preserved); `--dry-run` is threaded through as
;; the applier's second argument so each delegates to its tool's native
;; dry-run. As with `renders-with`, the collector parameter is #f outside
;; `apply`, so `applies-with` is a harmless no-op for render/tree/ops and the
;; ops contract is unchanged.

(define current-appliers (make-parameter #f))

(define* (applies-with name proc #:optional (order #f))
  "Register PROC, a (state dry? -> performs effects) applier, under string
NAME.  Appliers run in registration order under `hexol apply'; pass an
explicit ORDER (a number) only to override that placement.  A no-op when no
collector is bound."
  (let ((box (current-appliers)))
    (when box (set-car! box (cons (list name order proc) (car box)))))
  *unspecified*)

;; ---------- loader ----------

(define (load-inventory-file path)
  "Read every top-level form in the file at PATH, evaluate them in order in
the (hexol surface) module (falling back to (hexol kernel)), and return the
value of the last form, which must be a list of ops.  Earlier forms may be
`define's of helper procedures.  Source positions are attached so ops can
be blamed on the authored line."
  ;; Reads every top-level form in `path`, evaluates them in order, and
  ;; returns the value of the last (which must be a list of ops). Earlier
  ;; forms can be `define`s — useful for declaring method procedures
  ;; that build resources, then calling them inside the inventory.
  (let* ((module (or (resolve-module '(hexol surface) #:ensure #f)
                     (resolve-module '(hexol kernel))))
         (port   (open-input-file path)))
    ;; Attach (filename line column) source-properties to every form we
    ;; read, so the body-taking macros' `stamp-loc` can recover each
    ;; authored form's `syntax-source` and blame ops on the right line.
    (set-port-filename! port path)
    (read-enable 'positions)
    (let loop ((last #f) (seen-any? #f))
      (let ((form (read port)))
        (if (eof-object? form)
            (begin
              (close-port port)
              (unless seen-any?
                (error "empty inventory file:" path))
              (unless (list? last)
                (error "last form must evaluate to a list of ops:" path))
              last)
            (loop (eval form module) #t))))))
