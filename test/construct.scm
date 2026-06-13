;;; test/construct.scm — unit tests for (hexol construct).
;;; Run: guile -L . test/construct.scm  (part of `make test`)

(add-to-load-path (string-append (dirname (current-filename)) "/.."))

(use-modules (hexol construct)
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
(check "string key in #:map (file-shaped)"
       '(("nginx.conf" . "data"))
       (list-ref (widget "x" (image "i") (env ("nginx.conf" "data"))) 5))

;; ---- coerce ----
(define (double x) (if (number? x) (* 2 x) x))
(define-construct coerced
  #:head name
  #:fields ((n #:coerce double #:default 10))
  #:build (list name n))
(format #t "~%construct: coerce~%")
(check "coerce applied to value"   '("a" 8)  (coerced "a" (n 4)))
(check "coerce applied to default" '("a" 20) (coerced "a"))

;; ---- sub-constructs (#:construct, #:repeated) ----
(define-construct rule
  #:head ()
  #:fields ((verbs #:list))
  #:build (cons 'rule verbs))
(define-construct policy
  #:head name
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
  #:fields ((unit #:default "px"))
  #:build (list name n unit))
(format #t "~%construct: multi-positional head~%")
(check "two positional args + field" '("box" 12 "em") (sized "box" 12 (unit "em")))

;; ---- open schema: unknown keys collected into `extra` ----
(define-construct openrec
  #:head name #:open? #t
  #:fields ((kind #:required))
  #:build (list name kind extra))
(format #t "~%construct: open schema~%")
(check "unknown keys collected into extra (scalar + list)"
       '("z" "X" ((foo . "bar") (nums 1 2 3)))
       (openrec "z" (kind "X") (foo "bar") (nums 1 2 3)))

(format #t "~%~a~%" (if (zero? failures) "all construct checks passed"
                        (format #f "~a CONSTRUCT CHECK(S) FAILED" failures)))
(exit (if (zero? failures) 0 1))
