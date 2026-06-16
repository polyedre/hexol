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
;;;   map    : (key (k v) …)      -> a free-form nested alist (#:map field):
;;;                                  keys auto-quoted to symbols, values
;;;                                  evaluated; string keys allowed ("nginx.conf").
;;;   sub    : (key . args)       -> (subname . args) — args handed to another
;;;            #:repeated           define-construct (#:construct subname); a
;;;                                  #:repeated field collects each occurrence
;;;                                  into a list.
;;;
;;; `#:build` is an expression evaluated with the head args and every field
;;; bound as a local (resolved: default-filled, coerced, collected), like a
;;; `define*` body sees its `#:key` args. It may return any value — a plain
;;; alist (a sub-block) or an op (a resource). The library decides.

(define-module (hexol construct)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (define-construct %expand-call construct-flag construct-map-entries))

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
;; `(construct-map-entries (k v) …)` builds a nested alist for a #:map field:
;; keys auto-quote to symbols (or stay strings, e.g. "nginx.conf"), values
;; evaluated; `(block k …)` recurses. The one place a typed constructor admits
;; free-form data, so it deliberately reuses the schema-less rule (explicit
;; `block` for depth).
(define-syntax construct-map-entries
  (syntax-rules (block)
    ((_) '())
    ((_ (block k entry ...) rest ...)
     (cons (cons 'k (construct-map-entries entry ...))
           (construct-map-entries rest ...)))
    ((_ (k v) rest ...)
     (cons (cons (quote k) v) (construct-map-entries rest ...)))))

;; ---------- the define-construct macro ----------
;;
;; Generates `(define-syntax NAME …)` whose transformer is self-contained —
;; consulting only the field schema (spliced in as a literal) and stdlib procs,
;; so no cross-module expand-time dependency. Field kinds and entry → value forms:
;;
;;   (plain)            scalar; one value, evaluated
;;   #:flag             boolean; `(k)` → #t, `(k v)` → v, absent → #f
;;   #:list             `(k a b …)` → (list a b …); a lone `(k)` → '()
;;   #:map              `(k (sub v) …)` → free-form alist via construct-map-entries
;;   #:construct C      `(k . args)` → (C . args); with #:repeated, collect a list
;;   #:default E        value when the field is absent (else #f, or '() for list/map)
;;   #:coerce P         wrap the resolved value in (P …)
;;   #:wire W           (advisory; the builder decides output keys)
;;
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
    (define (kw-get args k default)
      (let ((m (memq k args))) (if m (cadr m) default)))
    (define (kw-syntax kws k default)
      (let loop ((kws kws))
        (syntax-case kws ()
          (() default)
          ((a b . rest)
           (if (eq? (syntax->datum #'a) k) #'b (loop #'rest))))))
    (syntax-case stx ()
      ((_ name kw ...)
       (let* ((open?    (kw-get (syntax->datum #'(kw ...)) #:open? #f))
              (build    (kw-syntax #'(kw ...) #:build #'(error "construct: no #:build")))
              (fields-stx (stx->list (kw-syntax #'(kw ...) #:fields #'())))
              ;; head identifiers kept as original syntax (with marks) so they
              ;; are the *same* bindings #:build references.
              (head-stx (kw-syntax #'(kw ...) #:head #'()))
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
                  (coerce (opt-syntax-after opts #:coerce)))
             ;; field-id is the ORIGINAL name identifier (car parts), marks
             ;; intact, so it is the very binding #:build references — correct
             ;; even when define-construct is itself produced by another macro
             ;; (e.g. SQL's type sugar).
             (list fname (car parts) kind cname rep? req? deflt coerce)))
         (let* ((infos    (map field-info fields-stx))
                (fnames   (map car infos))
                (field-ids (map cadr infos))
                (extra-id (datum->syntax build 'extra))
                ;; descriptors handed to the runtime expander: (name kind rep? req? cname)
                (descs    (map (lambda (i) (list (list-ref i 0) (list-ref i 2)
                                                 (list-ref i 4) (list-ref i 5) (list-ref i 3)))
                               infos))
                ;; impl prologue: default unset fields, then coerce.
                (prologue
                  (append-map
                    (lambda (i)
                      (let ((fid (cadr i)) (deflt (list-ref i 6)) (coerce (list-ref i 7)))
                        (cons #`(#,fid (if (eq? #,fid '%hx-unset) #,deflt #,fid))
                              (if coerce (list #`(#,fid (#,coerce #,fid))) '()))))
                    infos)))
           #`(begin
               (define (#,impl #,@head-ids #,@field-ids #,extra-id)
                 (let* #,prologue #,build))
               (define-syntax name
                 (lambda (s)
                   (%expand-call s '#,(datum->syntax #'name name-sym)
                                   '#,(datum->syntax #'name head)
                                   '#,(datum->syntax #'name descs)
                                   '#,(datum->syntax #'name open?)
                                   '#,(datum->syntax #'name fnames)
                                   #'#,impl))))))))))

;; Runtime expander every generated `name` transformer calls. Splits the call
;; into positional head args + `(key …)` entries, computes each field's value
;; form by kind, checks required/unknown, emits one positional call to `%impl`
;; (which defaults and coerces). Absent fields pass sentinel '%hx-unset.
(define (%expand-call s name head descs open? fnames impl)
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
       (define (field-form desc)
         (let* ((fn (list-ref desc 0)) (kind (list-ref desc 1))
                (rep? (list-ref desc 2)) (cell (assq fn grouped))
                (es (and cell (cdr cell))))
           (cond
             ((not es) unset)
             ((eq? kind 'flag) (let ((a (eargs (car es)))) (if (null? a) #'#t (car a))))
             ((eq? kind 'list) #`(list #,@(eargs (car es))))
             ((eq? kind 'map)  #`(construct-map-entries #,@(eargs (car es))))
             ((eq? kind 'construct)
              (let ((mk (lambda (e) #`(#,(ehead e) #,@(eargs e)))))
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
         (let ((field-forms (map field-form descs))
               (extra-form
                 (if open?
                     #`(list #,@(map (lambda (g)
                                       (let ((a (eargs (cadr g))))
                                         #`(cons '#,(ehead (cadr g))
                                                 #,(if (= (length a) 1) (car a) #`(list #,@a)))))
                                     unknowns))
                     #''())))
           #`(#,impl #,@pos #,@field-forms #,extra-form)))))))

