;;; hexol/surface.scm — author-facing macros.
;;;
;;; Author ops are `hx-`-prefixed (`hx-ops`, `hx-each`, `hx-merge`, `hx-when`,
;;; `hx-case`, `hx-append`) so they never shadow Guile's `when`/`append`/`case`/
;;; `load` or srfi-1's `merge`. `hx-ops`/`hx-when`/`hx-case` body slots take an
;;; op or a list of ops, flattening one level — a helper returning a list of ops
;;; drops straight in.
;;;
;;; Surface forms inside (hx-merge ...):
;;;
;;;   (key literal)            -> scalar       (port 22)
;;;   (key literal literal ..) -> list         (servers "a" "b")
;;;   (key (sub ...) ...)      -> nested map   (nginx (workers 4))
;;;   (key ($ expr))           -> computed     (mirror ($ (str "rpm." (attr 'dc))))
;;;   (key ($ e1) ($ e2) ...)  -> computed list
;;;
;;; Unquoted value symbols auto-quote: (encryption at-rest) yields `at-rest`.
;;; The $ marker is required when a value could otherwise parse as a nested map.
;;;
;;; Inside ($ expr), `(attr key)` and `(get path)` read fold state — same `$`
;;; defers to fold time in `hx-merge` and `hx-append`. They also work bare in
;;; a typed constructor's fields, which the construct engine evaluates at fold
;;; time. `(str …)` concatenates
;;; (coercing symbols/numbers), `(fmt template …)` fills a format string.
;;;
;;; An hx-when/hx-case predicate is an expression evaluated with fold state
;;; bound, so `attr`/`get` work in it:
;;;   (hx-when (attrs (role web)) …)               ; equality shorthand
;;;   (hx-when (semver> (get '(k8s version)) "1.3") …)  ; any expression
;;;   (hx-when (lambda (s) …) …)                    ; an explicit predicate
;;; A procedure value is applied to the state; any other decides by truthiness.

(define-module (hexol surface)
  #:use-module (hexol kernel)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:re-export (resolve state-get state-set state-append state-delete deep-merge
               op? op-kind op-source op-effect apply-op compose-ops for-each-into
               normalize-ops current-state
               renders-with applies-with)
  #:export (hx-ops hx-each hx-merge hx-when hx-case hx-append hx-late
            $ attr get attrs str fmt
            resource transform-resources annotate-all label-all
            block body
            semver-compare semver> semver< semver=))

;; ---------- attr / get helpers ----------
;;
;; Top-level so they're in scope wherever (hexol surface) is imported. They read
;; `current-state' — a kernel parameter bound to the fold state by the deferred
;; ops (hx-merge/hx-append), the hx-when/hx-case predicate/dispatch wrappers,
;; and the construct engine's field forms.

(define (attr k)
  "Read attribute K (a key under `attributes', i.e. the query) from the
current fold state.  Valid wherever the fold binds the state: a computed
value ($ …), an hx-when/hx-case predicate, or a construct field; errors
otherwise."
  (let ((s (current-state)))
    (unless s (error "(attr) used outside a computed value, predicate, or construct field"))
    (note-read! (list 'attributes k))
    (state-get s (list 'attributes k))))

(define (get p)
  "Read the value at path P (a list of symbol keys) from the current fold
state.  Valid wherever the fold binds the state: a computed value ($ …), an
hx-when/hx-case predicate, or a construct field; errors otherwise."
  (let ((s (current-state)))
    (unless s (error "(get) used outside a computed value, predicate, or construct field"))
    (note-read! p)
    (state-get s p)))

;; ---------- string building for computed ($ …) values ----------
;;
;; Build strings from attributes without `(string-append … (symbol->string …))`
;; ceremony. Ordinary procedures, usable anywhere — most useful in a computed
;; value, e.g. ($ (str "k8s-" (attr 'region))).

(define (str . parts)
  "Concatenate PARTS into a string, coercing each non-string part to its
display form (a symbol or number needs no `symbol->string` / `number->string`).
  (str \"k8s-\" 'alpha5)        => \"k8s-alpha5\"
  (str \"node-\" 3)           => \"node-3\""
  (string-concatenate
   (map (lambda (p) (if (string? p) p (format #f "~a" p))) parts)))

(define (fmt template . args)
  "Fill the ~a/~s holes of format string TEMPLATE with ARGS, returning the
string. A thin wrapper over `format`, for template-shaped values:
  (fmt \"https://api.~a.example.com:6443\" (attr 'region))"
  (apply format #f template args))

;; ---------- semver comparison ----------
;;
;; Compares dotted numeric versions ("1.2.3"); missing components count as zero
;; ("1.2" < "1.2.1", "1.2" = "1.2.0"). Returns -1, 0, or 1.

(define (semver-compare a b)
  "Compare dotted numeric version strings A and B, returning -1, 0, or 1.
Missing trailing components count as zero, so \"1.2\" < \"1.2.1\" and
\"1.2\" = \"1.2.0\"."
  (let loop ((as (map string->number (string-split a #\.)))
             (bs (map string->number (string-split b #\.))))
    (cond ((and (null? as) (null? bs)) 0)
          ((null? as) (if (every zero? bs)  0 -1))
          ((null? bs) (if (every zero? as)  0  1))
          ((> (car as) (car bs)) 1)
          ((< (car as) (car bs)) -1)
          (else (loop (cdr as) (cdr bs))))))

(define (semver> a b)
  "Return #t if version string A is strictly greater than B."
  (positive? (semver-compare a b)))
(define (semver< a b)
  "Return #t if version string A is strictly less than B."
  (negative? (semver-compare a b)))
(define (semver= a b)
  "Return #t if version strings A and B are equal (ignoring trailing zeros)."
  (zero?     (semver-compare a b)))

;; ---------- k8s resource registration ----------
;;
;; (resource <alist>) returns one op appending the alist to
;; (kubernetes_resources); source derived from kind + metadata.name.
(define (resource body)
  "Return an op that appends the resource alist BODY to the
(kubernetes_resources) list.  The op's label is derived from the
resource's kind and metadata.name for introspection."
  (let* ((meta (or (assq-ref body 'metadata) '()))
         (kind (assq-ref body 'kind))
         (name (assq-ref meta 'name))
         (op   (op:append '(kubernetes_resources) body `(resource ,kind ,name))))
    ;; Relabel with resource identity instead of the generic append label.
    (relabel op (string-append "resource " kind "/" name))))

;; ---------- cross-cutting resource transforms ----------
;;
;; Maps f over (kubernetes_resources), a flat list of resource alists.
;; Returns an op usable inside (when ...).

(define (transform-resources f)
  "Return an op that maps F over every alist in (kubernetes_resources).
Usable inside (when …) as a cross-cutting transform."
  (make-op 'transform-resources '(transform-resources)
           (lambda (state)
             (let ((rs (or (state-get state '(kubernetes_resources)) '())))
               (state-set state '(kubernetes_resources) (map f rs))))))

(define (annotate-all annotations)
  "Return an op that deep-merges ANNOTATIONS into every resource's
metadata.annotations."
  (relabel (transform-resources
             (lambda (r) (deep-merge r `((metadata (annotations ,@annotations))))))
           "annotate-all"))

(define (label-all labels)
  "Return an op that deep-merges LABELS into every resource's
metadata.labels."
  (relabel (transform-resources
             (lambda (r) (deep-merge r `((metadata (labels ,@labels))))))
           "label-all"))

;; ---------- Deferred constructors (fold-time $ values) ----------
;;
;; Both bind `current-state` while the thunk runs, so `attr`/`get` work inside
;; an ($ expr) value — $ means the same in hx-merge and hx-append.

(define (op:merge-dyn thunk source)
  (make-op 'merge source
           (lambda (state)
             (parameterize ((current-state state))
               (deep-merge state (thunk state))))))

(define (op:append-dyn path thunk source)
  (make-op 'append source
           (lambda (state)
             (parameterize ((current-state state))
               (state-append state path (thunk state))))
           (string-append "append " (path->string path))))

;; ---------- body normalization ----------
;;
;; Body-taking ops (hx-ops/hx-when/hx-case) accept each slot as an op or a list
;; of ops, flattening one level — a helper returning a list of ops drops in.
;; `normalize-ops' itself lives in the kernel (scope-ops/compose-ops need it).

;; ---------- $ marker ----------
;;
;; A literal in merge value position; also a macro so importing (hexol surface)
;; brings $ into scope.
(define-syntax $
  (syntax-rules ()
    ((_ . _) (error "$ used outside of merge value position"))))

;; ---------- body / block: an HCL-ish alist builder ----------
;;
;; Shared surface for target libraries building nested alists (terraform-
;; resource, ansible `task`, …). A body is a sequence of entries; each is an
;; attribute `(key <expr>)` (value is evaluated Scheme) or a nested block
;; `(block key <entry>…)`:
;;
;;   (body (name name) (block net (uuid (ref …))) (port 80))
;;     => ((name . <name>) (net (uuid . "${…}")) (port . 80))
;;
;; `block` is the only marker; standalone it errors — valid only as entry head.
(define-syntax block
  (syntax-rules ()
    ((_ . _) (error "(block …) is only valid as a body entry"))))

(define-syntax body-entry
  (syntax-rules (block)
    ((_ (block key entry ...)) (cons 'key (body entry ...)))
    ((_ (key val))             (cons 'key val))))

(define-syntax body
  (syntax-rules ()
    ((_ entry ...) (list (body-entry entry) ...))))

;; ---------- Internal macros (prefixed) ----------

(define-syntax %merge-entry
  (syntax-rules ($)
    ;; Computed scalar: (key ($ expr))
    ((_ (key ($ expr)))
     (cons 'key expr))
    ;; Computed list: (key ($ e1) ($ e2) ...)
    ((_ (key ($ expr) ...))
     (cons 'key (list expr ...)))
    ;; Nested map: each child a pair (subkey . subbody).
    ((_ (key (subkey . subbody) ...))
     (cons 'key (list (%merge-entry (subkey . subbody)) ...)))
    ;; Scalar literal / symbol
    ((_ (key val))
     (cons 'key 'val))
    ;; List of literals
    ((_ (key val ...))
     (cons 'key (list 'val ...)))))

(define-syntax %merge
  (syntax-rules ()
    ((_ entry ...)
     (op:merge-dyn
       (lambda (state) (list (%merge-entry entry) ...))
       '(merge entry ...)))))

(define-syntax %attrs
  (syntax-rules ()
    ((_ (key val) ...)
     (lambda (state)
       (and (equal? (state-get state (list 'attributes 'key)) 'val) ...)))))

(define-syntax %when
  (syntax-rules ()
    ((_ pred body ...)
     ;; Predicate is an expression, evaluated each fold with current-state bound
     ;; (so `attr`/`get` work, as in hx-case's dispatch). A procedure value
     ;; (e.g. `attrs`, or `(lambda (s) …)`) is applied to the state; else its
     ;; truthiness decides. All three read alike:
     ;;   (hx-when (attrs (role web)) …)
     ;;   (hx-when (semver> (get '(k8s version)) "1.32") …)
     ;;   (hx-when (lambda (s) …) …)
     ;; Body slots flatten one level (op or list-of-ops), like hx-ops.
     (op:when (lambda (state)
                (parameterize ((current-state state))
                  (let ((v pred))
                    (if (procedure? v) (v state) v))))
              (normalize-ops (list (stamp-loc body) ...))
              '(when pred body ...)))))

;; %append auto-quotes symbol/literal values like the merge surface. A computed
;; ($ expr) defers to fold time (where attr/get work), as in hx-merge.
(define-syntax %append
  (syntax-rules ($)
    ((_ (k ...) ($ expr)) (op:append-dyn '(k ...) (lambda (state) expr) '(append (k ...) ($ expr))))
    ((_ (k ...) val)      (op:append     '(k ...) 'val                  '(append (k ...) val)))
    ((_ k ($ expr))       (op:append-dyn '(k)     (lambda (state) expr) '(append k ($ expr))))
    ((_ k val)            (op:append     '(k)     'val                  '(append k val)))))

;; %case: (case expr arm ...), each arm ((v ...) body ...) or (else body ...).
;; Dispatch expr runs with current-state bound, so `attr`/`get` work. Only the
;; first matching arm's ops fold; arm bodies flatten one level like hx-ops.
(define-syntax %case-arm
  (syntax-rules (else)
    ((_ (else body ...))    (cons 'else   (normalize-ops (list (stamp-loc body) ...))))
    ((_ ((v ...) body ...)) (cons '(v ...) (normalize-ops (list (stamp-loc body) ...))))))

(define-syntax %case
  (syntax-rules ()
    ((_ expr arm ...)
     (op:case (lambda (state)
                (parameterize ((current-state state)) expr))
              (list (%case-arm arm) ...)
              '(case expr arm ...)))))

;; ---------- Public macro aliases ----------
;;
;; Author ops exported `hx-`-prefixed to avoid colliding with Guile's
;; `when`/`append`/`case`/`load` or srfi-1's `merge`. Thin wrappers over the
;; `%`-prefixed implementations above.

(define-syntax hx-merge  (syntax-rules ($) ((_ . a) (%merge . a))))
(define-syntax hx-when   (syntax-rules ()  ((_ . a) (%when . a))))
(define-syntax hx-case   (syntax-rules ()  ((_ . a) (%case . a))))
(define-syntax hx-append (syntax-rules ()  ((_ . a) (%append . a))))
(define-syntax attrs     (syntax-rules ()  ((_ . a) (%attrs . a))))

;; (hx-late LABEL body ...) -> ONE op, labeled LABEL, whose body is BUILT and
;; folded at fold time with the state bound — so `get`/`attr` work anywhere in
;; it, including the two places field deferral cannot reach:
;;
;;   • a construct's positional head args, which stay eager because they name
;;     the op before the fold:
;;       (hx-late "vault CR"
;;         (custom-resource (str "vault-" (get '(env))) (api "v1") (kind "Vault")))
;;   • the schema-less `body`/`block` surface (terraform-resource,
;;     terraform-settings/provider, the ansible `task`), which has no per-field
;;     schema to defer:
;;       (hx-late "db"
;;         (terraform-resource "aws_db_instance" "main"
;;           (body (instance_class (get '(db class))))))
;;
;; Body slots splice and stamp like `hx-ops`, and the ops it builds show up
;; under `hexol tree --realize` like a construct's do. LABEL is evaluated where
;; written (it names the op before the fold, as a construct's head args do).
(define-syntax hx-late
  (syntax-rules ()
    ((_ label body ...)
     (op:late 'late '(late label body ...)
              (lambda () (normalize-ops (list (stamp-loc body) ...)))
              label))))

;; (hx-ops form ...) -> a flat list of ops. Each slot is an op or a list of ops,
;; flattened one level. Top-level wrapper for an inventory file (its value is
;; the op list the loader resolves) and building block for op-assembling procs.
(define-syntax hx-ops
  (syntax-rules ()
    ((_ body ...)
     (normalize-ops (list (stamp-loc body) ...)))))

;; (hx-each TABLE #:into PATH body ...) -> a one-element list holding the
;; enumeration op (list-shaped like `hx-ops`, so it nests or stands alone). A
;; body-splicing surface over the kernel's `for-each-into`: resolve `body` once
;; per row of TABLE (alist `((key . seed) …)`), seeded with that row's
;; attributes, stashing each result under (PATH… key). TABLE leads as the
;; subject; the sink is `#:into`-labeled so it can't be mistaken for the source.
;; PATH auto-quotes, taking a bare symbol (`#:into regions`) or segment list
;; (`#:into (region clusters)`). Body slots splice and stamp like `hx-ops`.
(define-syntax hx-each
  (syntax-rules ()
    ((_ table #:into (seg ...) body ...)
     (list (for-each-into '(seg ...) table
                          (normalize-ops (list (stamp-loc body) ...)))))
    ((_ table #:into seg body ...)
     (list (for-each-into '(seg) table
                          (normalize-ops (list (stamp-loc body) ...)))))))
