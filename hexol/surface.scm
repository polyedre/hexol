;;; hexol/surface.scm — author-facing macros.
;;;
;;; The author ops are all `hx-`-prefixed — `hx-ops`, `hx-each`, `hx-merge`,
;;; `hx-when`, `hx-case`, `hx-append` — so they never shadow Guile's own `when`,
;;; `append`, `case`, `load`, or srfi-1's `merge`. A file can `(use-modules
;;; (hexol))` and still reach every builtin unchanged. `hx-ops`, `hx-when`,
;;; and `hx-case` each take body slots that are either a single op or a list
;;; of ops, flattening one level — so a helper procedure that returns a list
;;; of ops drops straight into any of them.
;;;
;;; Surface forms inside (hx-merge ...):
;;;
;;;   (key literal)            -> scalar       (port 22)
;;;   (key literal literal ..) -> list         (servers "a" "b")
;;;   (key (sub ...) ...)      -> nested map   (nginx (workers 4))
;;;   (key ($ expr))           -> computed     (mirror ($ (str "rpm." (attr 'dc))))
;;;   (key ($ e1) ($ e2) ...)  -> computed list
;;;
;;; Unquoted symbols in value position are auto-quoted: (encryption at-rest)
;;; produces `at-rest` as a symbol. The $ marker is required for any value
;;; whose shape could otherwise be parsed as a nested map.
;;;
;;; Inside ($ expr), helpers `(attr key)` and `(get path)` read the current
;;; fold state. They are bound by the op's expansion — the same `$` defers to
;;; fold time in `hx-merge` and `hx-append` alike. `(str …)` concatenates
;;; (coercing symbols/numbers) and `(fmt template …)` fills a format string,
;;; so a computed identifier needs no string-append / symbol->string ceremony.
;;;
;;; An hx-when / hx-case predicate is just an expression evaluated with the
;;; fold state bound, so `attr`/`get` work in it directly:
;;;   (hx-when (attrs (role web)) …)               ; equality shorthand
;;;   (hx-when (semver> (get '(k8s version)) "1.3") …)  ; any expression
;;;   (hx-when (lambda (s) …) …)                    ; an explicit predicate
;;; A predicate that evaluates to a procedure is applied to the state; any
;;; other value decides by its truthiness.

(define-module (hexol surface)
  #:use-module (hexol kernel)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:re-export (resolve state-get state-set state-append state-delete deep-merge
               op? op-kind op-source op-effect apply-op compose-ops for-each-into
               renders-with applies-with)
  #:export (hx-ops hx-each hx-merge hx-when hx-case hx-append
            hx-copy hx-move hx-delete
            $ attr get attrs str fmt
            resource transform-resources annotate-all label-all
            block body
            semver-compare semver> semver< semver=))

;; ---------- attr / get helpers ----------
;;
;; These are top-level procedures so they're in scope wherever
;; (use-modules (hexol surface)) is imported. They read from a parameter
;; bound to the current fold state by the deferred ops (hx-merge / hx-append)
;; and by the hx-when / hx-case predicate/dispatch wrappers.

(define current-state (make-parameter #f))

(define (attr k)
  "Read attribute K (a key under `attributes', i.e. the query) from the
current fold state.  Valid only inside a computed value ($ …) or an
hx-when/hx-case predicate; errors otherwise."
  (let ((s (current-state)))
    (unless s (error "(attr) used outside a computed value or predicate"))
    (state-get s (list 'attributes k))))

(define (get p)
  "Read the value at path P (a list of symbol keys) from the current fold
state.  Valid only inside a computed value ($ …) or an hx-when/hx-case
predicate; errors otherwise."
  (let ((s (current-state)))
    (unless s (error "(get) used outside a computed value or predicate"))
    (state-get s p)))

;; ---------- string building for computed ($ …) values ----------
;;
;; Two ways to build a string out of attributes without the
;; `(string-append … (symbol->string (attr 'x)) …)` ceremony. Both are
;; ordinary procedures, so they work anywhere — most usefully inside a
;; computed value, e.g. ($ (str "k8s-" (attr 'region))).

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
;; Compares dotted numeric versions ("1.2.3"). Shorter is treated as if
;; the missing components were zero ("1.2" < "1.2.1", "1.2" = "1.2.0").
;; Returns -1, 0, or 1 like a standard compare.

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
;; (resource <alist>) returns one op that appends the alist to the
;; (kubernetes_resources) list. The op's source is derived from the
;; resource's kind + metadata.name for introspection.
(define (resource body)
  "Return an op that appends the resource alist BODY to the
(kubernetes_resources) list.  The op's label is derived from the
resource's kind and metadata.name for introspection."
  (let* ((meta (or (assq-ref body 'metadata) '()))
         (kind (assq-ref body 'kind))
         (name (assq-ref meta 'name))
         (op   (op:append '(kubernetes_resources) body `(resource ,kind ,name))))
    ;; Override the generic "append kubernetes_resources" label with the
    ;; resource identity, which is what users actually want to see.
    (relabel op (string-append "resource " kind "/" name))))

;; ---------- cross-cutting resource transforms ----------
;;
;; Walks (kubernetes_resources) — a flat list of resource alists — and
;; applies f to each. Returns an op usable inside (when ...).

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
;; Both bind `current-state` while the thunk runs, so `attr`/`get` work
;; inside an ($ expr) value — the marker means the same thing in hx-merge
;; and hx-append.

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
;; The body-taking ops (hx-ops / hx-when / hx-case) accept each slot as
;; either a single op or a list of ops, flattening one level — so a helper
;; procedure that returns a list of ops drops straight in. (Uses srfi-1
;; concatenate; nothing here is shadowed.)
(define (normalize-ops xs)
  (concatenate (map (lambda (x) (if (op? x) (list x) x)) xs)))

;; ---------- $ marker ----------
;;
;; Used as a literal in merge value position. The marker itself is also
;; a macro so `(use-modules (hexol surface))` has $ in scope.
(define-syntax $
  (syntax-rules ()
    ((_ . _) (error "$ used outside of merge value position"))))

;; ---------- body / block: an HCL-ish alist builder ----------
;;
;; Shared author surface for target libraries that build nested alists
;; (terraform-resource, the ansible `task`, …). A body is a sequence of
;; entries; each entry is either an attribute `(key <expr>)` whose value
;; is ordinary evaluated Scheme, or a nested block `(block key <entry>…)`:
;;
;;   (body (name name) (block net (uuid (ref …))) (port 80))
;;     => ((name . <name>) (net (uuid . "${…}")) (port . 80))
;;
;; `block` is the only marker; everything else is "value is code". `block`
;; standalone errors — it is meaningful only as an entry head.
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
    ;; Nested map: every child is a pair (subkey . subbody).
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
     ;; The predicate is an ordinary expression, evaluated each fold with
     ;; current-state bound — so `attr` and `get` work in it directly, the
     ;; same way the dispatch expr does in hx-case. If it yields a procedure
     ;; (e.g. `attrs`, or an explicit `(lambda (s) …)`), it is applied to the
     ;; state; otherwise its truthiness decides. So all three read alike:
     ;;   (hx-when (attrs (role web)) …)
     ;;   (hx-when (semver> (get '(k8s version)) "1.32") …)
     ;;   (hx-when (lambda (s) …) …)
     ;; Body slots are flattened one level (op or list-of-ops), like hx-ops.
     (op:when (lambda (state)
                (parameterize ((current-state state))
                  (let ((v pred))
                    (if (procedure? v) (v state) v))))
              (normalize-ops (list (stamp-loc body) ...))
              '(when pred body ...)))))

;; %append auto-quotes symbol/literal values, matching the merge surface.
;; A computed value ($ expr) is deferred to fold time (where attr/get work),
;; exactly as in hx-merge.
(define-syntax %append
  (syntax-rules ($)
    ((_ (k ...) ($ expr)) (op:append-dyn '(k ...) (lambda (state) expr) '(append (k ...) ($ expr))))
    ((_ (k ...) val)      (op:append     '(k ...) 'val                  '(append (k ...) val)))
    ((_ k ($ expr))       (op:append-dyn '(k)     (lambda (state) expr) '(append k ($ expr))))
    ((_ k val)            (op:append     '(k)     'val                  '(append k val)))))

;; %copy / %move move a value between paths; %delete removes one. Each path
;; slot accepts a bare symbol (`nginx`) or a segment list (`(nginx workers)`),
;; auto-quoted exactly like %append's path.
(define-syntax %copy
  (syntax-rules ()
    ((_ (s ...) (d ...)) (op:copy '(s ...) '(d ...) '(copy (s ...) (d ...))))
    ((_ (s ...) d)       (op:copy '(s ...) '(d)     '(copy (s ...) d)))
    ((_ s (d ...))       (op:copy '(s)     '(d ...) '(copy s (d ...))))
    ((_ s d)             (op:copy '(s)     '(d)     '(copy s d)))))

(define-syntax %move
  (syntax-rules ()
    ((_ (s ...) (d ...)) (op:move '(s ...) '(d ...) '(move (s ...) (d ...))))
    ((_ (s ...) d)       (op:move '(s ...) '(d)     '(move (s ...) d)))
    ((_ s (d ...))       (op:move '(s)     '(d ...) '(move s (d ...))))
    ((_ s d)             (op:move '(s)     '(d)     '(move s d)))))

(define-syntax %delete
  (syntax-rules ()
    ((_ (k ...)) (op:delete '(k ...) '(delete (k ...))))
    ((_ k)       (op:delete '(k)     '(delete k)))))

;; %case: (case expr arm ...) where each arm is ((v ...) body ...) or
;; (else body ...). The dispatch expr runs with current-state bound, so
;; `attr` and `get` work inside it. Only the first matching arm's ops fold.
;; Arm bodies are flattened one level like hx-ops.
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
;; The author ops are exported under `hx-`-prefixed names so they never
;; collide with Guile's `when`/`append`/`case`/`load` or srfi-1's `merge`.
;; They are thin wrappers over the `%`-prefixed implementations above.

(define-syntax hx-merge  (syntax-rules ($) ((_ . a) (%merge . a))))
(define-syntax hx-when   (syntax-rules ()  ((_ . a) (%when . a))))
(define-syntax hx-case   (syntax-rules ()  ((_ . a) (%case . a))))
(define-syntax hx-append (syntax-rules ()  ((_ . a) (%append . a))))
(define-syntax hx-copy   (syntax-rules ()  ((_ . a) (%copy . a))))
(define-syntax hx-move   (syntax-rules ()  ((_ . a) (%move . a))))
(define-syntax hx-delete (syntax-rules ()  ((_ . a) (%delete . a))))
(define-syntax attrs     (syntax-rules ()  ((_ . a) (%attrs . a))))

;; (hx-ops form ...) -> a flat list of ops. Each body slot is either an op
;; or a list of ops; we flatten one level so a helper procedure that returns
;; a list of ops drops straight in. This is the top-level wrapper for an
;; inventory file (its value is the list of ops the loader resolves) and the
;; building block for any procedure that assembles ops.
(define-syntax hx-ops
  (syntax-rules ()
    ((_ body ...)
     (normalize-ops (list (stamp-loc body) ...)))))

;; (hx-each TABLE #:into PATH body ...) -> a one-element list holding the
;; enumeration op (a list, like `hx-ops`, so it drops into another body or
;; stands alone as a file's final form). A body-splicing
;; surface over the kernel's `for-each-into`: resolve `body` once per row of
;; TABLE (an alist `((key . seed) …)`) seeded with that row's attributes, and
;; stash each result under (PATH… key). TABLE comes first — it is the subject,
;; matching "for each row" — and the sink is labeled `#:into` so it can't be
;; mistaken for the source. PATH is auto-quoted and accepts a bare symbol
;; (`#:into regions`) or a segment list (`#:into (region clusters)`). The body
;; slots splice and stamp exactly like `hx-ops`, so no `(list …)` wrapper and
;; a helper returning a list of ops drops straight in.
(define-syntax hx-each
  (syntax-rules ()
    ((_ table #:into (seg ...) body ...)
     (list (for-each-into '(seg ...) table
                          (normalize-ops (list (stamp-loc body) ...)))))
    ((_ table #:into seg body ...)
     (list (for-each-into '(seg) table
                          (normalize-ops (list (stamp-loc body) ...)))))))
