;;; test/construct.scm — unit tests for (hexol construct).
;;; Run: guile -L . test/construct.scm  (part of `make test`)

(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (hexol construct)
             (hexol kernel)
             (hexol surface)
             (hexol lint)
             (srfi srfi-1)
             (ice-9 format))

(define failures 0)
(define-syntax check
  (syntax-rules ()
    ((_ desc expected actual)
     (let ((e expected) (a actual))
       (if (equal? e a)
           (format #t "  ok   ~a~%" desc)
           (begin (set! failures (+ failures 1))
                  (format #t "  FAIL ~a~%       expected: ~s~%       got:      ~s~%" desc e a)))))))

;; ---- defaults, evaluated values, flags, lists, maps ----
(define-construct widget
  #:head name
  #:value
  #:fields ((image #:required) (port #:default 8080) (debug #:flag)
            (tags #:list) (env #:map))
  #:build (list name image port debug tags env))

(format #t "~%construct: scalar / default / flag / list / map~%")
(check "required + default + flag(valueless) + list + map"
       (list "api" "img:1" 8080 #t '("a" "b") '((LOG . "info") (TIER . "web")))
       (widget "api" (image "img:1") (debug) (tags "a" "b") (env (LOG "info") (TIER "web"))))
(check "default kept, flag absent #f, value evaluated, list/map empty"
       (list "min" "i" 3 #f '() '())
       (widget "min" (image "i") (port (+ 1 2))))
(check "flag with explicit value"
       #t (list-ref (widget "x" (image "i") (debug #t)) 3))
(check "string key in #:map coerces to a symbol (file-shaped)"
       `((,(string->symbol "nginx.conf") . "data"))
       (list-ref (widget "x" (image "i") (env ("nginx.conf" "data"))) 5))

;; ---- ,@ / , in a #:map field ----
(define computed-env '((A . "1") ("b.c" . "2")))
(check ",@ splices an evaluated alist into a #:map field, keys coerced"
       `((MODE . "fast") (A . "1") (,(string->symbol "b.c") . "2") (Z . "9"))
       (list-ref (widget "x" (image "i")
                         (env (MODE "fast") ,@computed-env ,(cons 'Z "9"))) 5))
(check ",@ of '() contributes nothing"
       '((MODE . "fast"))
       (list-ref (widget "x" (image "i") (env (MODE "fast") ,@'())) 5))
(check "non-alist ,@ raises naming construct and field"
       #t
       (catch #t
         (lambda () (widget "x" (image "i") (env ,@"nope")) #f)
         (lambda (k . a)
           (and (string-contains (format #f "~a" a) "widget: field (env")
                #t))))

;; ---- coerce ----
(define (double x) (if (number? x) (* 2 x) x))
(define-construct coerced
  #:head name
  #:value
  #:fields ((n #:coerce double #:default 10))
  #:build (list name n))
(format #t "~%construct: coerce~%")
(check "coerce applied to value"   '("a" 8)  (coerced "a" (n 4)))
(check "coerce applied to default" '("a" 20) (coerced "a"))

;; ---- sub-constructs (#:construct, #:repeated) ----
(define-construct rule
  #:head ()
  #:value
  #:fields ((verbs #:list))
  #:build (cons 'rule verbs))
(define-construct policy
  #:head name
  #:value
  #:fields ((rule #:repeated #:construct rule))
  #:build (list name rule))
(format #t "~%construct: sub-constructs~%")
(check "repeated sub-construct collects a list"
       '("p" ((rule "get" "list") (rule "watch")))
       (policy "p" (rule (verbs "get" "list")) (rule (verbs "watch"))))
(check "repeated absent -> empty list" '("p" ()) (policy "p"))

;; ---- multi-positional head ----
(define-construct sized
  #:head (name n)
  #:value
  #:fields ((unit #:default "px"))
  #:build (list name n unit))
(format #t "~%construct: multi-positional head~%")
(check "two positional args + field" '("box" 12 "em") (sized "box" 12 (unit "em")))

;; ---- open schema: unknown keys collected into `extra` ----
(define-construct openrec
  #:head name #:open? #t
  #:value
  #:fields ((kind #:required))
  #:build (list name kind extra))
(format #t "~%construct: open schema~%")
(check "unknown keys collected into extra (scalar + list)"
       '("z" "X" ((foo . "bar") (nums 1 2 3)))
       (openrec "z" (kind "X") (foo "bar") (nums 1 2 3)))

;; ---- schema registry (what `hexol doc` reads) ----
(define-construct documented
  #:head name
  #:doc "a documented construct"
  #:value
  #:fields ((image #:required #:doc "container image") (port #:default 8080)
            (debug #:flag) (tags #:list) (rule #:repeated #:construct rule))
  #:build (list name image port debug tags rule))
(format #t "~%construct: schema registry~%")
(let ((s (car (find-constructs 'documented))))
  (check "registered under its name, head, doc and value? marker"
         '((name) "a documented construct" #t)
         (list (assq-ref s 'head) (assq-ref s 'doc) (assq-ref s 'value?)))
  (check "field names in definition order"
         '(image port debug tags rule)
         (map (lambda (f) (assq-ref f 'name)) (assq-ref s 'fields)))
  (check "required / doc / default / flag / repeated construct recorded"
         '((#t "container image") 8080 flag (construct #t rule))
         (let ((f (lambda (n) (find (lambda (f) (eq? (assq-ref f 'name) n)) (assq-ref s 'fields)))))
           (list (list (assq-ref (f 'image) 'required?) (assq-ref (f 'image) 'doc))
                 (assq-ref (f 'port) 'default)
                 (assq-ref (f 'debug) 'kind)
                 (list (assq-ref (f 'rule) 'kind) (assq-ref (f 'rule) 'repeated?)
                       (assq-ref (f 'rule) 'construct))))))
(check "every construct of this file is registered, in order"
       '(widget coerced rule policy sized openrec documented)
       (map (lambda (s) (assq-ref s 'name)) (construct-schemas)))

;; ---- fold-time fields: get / attr work bare inside a construct ----
;;
;; A construct without #:value returns an op; its field expressions run when
;; that op fires, so they read whatever the fold has written so far.
(define-construct thing
  #:head name
  #:fields ((image #:required) (n #:default 1))
  #:build (op:set '(out) (list name image n) (list 'thing name)))

(format #t "~%construct: fold-time field values~%")
(check "a construct call is an op, not its built value"
       #t (op? (thing "api" (image "i"))))
(check "(get …) in a field reads what an earlier hx-merge wrote"
       '("api" "r.io/api" 3)
       (state-get (resolve (hx-ops
                             (hx-merge (cfg (registry "r.io") (replicas 3)))
                             (thing "api"
                                    (image (str (get '(cfg registry)) "/api"))
                                    (n (get '(cfg replicas)))))
                           '())
                  '(out)))
(check "(attr …) in a field sees the per-row seed inside hx-each"
       '("web" "db")
       (let ((final (resolve (hx-ops
                               (hx-each '((r1 . ((role . "web"))) (r2 . ((role . "db"))))
                                        #:into rows
                                        (thing "x" (image (attr 'role)))))
                             '())))
         (list (cadr (state-get final '(rows r1 out)))
               (cadr (state-get final '(rows r2 out))))))
(check "the head arg still names the op before any fold"
       "thing api" (op-label (thing "api" (image "i"))))
(check "realized children are exposed after one fold"
       '(1 set)
       (let* ((op (thing "api" (image "i")))
              (_  (resolve (list op) '())))
         (list (length (op-realized-children op))
               (op-kind (car (op-realized-children op))))))

(format #t "~%construct: fold-time field errors~%")
(check "a failing field names the construct and the field"
       #t
       (catch #t
         (lambda () (resolve (hx-ops (thing "api" (image (error "boom")))) '()) #f)
         (lambda (key . args)
           (and (string-contains (format #f "~a ~a" key args) "thing: field (image …)")
                #t))))

(format #t "~%construct: lint sees reads made inside a field~%")
(check "a field read before the write it depends on is reported"
       #t
       (let ((warnings (lint-ops (hx-ops
                                   (thing "api" (image (get '(cfg registry))))
                                   (hx-merge (cfg (registry "r.io")))))))
         (and (= (length warnings) 1)
              (string-contains (car warnings) "cfg.registry")
              #t)))

(format #t "~%~a~%" (if (zero? failures) "all construct checks passed"
                        (format #f "~a CONSTRUCT CHECK(S) FAILED" failures)))
(exit (if (zero? failures) 0 1))
