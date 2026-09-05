;;; hexol/construct.scm — the schema-driven record-body constructor engine.
;;;
;;; `define-construct` underlies every *typed* target-library constructor. It
;;; replaces the `#:`-keyword `define*` surface (and its hand-quoted alist
;;; values) with a record body: a positional head plus a recursive sequence of
;;; `(key value …)` entries. Values are evaluated Scheme (strings quoted, refs
;;; and arithmetic natural) — same rule as the terraform/ansible `block`/`body`
;;; surface — while the *schema* recovers what the keyword surface gave free:
;;; defaults, required fields, coercions, boolean flags, kebab→wire key mapping,
;;; and unknown-key errors suggesting the closest valid key.
;;;
;;; Since the schema names each field's kind, a typed constructor distinguishes
;;; nested block from scalar with NO syntactic marker — dropping `block`:
;;;
;;;   (deployment "api"
;;;     (image "ghcr.io/acme/api:1.4")        ; scalar field, evaluated
;;;     (replicas (if prod? 3 1))             ; just Scheme
;;;     (env (LOG_LEVEL "info") (TIER "web")) ; free-form map block
;;;     (resources "100m-500m/128Mi"))        ; #:coerce parses the string
;;;
;;; (Schema-LESS escapes — terraform-resource, task, custom-resource `spec` —
;;; have no per-field schema, so keep an explicit nesting marker; that surface
;;; is `body`/`block` in (hexol surface), unchanged.)
;;;
;;; Grammar of one entry `(key . args)`, dispatched on the field's schema kind:
;;;   scalar : (key v)            -> v               (evaluated)
;;;            (key)              -> #t              (only for a #:flag field)
;;;   list   : (key a b …)        -> (list a b …)    (#:list field; also (key (x)))
;;;            (key a ,@xs b)     -> (append (list a) xs (list b))  — `,@e`
;;;                                  splices a runtime list into a #:list field,
;;;                                  so a computed list of entries needs no
;;;                                  raw-alist escape: (env ,@extra-env (FOO "1"))
;;;   map    : (key (k v) …)      -> a free-form nested alist (#:map field):
;;;                                  keys auto-quoted to symbols (a string key
;;;                                  such as "nginx.conf" is coerced with
;;;                                  string->symbol), values evaluated.
;;;            (key (k v) ,@e ,p)   -> `,@e` splices an evaluated alist and `,p`
;;;                                  one evaluated (key . value) pair, as in a
;;;                                  #:list field — so a computed map (a
;;;                                  ConfigMap's data, per-app labels) needs no
;;;                                  raw-alist escape.
;;;   sub    : (key . args)       -> (subname . args) — args handed to another
;;;            #:repeated           define-construct (#:construct subname); a
;;;                                  #:repeated field collects each occurrence
;;;                                  into a list.
;;;
;;; `#:build` is an expression evaluated with the head args and every field
;;; bound as a local (resolved: default-filled, coerced, collected), like a
;;; `define*` body sees its `#:key` args. It may return any value — a plain
;;; alist (a sub-block) or an op (a resource). The library decides.
;;;
;;; WHEN fields evaluate. A construct call does NOT run its `#:build` where it
;;; is written: it returns an op, and the field expressions (plus `#:default`
;;; and `#:coerce`) run when that op fires, with `current-state` bound. So the
;;; surface's `get`/`attr` work bare in any field —
;;;
;;;   (deployment "api" (image (str (get '(cfg registry)) "/api"))
;;;                     (replicas (get '(cfg replicas))))
;;;
;;; — reading whatever the merges before it in the fold have written. The
;;; positional HEAD args stay eager: they name the thing, and the op's label
;;; ("deployment api") has to exist before the fold.
;;;
;;; A `#:value` construct is the exception: it returns data for an enclosing
;;; construct to consume (a sql column, a Gateway listener), so it evaluates
;;; where it is written — which, inside a deferred field, is already fold time.

(define-module (hexol construct)
  #:use-module (hexol kernel)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (define-construct %expand-call construct-flag construct-map-entries
            construct-map-key construct-map-pair construct-map-splice
            construct-op construct-label construct-field construct-value
            register-construct! construct-schemas find-constructs))

;; ---------- schema registry ----------
;;
;; Every `define-construct` records its schema here at definition time (one
;; `register-construct!` call spliced into the expansion, so a construct's
;; call semantics are untouched). `hexol doc` reads it. A schema is an alist:
;;   ((name . SYM) (module . (hexol k8s)) (head . (name …)) (doc . "…"|#f)
;;    (value? . BOOL) (fields . (FIELD …)))
;; and each FIELD an alist: ((name . SYM) (kind . plain|flag|list|map|construct)
;;   (required? . BOOL) (repeated? . BOOL) (construct . SYM|#f)
;;   (default . DATUM|#f)   ; the #:default expression as written, or #f
;;   (doc . "…"|#f))
;; Keyed by name only loosely — the same name can live in two modules (sql's
;; `references`, k8s's `rule`), so `find-constructs` returns every match.
(define *constructs* '())

(define (register-construct! schema)
  (set! *constructs*
        (cons schema (filter (lambda (s)
                               (not (and (equal? (assq-ref s 'name) (assq-ref schema 'name))
                                         (equal? (assq-ref s 'module) (assq-ref schema 'module)))))
                             *constructs*))))

;; All registered schemas, in definition order.
(define (construct-schemas) (reverse *constructs*))

;; Every schema named NAME (a symbol), in definition order.
(define (find-constructs name)
  (filter (lambda (s) (eq? (assq-ref s 'name) name)) (construct-schemas)))

;; Sentinel a valueless #:flag field carries: `(unique)` means `(unique #t)`.
;; Exposed so generated code can reference it.
(define construct-flag #t)

;; ---------- expand-time helpers ----------
;;
;; Top level evaluates in order, so these are in scope for the `define-construct`
;; transformer below, which calls them during expansion. They work on raw
;; S-expression *data* — the macro hands stripped datums, splices results as syntax.

(define (field-name f)        (if (pair? f) (car f) f))
(define (field-opts f)        (if (pair? f) (cdr f) '()))
(define (field-flag? f k)     (memq k (field-opts f)))
(define (field-opt f k)       (let ((m (memq k (field-opts f)))) (and m (cadr m))))

;; Levenshtein distance, for "unknown key X — did you mean Y?".
(define (edit-distance a b)
  (let* ((la (string-length a)) (lb (string-length b))
         (prev (list->vector (iota (+ lb 1)))))
    (let loop ((i 0) (prev prev))
      (if (= i la)
          (vector-ref prev lb)
          (let ((cur (make-vector (+ lb 1) 0)))
            (vector-set! cur 0 (+ i 1))
            (let jloop ((j 0))
              (if (= j lb)
                  (loop (+ i 1) cur)
                  (let ((cost (if (char=? (string-ref a i) (string-ref b j)) 0 1)))
                    (vector-set! cur (+ j 1)
                      (min (+ (vector-ref cur j) 1)
                           (+ (vector-ref prev (+ j 1)) 1)
                           (+ (vector-ref prev j) cost)))
                    (jloop (+ j 1))))))))))

(define (nearest key candidates)
  (let ((ks (symbol->string key)))
    (fold (lambda (c best)
            (let ((d (edit-distance ks (symbol->string c))))
              (if (or (not best) (< d (cdr best))) (cons c d) best)))
          #f candidates)))

;; ---------- free-form map block reader ----------
;;
;; `(construct-map-entries CTX (k v) …)` builds a nested alist for a #:map
;; field: keys auto-quote to symbols, values evaluated; `(block k …)` recurses.
;; Map keys are ALWAYS symbols — a string key ("nginx.conf", "requests.cpu") is
;; coerced with string->symbol, since the emitters key on symbols.
;;
;; Like a #:list field, a map field also takes computed entries:
;;   ,@e   splices an evaluated alist of (key . value) pairs
;;   ,e    inserts one evaluated (key . value) pair
;; so `(data (MODE "fast") ,@computed)` needs no raw-alist escape. CTX is a
;; string naming the construct and field, used in error messages.
(define (construct-map-key ctx k)
  (cond ((symbol? k) k)
        ((string? k) (string->symbol k))
        (else (error (format #f "~a: map key must be a symbol or string, got ~s"
                             ctx k)))))

(define (construct-map-pair ctx x)
  (if (pair? x)
      (cons (construct-map-key ctx (car x)) (cdr x))
      (error (format #f "~a: ,expr in a map field must be a (key . value) pair, got ~s"
                     ctx x))))

(define (construct-map-splice ctx x)
  (cond ((null? x) '())
        ((and (list? x) (every pair? x)) (map (lambda (e) (construct-map-pair ctx e)) x))
        (else (error (format #f "~a: ,@expr in a map field must be an alist of (key . value) pairs, got ~s"
                             ctx x)))))

(define-syntax construct-map-entries
  (syntax-rules (block unquote unquote-splicing)
    ((_ ctx) '())
    ((_ ctx (unquote-splicing e) rest ...)
     (append (construct-map-splice ctx e) (construct-map-entries ctx rest ...)))
    ((_ ctx (unquote e) rest ...)
     (cons (construct-map-pair ctx e) (construct-map-entries ctx rest ...)))
    ((_ ctx (block k entry ...) rest ...)
     (cons (cons (construct-map-key ctx 'k) (construct-map-entries ctx entry ...))
           (construct-map-entries ctx rest ...)))
    ((_ ctx (k v) rest ...)
     (cons (cons (construct-map-key ctx 'k) v) (construct-map-entries ctx rest ...)))))

;; ---------- the define-construct macro ----------
;;
;; Generates `(define-syntax NAME …)` whose transformer is self-contained —
;; consulting only the field schema (spliced in as a literal) and stdlib procs,
;; so no cross-module expand-time dependency. Field kinds and entry → value forms:
;;
;;   (plain)            scalar; one value, evaluated
;;   #:flag             boolean; `(k)` → #t, `(k v)` → v, absent → #f
;;   #:list             `(k a b …)` → (list a b …); a lone `(k)` → '();
;;                      `,@e` in arg position splices a runtime list
;;   #:map              `(k (sub v) …)` → free-form alist via construct-map-entries;
;;                      `,@e` splices an evaluated alist, `,p` one (key . value)
;;   #:construct C      `(k . args)` → (C . args); with #:repeated, collect a list
;;   #:default E        value when the field is absent (else #f, or '() for list/map)
;;   #:coerce P         wrap the resolved value in (P …)
;;   #:wire W           (advisory; the builder decides output keys)
;;   #:doc "…"          one-line description, shown by `hexol doc`
;;
;; `#:doc "…"` at the construct level documents the construct itself.
;; `#:value` (a bare marker) says #:build returns a VALUE for an enclosing
;; construct to consume — a column alist, a Gateway listener — rather than an
;; op. A value construct is evaluated where it is written; every other
;; construct is deferred to fold time (see %expand-call).
;; #:head is one symbol or a list of positional params; #:open? #t passes
;; unknown keys through as evaluated `(k v)`/`(k a …)` attributes into the
;; `extra` local (an alist); #:build is the result expression with head params,
;; every field, and `extra` bound.

(define (stx->list s)
  (syntax-case s ()
    (() '())
    ((a . b) (cons #'a (stx->list #'b)))))

;; Syntax following value-keyword K in an opts syntax list (or #f).
(define (opt-syntax-after opts-stx k)
  (let loop ((o opts-stx))
    (cond ((null? o) #f)
          ((eq? (syntax->datum (car o)) k) (cadr o))
          (else (loop (cdr o))))))

(define-syntax define-construct
  (lambda (stx)
    ;; Bare marker keywords: they stand alone, so they are stripped before the
    ;; rest of the option list is read as key/value pairs.
    (define markers '(#:value))
    (define (kw-get args k default)
      (let ((m (memq k args))) (if m (cadr m) default)))
    ;; KWS is a LIST of syntax objects, markers already removed: strict pairs.
    (define (kw-syntax kws k default)
      (let loop ((kws kws))
        (cond ((or (null? kws) (null? (cdr kws))) default)
              ((eq? (syntax->datum (car kws)) k) (cadr kws))
              (else (loop (cddr kws))))))
    (syntax-case stx ()
      ((_ name kw ...)
       (let* ((all-kws  (stx->list #'(kw ...)))
              (value?   (and (memq #:value (map syntax->datum all-kws)) #t))
              (kws      (filter (lambda (s) (not (memq (syntax->datum s) markers)))
                                all-kws))
              (kw-data  (map syntax->datum kws))
              (open?    (kw-get kw-data #:open? #f))
              (build    (kw-syntax kws #:build #'(error "construct: no #:build")))
              (fields-stx (stx->list (kw-syntax kws #:fields #'())))
              (doc      (kw-get kw-data #:doc #f))
              ;; head identifiers kept as original syntax (with marks) so they
              ;; are the *same* bindings #:build references.
              (head-stx (kw-syntax kws #:head #'()))
              (head-ids (syntax-case head-stx ()
                          ((a ...) (stx->list head-stx))
                          (single  (list head-stx))))
              (head     (map syntax->datum head-ids))
              (name-sym (syntax->datum #'name))
              (impl     (datum->syntax #'name (symbol-append '% name-sym '-impl))))
         ;; Per field: derive name, kind, repeated?, required?, construct name
         ;; (datum), and default/coerce *syntax* (kept as syntax so they evaluate
         ;; in this module's lexical scope — `current-k8s-namespace`,
         ;; `normalize-resources`, …). Kinds: flag list map construct plain.
         (define (field-info fstx)
           (let* ((parts (if (identifier? fstx) (list fstx) (stx->list fstx)))
                  (fname (syntax->datum (car parts)))
                  (opts  (cdr parts))
                  (od    (map syntax->datum opts))
                  (has?  (lambda (k) (and (memq k od) #t)))
                  (kind  (cond ((has? #:flag) 'flag) ((has? #:list) 'list)
                               ((has? #:map) 'map) ((has? #:construct) 'construct)
                               (else 'plain)))
                  (cname (and (eq? kind 'construct)
                              (syntax->datum (opt-syntax-after opts #:construct))))
                  (rep?  (has? #:repeated))
                  (req?  (has? #:required))
                  (deflt (or (opt-syntax-after opts #:default)
                             (case kind
                               ((flag) #'#f) ((list map) #''())
                               ((construct) (if rep? #''() #'#f))
                               (else #'#f))))
                  (coerce (opt-syntax-after opts #:coerce))
                  (fdoc   (and (has? #:doc) (syntax->datum (opt-syntax-after opts #:doc))))
                  (schema `((name . ,fname) (kind . ,kind) (required? . ,req?)
                            (repeated? . ,rep?) (construct . ,cname)
                            (default . ,(and (has? #:default)
                                             (syntax->datum (opt-syntax-after opts #:default))))
                            (doc . ,fdoc))))
             ;; field-id is the ORIGINAL name identifier (car parts), marks
             ;; intact, so it is the very binding #:build references — correct
             ;; even when define-construct is itself produced by another macro
             ;; (e.g. SQL's type sugar).
             (list fname (car parts) kind cname rep? req? deflt coerce schema)))
         (let* ((infos    (map field-info fields-stx))
                (fnames   (map car infos))
                (field-ids (map cadr infos))
                (extra-id (datum->syntax build 'extra))
                ;; descriptors handed to the runtime expander: (name kind rep? req? cname)
                (descs    (map (lambda (i) (list (list-ref i 0) (list-ref i 2)
                                                 (list-ref i 4) (list-ref i 5) (list-ref i 3)))
                               infos))
                ;; impl prologue: default unset fields, then coerce.
                ;; A deferred construct's prologue runs mid-fold like its
                ;; fields do, so a failing #:default or #:coerce is named the
                ;; same way. A value construct runs where it is written, where
                ;; Guile already blames the right line.
                (blame-in
                  (lambda (fname form)
                    (if value?
                        form
                        #`(construct-field '#,(datum->syntax #'name name-sym)
                                           '#,(datum->syntax #'name fname)
                                           (lambda () #,form)))))
                (prologue
                  (append-map
                    (lambda (i)
                      (let ((fname (car i)) (fid (cadr i))
                            (deflt (list-ref i 6)) (coerce (list-ref i 7)))
                        (cons #`(#,fid (if (eq? #,fid '%hx-unset)
                                           #,(blame-in fname deflt)
                                           #,fid))
                              (if coerce
                                  (list #`(#,fid #,(blame-in fname #`(#,coerce #,fid))))
                                  '()))))
                    infos))
                (schema   `((name . ,name-sym) (head . ,head) (doc . ,doc)
                            (value? . ,value?)
                            (fields . ,(map (lambda (i) (list-ref i 8)) infos)))))
           #`(begin
               (register-construct!
                 (cons (cons 'module (module-name (current-module)))
                       '#,(datum->syntax #'name schema)))
               (define (#,impl #,@head-ids #,@field-ids #,extra-id)
                 (let* #,prologue #,build))
               (define-syntax name
                 (lambda (s)
                   (%expand-call s '#,(datum->syntax #'name name-sym)
                                   '#,(datum->syntax #'name head)
                                   '#,(datum->syntax #'name descs)
                                   '#,(datum->syntax #'name open?)
                                   '#,(datum->syntax #'name fnames)
                                   #'#,impl
                                   '#,(datum->syntax #'name value?)))))))))))

;; ---------- fold-time construct ops ----------
;;
;; A deferred construct call expands into `construct-op`: the authored form is
;; the op's source (so its content hash is per-call-site), the label is the
;; construct name plus its head args (computed at load, before any fold), and
;; the effect runs THUNK — the `%…-impl` call, i.e. defaults, coercions and
;; every field expression — with `current-state` bound, then folds whatever it
;; returned (one op or a list of ops).

(define (construct-label name args)
  "The op label for a construct call: NAME plus its head ARGS, e.g.
\"deployment api\".  Head args are evaluated where the call is written, so
the label exists before any fold."
  (string-join (cons name (map (lambda (a) (format #f "~a" a)) args)) " "))

(define (construct-op label source thunk)
  "Return an op that runs THUNK at fold time with `current-state' bound and
folds the op (or list of ops) it returns.  A thin naming of the kernel's
`op:late'."
  (op:late 'construct source thunk label))

;; Wraps one field expression so a failure names the construct and the field.
;; Pre-unwind (a throw handler, not a catch) so the original stack survives for
;; --backtrace; `apply-op' adds the FILE:LINE of the authored call on the way
;; out, exactly as it does for any other fold-time error.
(define (construct-field name field thunk)
  "Evaluate THUNK, re-throwing any error prefixed with \"NAME: field (FIELD …)\"."
  (with-throw-handler #t
    thunk
    (lambda (key . args)
      (match args
        ((subr (? string? msg) margs . rest)
         (apply throw key subr (string-append "~a: " msg)
                (cons (format #f "~a: field (~a …)" name field) (or margs '()))
                rest))
        (_ #f)))))

;; A `#:construct` sub-field expects DATA back, so the sub-construct has to be
;; a `#:value` one. Unmarked, it returns an op instead, which would silently
;; embed `#<op …>` in the rendered state — name it here.
(define (construct-value name field v)
  "Return V, erroring if it is an op: a #:construct sub-field consumes a value."
  (if (op? v)
      (error (format #f "~a: (~a …) expects a #:value construct, got ~a — mark the sub-construct #:value"
                     name field (short-value v)))
      v))

;; Runtime expander every generated `name` transformer calls. Splits the call
;; into positional head args + `(key …)` entries, computes each field's value
;; form by kind, checks required/unknown, emits one positional call to `%impl`
;; (which defaults and coerces). Absent fields pass sentinel '%hx-unset.
(define* (%expand-call s name head descs open? fnames impl #:optional (value? #f))
  (syntax-case s ()
    ((_ . rest)
     (let* ((forms   (stx->list #'rest))
            (arity   (length head))
            (pos     (list-head forms arity))
            (entries (list-tail forms arity)))
       (define (ehead e) (car (stx->list e)))
       (define (ekey e)  (syntax->datum (ehead e)))
       (define (eargs e) (cdr (stx->list e)))
       (define grouped
         (fold-right (lambda (e acc)
                       (let ((k (ekey e)) (cell #f))
                         (set! cell (assq (ekey e) acc))
                         (if cell (begin (set-cdr! cell (cons e (cdr cell))) acc)
                             (cons (list k e) acc))))
                     '() entries))
       (define unset #''%hx-unset)
       ;; Name the construct and field if this expression fails mid-fold. Only
       ;; for deferred constructs: a value construct's fields run at load, where
       ;; Guile already blames the right line.
       (define (blame fn form)
         (if value?
             form
             #`(construct-field '#,(datum->syntax impl name)
                                '#,(datum->syntax impl fn)
                                (lambda () #,form))))
       (define (field-form desc)
         (let* ((fn (list-ref desc 0)) (kind (list-ref desc 1))
                (rep? (list-ref desc 2)) (cell (assq fn grouped))
                (es (and cell (cdr cell))))
           (cond
             ((not es) unset)
             ((eq? kind 'flag) (let ((a (eargs (car es)))) (if (null? a) #'#t (car a))))
             ((eq? kind 'list)
              ;; each arg is one element, except `,@e` (unquote-splicing) which
              ;; splices a runtime list — so a #:list field takes both literal
              ;; entries and a computed list. `(append)` keeps a lone `(k)` => '().
              #`(append #,@(map (lambda (a)
                                  (syntax-case a (unquote-splicing)
                                    ((unquote-splicing e) #'e)
                                    (_ #`(list #,a))))
                                (eargs (car es)))))
             ((eq? kind 'map)
              #`(construct-map-entries
                  #,(datum->syntax s (format #f "~a: field (~a …)" name fn))
                  #,@(eargs (car es))))
             ((eq? kind 'construct)
              (let ((mk (lambda (e)
                          #`(construct-value '#,(datum->syntax impl name)
                                             '#,(datum->syntax impl fn)
                                             (#,(ehead e) #,@(eargs e))))))
                (if rep? #`(list #,@(map mk es)) (mk (car es)))))
             (else (let ((a (eargs (car es)))) (if (null? a) #'#t (car a)))))))
       ;; required
       (for-each (lambda (d)
                   (when (and (list-ref d 3) (not (assq (car d) grouped)))
                     (error (format #f "~a: missing required field (~a …)" name (car d)))))
                 descs)
       ;; unknown keys
       (let ((unknowns (filter (lambda (g) (not (memq (car g) fnames))) grouped)))
         (when (and (not open?) (pair? unknowns))
           (let* ((k (caar unknowns)) (near (nearest k fnames)))
             (error (format #f "~a: unknown field (~a …)~a" name k
                            (if near (format #f " — did you mean (~a …)?" (car near)) "")))))
         (let ((field-forms (map (lambda (d) (blame (car d) (field-form d))) descs))
               (extra-form
                 (if open?
                     #`(list #,@(map (lambda (g)
                                       (let ((a (eargs (cadr g))))
                                         #`(cons '#,(ehead (cadr g))
                                                 #,(if (= (length a) 1) (car a) #`(list #,@a)))))
                                     unknowns))
                     #''())))
           (if value?
               ;; A value construct evaluates where it is written.
               #`(#,impl #,@pos #,@field-forms #,extra-form)
               ;; Everything else becomes an op: head args eagerly (they make
               ;; the label), fields inside the fold-time thunk.
               ;; `impl' is an identifier, so it is a valid datum->syntax
               ;; context (the whole call `s' is a list, and would not wrap).
               (let ((pos-ids (map (lambda (i)
                                     (datum->syntax impl (string->symbol
                                                           (format #f "%hx-pos~a" i))))
                                   (iota (length pos)))))
                 #`(let #,(map (lambda (id p) #`(#,id #,p)) pos-ids pos)
                     (construct-op
                       (construct-label #,(symbol->string name) (list #,@pos-ids))
                       '#,(datum->syntax impl (syntax->datum s))
                       (lambda ()
                         (#,impl #,@pos-ids #,@field-forms #,extra-form))))))))))))

