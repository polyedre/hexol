;;; hexol/kernel.scm — the engine.
;;;
;;; State is a nested alist with `attributes` at the root holding the query.
;;; An op is a record (kind, source, effect) where effect : state -> state.
;;; Resolution is a left fold of apply-op over ops, seeded with the query.
;;;
;;; Kernel only — surface macros (`merge`, `when`, `attrs`) live elsewhere and
;;; expand to `op:merge`, `op:when`, etc.

(define-module (hexol kernel)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:export (;; ops
            make-op op? op-kind op-source op-effect op-label op-children op-loc
            op-realized-children set-op-realized-children!
            current-author-loc stamp-loc relabel
            current-state
            op-content-hash op-short-hash fnv1a-64
            apply-op resolve normalize-ops compose-ops scope-ops for-each-into
            short-value
            op:merge op:set op:append op:when op:case op:late
            ;; state helpers
            state-get state-set state-append state-delete deep-merge
            path->string
            ;; tracing (explain support)
            current-trace resolve-with-trace path-get
            ;; read/write access log (lint support)
            current-access note-read! resolve-with-access
            ;; per-op fold timing (tree -v support)
            current-timings resolve-with-timings
            ;; loader (exposed so other modules can override path resolution)
            load-inventory-file
            ;; registration collectors (the shape renderers/appliers/actions share)
            make-collector collect! collect-from
            ;; optional per-file render adapters
            current-renderers renders-with
            make-renderer renderer? renderer-name renderer-proc
            ;; optional per-file apply adapters (effects)
            current-appliers applies-with
            make-applier applier? applier-name applier-proc
            ;; optional per-file CLI verbs (actions)
            current-actions defines-action
            make-action action? action-name action-synopsis action-proc))

;; ---------- op record ----------

(define-record-type <op>
  (%make-op kind source effect label children loc realized)
  op?
  (kind   op-kind)
  (source op-source)
  (effect op-effect)
  ;; Optional one-line label for debug/listing. #f falls back to the kind.
  ;; Set by ops with meaningful identity ((load "path"), (resource
  ;; "Deployment/api")); content-shaped ops leave it #f since source describes
  ;; them better.
  (label    op-label)
  ;; Optional nested op records. Ops that fold sub-ops (when, case, compose
  ;; helpers) put them here so introspection descends past the closure
  ;; boundary. Empty for leaf ops.
  (children op-children)
  ;; Optional (file . line) of the authored form responsible — even when the
  ;; op is built deep in a library helper ((public-app ...) -> several resource
  ;; ops, all blamed on the public-app call). #f if unknown. From
  ;; current-author-loc.
  (loc      op-loc)
  ;; A one-element box holding the ops this op's effect actually produced and
  ;; folded, filled in when it fires. A deferred construct only knows its
  ;; children once it runs, and `hexol tree' shows them after a trial fold.
  ;; Deliberately NOT `children': that field feeds op-content-hash, and an
  ;; op's address must not change just because it has been folded once.
  (realized op-realized))

;; One-line printer. Without it an op prints its whole source form and child
;; tree — an error mentioning a top-level op could dump hundreds of kilobytes.
(set-record-type-printer!
 <op>
 (lambda (op port)
   (format port "#<op ~a~a~a>"
           (op-kind op)
           (if (op-label op) (format #f " ~s" (op-label op)) "")
           (let ((loc (op-loc op)))
             (if loc (format #f " ~a:~a" (car loc) (cdr loc)) "")))))

;; A value rendered short enough to sit inside a one-line error message.
(define* (short-value x #:optional (limit 60))
  "Return X written as a string, truncated to LIMIT characters with an
ellipsis.  Used by error messages so a big structure can't flood stderr."
  (let ((s (format #f "~s" x)))
    (if (> (string-length s) limit)
        (string-append (substring s 0 limit) "…")
        s)))

;; The fold state visible to author-facing readers (`get`/`attr` in (hexol
;; surface)). Bound by every op that evaluates author expressions at fold time
;; — the deferred merge/append values, hx-when/hx-case predicates, and the
;; construct engine's field forms. Lives here, not in the surface, because
;; (hexol construct) and extension-authored `make-op` effects must bind it too.
(define current-state (make-parameter #f))

;; (file . line) of the authored form currently evaluating, bound by the
;; body-taking macros (inventory/when/case/with-namespace). make-op snapshots
;; it, so every op — including ones built by library functions called from that
;; form — inherits the line the author wrote; inner forms shadow outer.
(define current-author-loc (make-parameter #f))

(define* (make-op kind source effect #:optional (label #f) (children '()))
  "Construct an op of KIND whose EFFECT is a (state -> state) procedure.
SOURCE is the authored form for debugging, LABEL an optional one-line
description (#f falls back to KIND), and CHILDREN the nested ops for
introspection.  The op's source location is snapshotted from
`current-author-loc'."
  (%make-op kind source effect label children (current-author-loc) (list '())))

(define (op-realized-children op)
  "The ops OP's effect produced the last time it fired, or '() if it has not
fired (or produces none).  Unlike `op-children' this is discovered, not
declared, so it is excluded from `op-content-hash'."
  (car (op-realized op)))

(define (set-op-realized-children! op ops)
  "Record OPS as the ops OP's effect produced while firing."
  (set-car! (op-realized op) ops))

;; Stamps a domain identity ("resource Deployment/api", "tx Rent") onto an op
;; built by a generic constructor (op:append/op:merge) that otherwise carries a
;; bland label. Unlike make-op, keeps the original op-loc rather than
;; re-snapshotting current-author-loc, so it is safe to call any time.
(define (relabel op label)
  "Return OP with its LABEL replaced, preserving kind, source, effect,
children, and source location."
  ;; A fresh realized box: the copy is its own op, and sharing the box would
  ;; make one of them report ops the other produced.
  (%make-op (op-kind op) (op-source op) (op-effect op)
            label (op-children op) (op-loc op) (list (op-realized-children op))))

;; (stamp-loc form) evaluates form with current-author-loc bound to form's own
;; source location, so ops built while it runs are blamed on the authored line.
;; The body-taking macros wrap each sub-form in this. No source info (REPL,
;; macro-gen) -> evaluated unchanged. syntax-source lines are 0-based; stored
;; 1-based to match editors.
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
;; Stable content-derived hash per op — the addressable identity `hexol tree`
;; prints and `hexol show <hash>` resolves. Merkle hash: folds in kind, source
;; form, label, and children's hashes, so editing an op changes its own and its
;; ancestors' hashes (like a git tree) but not siblings'. Effect (opaque
;; closure) and location are excluded — the hash names what an op DOES, not
;; where it was written, so moving code doesn't churn hashes.
;;
;; Identical sibling subtrees share a hash; that is honest, and `show` reports
;; the ambiguity rather than guessing. FNV-1a/64 (no crypto/deps needed for
;; addressing); swap for a gcrypt digest if collision resistance is needed.

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
;; When bound to a mutable box, collects every apply-op call's (op .
;; after-state) tuple in *fire order* — nested ops appear before their compose/
;; when/case wrapper. Wrappers don't change state independently of children, so
;; explain tools typically filter the trace to leaves (empty children).

(define current-trace (make-parameter #f))

;; When bound to a hash table, accumulates each apply-op's elapsed real-time
;; keyed by op identity (eq?). A compose op's time is *inclusive* of its subtree
;; (folds children through apply-op). Unbound -> zero timing overhead.
(define current-timings (make-parameter #f))

;; Nested-fold frames, innermost first: (prefix . outer-state). for-each-into
;; pushes one per table entry while its body resolves, so the trace and the
;; access log see the body's states re-embedded at their outer path
;; ((regions alpha5 …)) and its read paths prefixed — a nested fold's deltas
;; are attributed where the author addresses them, not to a bare sub-state.
(define current-fold-frames (make-parameter '()))

(define (embed-state s)
  (fold (lambda (frame s) (state-set (cdr frame) (car frame) s))
        s (current-fold-frames)))

(define (full-path path)
  (append (append-map car (reverse (current-fold-frames))) path))

;; When bound to a box, collects every apply-op call's (op reads after-state)
;; entry in fire order — like the trace, plus the state paths the effect read
;; via note-read! (surface `get`/`attr`). current-reads is the per-effect box
;; apply-op binds so reads land on the innermost op firing.
(define current-access (make-parameter #f))
(define current-reads  (make-parameter #f))

(define (note-read! path)
  "Record PATH as read by the op currently firing, when an access log is
being collected (`resolve-with-access').  A no-op otherwise."
  (let ((box (current-reads)))
    (when box (set-car! box (cons (full-path path) (car box))))))

;; Re-raise anything THUNK throws with "FILE:LINE: " prepended to its message,
;; so an error from inside an inventory form names the form that caused it —
;; Guile's own frames for `eval'd code carry no file/line. Pre-unwind (a throw
;; handler, not a catch) so the original stack is still live for --backtrace.
(define %location-annotated? (make-fluid #f))

(define (%with-location path line thunk)
  (let ((annotated? #f))
    (with-throw-handler #t
      thunk
      (lambda (key . args)
        ;; Nested %with-location layers each see the same throw; only the
        ;; innermost may annotate, else the message grows one FILE:LINE per
        ;; enclosing op.
        (unless (or annotated? (fluid-ref %location-annotated?))
          (set! annotated? #t)
          (fluid-set! %location-annotated? #t)
          (match args
            ;; Standard (scm-error) shape: (subr message message-args . rest).
            ((subr (? string? msg) margs . rest)
             (apply throw key subr (string-append "~a: " msg)
                    (cons (format #f "~a:~a" path
                                  (if (procedure? line) (line) (or line '?)))
                          (or margs '()))
                    rest))
            (_ #f)))))))

(define (apply-op op state)
  "Apply OP's effect to STATE and return the new state.  When
`current-trace' is bound to a box, records the (op . after-state) pair; when
`current-access' is bound to a box, records (op reads after-state); when
`current-timings' is bound to a hash table, accumulates OP's elapsed
real-time (inclusive of children) keyed by op identity."
  (unless (op? op)
    (error (format #f "expected an op, got ~a — did you forget to splice a list of ops?"
                   (short-value op))))
  (let* ((timings   (current-timings))
         (start     (and timings (get-internal-real-time)))
         (log       (current-access))
         (reads     (and log (list '())))
         (loc       (op-loc op))
         (fire      (lambda ()
                      (if reads
                          (parameterize ((current-reads reads)) ((op-effect op) state))
                          ((op-effect op) state))))
         ;; Blame resolve-time failures on the authored line of the op that
         ;; was firing — the fold is many closures deep by then, and Guile's
         ;; own frames name none of the inventory.
         (new-state (if loc
                        (%with-location (car loc) (cdr loc) fire)
                        (fire))))
    (when timings
      (hashq-set! timings op
                  (+ (- (get-internal-real-time) start)
                     (or (hashq-ref timings op) 0))))
    (let ((box (current-trace)))
      (when box
        (set-car! box (cons (cons op (embed-state new-state)) (car box)))))
    (when log
      (set-car! log (cons (list op (reverse (car reads)) (embed-state new-state))
                          (car log))))
    new-state))

(define (resolve ops attributes)
  "Fold OPS left-to-right over a seed state holding ATTRIBUTES (the query)
under the `attributes' root key, returning the final resolved state."
  (fold (lambda (op state) (apply-op op state))
        `((attributes . ,attributes))
        ops))

;; Returns two values: final state and the fire-order trace.
(define (resolve-with-trace ops attributes)
  "Like `resolve', but return two values: the final state and the trace as
a list of (op . after-state) pairs in fire order."
  (let ((box (list '())))
    (let ((result (parameterize ((current-trace box))
                    (resolve ops attributes))))
      (values result (reverse (car box))))))

(define (resolve-with-access ops attributes)
  "Like `resolve', but return two values: the final state and the access log
as a list of (op reads after-state) entries in fire order, READS being the
paths the op's effect read via `note-read!'."
  (let ((box (list '())))
    (let ((result (parameterize ((current-access box))
                    (resolve ops attributes))))
      (values result (reverse (car box))))))

(define (resolve-with-timings ops attributes table)
  "Like `resolve', but record each op's fold time into TABLE (a hash table
keyed by op identity, via hashq), accumulating across calls.  Times are
internal real-time units and inclusive of each op's children.  Returns the
final resolved state."
  (parameterize ((current-timings table))
    (resolve ops attributes)))

;; Walk a nested state by a path of symbols (alist keys) and integers (list
;; indices); #f if any step is missing. List fields are plain lists, so
;; (... rules 0 host) reads the first rule's host with no special-casing.
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
     ;; not an alist where one was expected — overwrite the subtree.
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
shared keys."
  (cond
    ((not (alist? incoming)) incoming)
    ((not (alist? target))   incoming)
    (else
     (fold (lambda (entry acc)
             (let* ((k (car entry))
                    (v (cdr entry))
                    (existing (state-get acc (list k))))
               (state-set acc (list k) (deep-merge existing v))))
           target
           incoming))))

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

(define (op:when pred body source)
  "Return an op that folds BODY (a list of ops) into the state only when
PRED, a (state -> bool) procedure, holds.  SOURCE is the authored form;
BODY is exposed as the op's children for introspection."
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
  ;; arms: (vals . op-list); vals is 'else or a literal list matched eqv?.
  ;; First matching arm wins.
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
           ;; Flatten arm bodies as children — loses arm-association but
           ;; exposes inner ops to introspection.
           (concatenate (map cdr arms))))

;; Everything that has to be BUILT at fold time rather than at load time goes
;; through here: the construct engine's deferred fields, and the author-facing
;; `hx-late'. THUNK runs when the op fires, with the fold state bound (so
;; `get'/`attr' work in whatever it evaluates) and this op's own authored line
;; restored (so ops it builds deep inside the fold are still blamed on it);
;; whatever it returns — one op or a list of ops — is then folded.
;; One op fires once per `for-each-into' row, rebuilding its ops each time, so
;; realizations ACCUMULATE — otherwise only one row's ops would be addressable
;; by `show'/`explain'. Deduplicated by content hash: rows that produce the same
;; op contribute it once, and a row that produces a different one (a name read
;; from the row's seed) adds it.
(define (merge-realized have new)
  (let loop ((xs new) (seen (map op-content-hash have)) (acc '()))
    (if (null? xs)
        (append have (reverse acc))
        (let ((h (op-content-hash (car xs))))
          (if (member h seen string=?)
              (loop (cdr xs) seen acc)
              (loop (cdr xs) (cons h seen) (cons (car xs) acc)))))))

(define* (op:late kind source thunk #:optional (label #f))
  "Return an op of KIND that runs THUNK when it fires, with `current-state'
and `current-author-loc' bound, then folds the op (or list of ops) THUNK
returned.  Those ops are recorded as the op's realized children so
introspection can descend after a fold, accumulating across fires (one op
fires once per `for-each-into' row) and deduplicated by content hash."
  (letrec ((op (make-op kind source
                        (lambda (state)
                          (parameterize ((current-state state)
                                         (current-author-loc (op-loc op)))
                            (let ((ops (let ((r (thunk)))
                                         (normalize-ops (if (op? r) (list r) r)))))
                              (set-op-realized-children!
                                op (merge-realized (op-realized-children op) ops))
                              (fold apply-op state ops))))
                        label)))
    op))

;; Bundle ops into ONE op whose effect folds them in order and whose children
;; are those ops, so introspection descends through it. The combinator every
;; target library uses to make a builder (app, aws-rds, fleet) look like one
;; operation. Domain-agnostic, hence here.
(define (normalize-ops xs)
  "Flatten a body list one level: each element of XS is an op or a list of ops
(including the empty list, so a conditional arm may contribute nothing)."
  (concatenate
   (map (lambda (x)
          (cond
            ((op? x) (list x))
            ;; A flat list of ops splices; anything else (a nested list, a
            ;; stray value) would only fail later, deep in the fold, with an
            ;; unreadable struct error — name it here instead.
            ((and (list? x) (every op? x)) x)
            (else
             (error (format #f "expected an op, got ~a — did you forget to splice a list of ops?~a"
                            (short-value x) (nearby-loc x))))))
        xs)))

;; Best-effort " (in FILE:LINE)" suffix for an error about X: if X is (or
;; contains) an op, blame that op's authored location.
(define (nearby-loc x)
  (let* ((op  (let first-op ((x x))
                (cond ((op? x) x)
                      ((pair? x) (or (first-op (car x)) (first-op (cdr x))))
                      (else #f))))
         (loc (and op (op-loc op))))
    (if loc (format #f " (in ~a:~a)" (car loc) (cdr loc)) "")))

(define (compose-ops kind source ops*)
  "Bundle OPS into a single op of KIND whose effect folds them in order and
whose children are OPS, so introspection descends through it.  This is the
combinator target libraries use to make a builder look like one operation.
SOURCE is the authored form.

It binds NO parameters: OPS are already built by the time it sees them, and
their effects fire later still.  A macro that wants a library parameter
(`current-k8s-namespace', `current-sql-schema') in scope for what its body
builds AND folds wants `scope-ops', not a `parameterize' around a
`compose-ops'."
  (let ((ops (normalize-ops ops*)))
    (make-op kind source
             (lambda (state) (fold (lambda (op s) (apply-op op s)) state ops))
             #f
             ops)))

;; Scope: bind PARAM to VAL while the body's ops are *constructed* AND again
;; while they *fold*, then bundle them into a composing op of KIND labeled
;; LABEL-PREFIX+VAL. Each body form is stamp-loc'd, and each body slot is an op
;; or a list of ops (normalize-ops flattens one level, like hx-ops).
;;
;; Both bindings matter. Build time is what bakes the value into whatever the
;; body computes eagerly (sql's `table` renders "public.users" then and there).
;; Fold time is what a *deferred* construct field needs: `(namespace #:default
;; (current-k8s-namespace))` is evaluated when the construct's op fires, long
;; after the scope form returned, so the parameter has to still be bound.
;;
;; The combinator behind k8s with-namespace, sql with-schema, ledger
;; in-year/in-currency — i.e. compose-ops + parameterize + value-stamped label.
(define-syntax scope-ops
  (syntax-rules ()
    ((_ kind (param val) label-prefix body ...)
     (let* ((v   val)
            (ops (parameterize ((param v))
                   (normalize-ops (list (stamp-loc body) ...)))))
       (make-op kind (list kind v)
                (lambda (state)
                  (parameterize ((param v)) (fold apply-op state ops)))
                (string-append label-prefix (format #f "~a" v))
                ops)))))

;; Map a body over a keyed table, isolating each element. table is ((key .
;; seed) …); each entry runs a FRESH resolve of body seeded with that entry's
;; attributes, stashed under (base… key). A mapping of seeds becomes a mapping
;; of resolved sub-states — the combinator behind enumerations like the region
;; fleet. body is exposed as children.
(define (for-each-into base table body*)
  "Return an op that maps BODY (a list of ops) over TABLE, an alist of
(key . seed).  For each entry it runs a fresh `resolve' of BODY seeded with
that entry's attributes and stashes the result under (base… key), turning a
table of seeds into a mapping of resolved sub-states.  BODY is exposed as
children for introspection."
  (let ((body (normalize-ops body*)))
   (make-op 'for-each-into
           `(for-each-into ,base ,(map car table))
           (lambda (state)
             (fold (lambda (entry s)
                     (let ((prefix (append base (list (car entry)))))
                       (state-set s prefix
                                  (parameterize ((current-fold-frames
                                                  (cons (cons prefix s)
                                                        (current-fold-frames))))
                                    (resolve body (cdr entry))))))
                   state table))
           (format #f "for-each-into ~a (~a)"
                   (string-join (map symbol->string base) ".")
                   (length table))
           body)))

;; ---------- registration collectors ----------
;;
;; The three optional per-file registries below (renderers, appliers, actions)
;; share ONE shape, named once so each is an instance. A *collector* is a
;; parameter, either #f (inert default — registration forms vanish when nothing
;; collects) or bound to a box into which registrations accumulate in reverse.
;; collect! pushes (no-op when #f); collect-from binds a fresh box around a
;; thunk and returns two values (result, entries in registration order).
;; renders-with/applies-with/defines-action each collect! onto their own
;; collector; the CLI reads each back with one collect-from.

(define (make-collector)
  "Return a fresh collector: a parameter holding #f (inert) until bound to a
box by `collect-from'.  Each per-file registry is one instance."
  (make-parameter #f))

(define (collect! collector entry)
  "Push ENTRY onto COLLECTOR's bound box, or do nothing when COLLECTOR is #f
(unbound).  Returns unspecified, so a registration form has no value."
  (let ((box (collector)))
    (when box (set-car! box (cons entry (car box)))))
  *unspecified*)

(define (collect-from collector thunk)
  "Call THUNK with a fresh box bound to COLLECTOR, returning two values:
THUNK's result and the list of entries `collect!'d during it, in registration
order."
  (let ((box (list '())))
    (let ((result (parameterize ((collector box)) (thunk))))
      (values result (reverse (car box))))))

;; What each collect! stores: a named record, not a positional tuple, so the
;; consumer reads named fields. A renderer carries a (state -> text) proc; an
;; applier a (state mode -> effects) proc; an action a (state args -> effects)
;; proc plus a one-line SYNOPSIS for --help.
(define-record-type <renderer>
  (make-renderer name proc)
  renderer?
  (name renderer-name)
  (proc renderer-proc))

(define-record-type <applier>
  (make-applier name proc)
  applier?
  (name applier-name)
  (proc applier-proc))

(define-record-type <action>
  (make-action name synopsis proc)
  action?
  (name     action-name)
  (synopsis action-synopsis)
  (proc     action-proc))

;; ---------- optional per-file render adapters ----------
;;
;; The resolved state IS the output; builtin formats (sexp/json/yaml) render it
;; generically. A library wanting a domain text view (SQL DDL, ledger-cli)
;; provides a (state -> writes text) proc, which the inventory registers by name
;; with renders-with; the CLI binds current-renderers around the load and
;; exposes each as `hexol render -o NAME`. Outside that the parameter is #f and
;; renders-with is a no-op, so the ops contract is unchanged.

(define current-renderers (make-collector))

(define (renders-with name proc)
  "Register PROC, a (state -> writes text) renderer, under string NAME for
the inventory file currently being loaded.  The CLI exposes it as `hexol
render -o NAME`.  A no-op when no collector is bound."
  (collect! current-renderers (make-renderer name proc)))

;; ---------- optional per-file apply adapters (effects) ----------
;;
;; The mirror of renders-with, but for *effects*. An applier is a (state mode ->
;; performs effects) proc: it reads its slice of resolved state and pushes it to
;; the world (tofu apply, kubectl apply). The inventory registers each by NAME
;; with applies-with; `hexol apply` runs them in *registration order* against a
;; single resolve. --only NAME filters the set (order preserved). MODE is the
;; applier's second arg: `apply` (push), `plan` (`--dry-run`: the tool's native
;; dry-run), or `diff` (`hexol diff`: report drift by returning `drift`). The
;; parameter is #f outside apply/diff, so applies-with is a no-op elsewhere.

(define current-appliers (make-collector))

(define (applies-with name proc)
  "Register PROC, a (state mode -> performs effects) applier, under string
NAME.  Appliers run under `hexol apply' in the order registered.  A no-op when
no collector is bound."
  (collect! current-appliers (make-applier name proc)))

;; ---------- optional per-file CLI verbs (actions) ----------
;;
;; The third collector. An *action* is a standalone CLI verb the inventory
;; contributes (hexol destroy, hexol diff). The CLI tries built-in verbs first
;; (so an inventory can't shadow render/secret); only on no match does it load
;; the inventory collecting these and look for a custom verb.
;;
;; An action is a (state args -> performs effects) proc: STATE is resolved once
;; by the CLI, ARGS the post-verb args with -i/-q stripped, so the action owns
;; its own flags (--dry-run is the action's to interpret). SYNOPSIS is the
;; one-line `hexol --help' usage. The parameter is #f outside action-discovery,
;; so defines-action is a no-op elsewhere.

(define current-actions (make-collector))

(define* (defines-action name proc #:optional (synopsis #f))
  "Register PROC, a (state args -> performs effects) action, as the CLI verb
NAME, with optional one-line SYNOPSIS for `hexol --help'.  Built-in verbs take
precedence over inventory actions.  A no-op when no collector is bound."
  (collect! current-actions (make-action name synopsis proc)))

;; ---------- loader ----------

(define (%source-line form)
  "1-based source line of FORM as read, or #f.  Source properties count
lines from 0; editors count from 1."
  (and (pair? form)
       (let ((l (assq-ref (source-properties form) 'line)))
         (and l (+ l 1)))))

(define (load-inventory-file path)
  "Read every top-level form in the file at PATH, evaluate them in order in
the (hexol surface) module (falling back to (hexol kernel)), and return the
value of the last form, which must be a list of ops.  Earlier forms may be
`define's of helper procedures.  Source positions are attached so ops can
be blamed on the authored line, and errors are re-raised naming FILE:LINE."
  (let* ((module (or (resolve-module '(hexol surface) #:ensure #f)
                     (resolve-module '(hexol kernel))))
         (port   (open-input-file path)))
    ;; Attach source-properties to every form read, so stamp-loc can recover
    ;; each authored form's syntax-source and blame ops on the right line.
    (set-port-filename! port path)
    (read-enable 'positions)
    (let loop ((last #f) (seen-any? #f))
      ;; LINE as a thunk: read the position at failure time, after the
      ;; reader has skipped whitespace onto the offending form.
      (let ((form (%with-location path (lambda () (+ 1 (port-line port)))
                                  (lambda () (read port)))))
        (if (eof-object? form)
            (begin
              (close-port port)
              (unless seen-any?
                (error "empty inventory file:" path))
              (unless (list? last)
                (error (format #f "~a: last form must evaluate to a list of ops, got ~a"
                               path (short-value last))))
              last)
            (loop (%with-location path (%source-line form)
                                  (lambda () (eval form module)))
                  #t))))))
