;;; test/k8s-res.scm — unit tests for the (hexol k8s) `res` parser.
;;; Run: guile -L . test/k8s-res.scm   (or `make test`)
;;;
;;; `res` parses the compact resources spec
;;;   "<cpu-req>-<cpu-lim>/<mem-req>-<mem-lim>"
;;; into a k8s `resources` alist. Conventions under test:
;;;   *          omit that bound entirely
;;;   single mem value   => request == limit (memory clamps by default)
;;;   single cpu value   => request only, NO limit (cpu is left unbounded)
;;;   missing mem side   => treated as "*" (no memory at all)

(add-to-load-path (dirname (dirname (current-filename))))

(use-modules (hexol k8s)
             (ice-9 format))

(define failures 0)

(define-syntax check
  (syntax-rules ()
    ((_ desc expected actual)
     (let ((e expected) (a actual))
       (if (equal? e a)
           (format #t "  ok   ~a~%" desc)
           (begin
             (set! failures (+ failures 1))
             (format #t "  FAIL ~a~%       expected: ~s~%       got:      ~s~%"
                     desc e a)))))))

(format #t "~%k8s: res — both bounds on both axes~%")
(check "cpu+mem, req+lim each"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (cpu . "500m") (memory . "256Mi")))
       (res "100m-500m/128Mi-256Mi"))

(format #t "~%k8s: res — memory single value clamps (request == limit)~%")
(check "cpu req+lim, mem single -> mem limit mirrors request"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (cpu . "500m") (memory . "128Mi")))
       (res "100m-500m/128Mi"))
(check "cpu req only, mem single"
       '((requests (cpu . "200m") (memory . "256Mi"))
         (limits   (memory . "256Mi")))
       (res "200m/256Mi"))

(format #t "~%k8s: res — single cpu value is a request with NO limit~%")
(check "cpu single -> request only, no cpu limit; mem clamps"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (memory . "128Mi")))
       (res "100m/128Mi"))

(format #t "~%k8s: res — `*` omits a bound~%")
(check "cpu limit omitted with *"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (memory . "256Mi")))
       (res "100m-*/128Mi-256Mi"))
(check "cpu request omitted, only cpu limit"
       '((requests (memory . "128Mi"))
         (limits   (cpu . "500m") (memory . "128Mi")))
       (res "*-500m/128Mi"))
(check "no cpu at all (*/...) -> memory only"
       '((requests (memory . "256Mi"))
         (limits   (memory . "256Mi")))
       (res "*/256Mi"))
(check "cpu only, memory starred -> requests cpu, no limits"
       '((requests (cpu . "100m")))
       (res "100m/*"))
(check "everything starred -> empty resources"
       '()
       (res "*/*"))

(format #t "~%k8s: res — missing memory side defaults to none~%")
(check "no slash -> cpu request only, no memory"
       '((requests (cpu . "100m")))
       (res "100m"))
(check "no slash, cpu req+lim, no memory"
       '((requests (cpu . "100m")) (limits (cpu . "500m")))
       (res "100m-500m"))

(format #t "~%k8s: res — empty token behaves like `*`~%")
(check "empty cpu limit (trailing -) omits cpu limit"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (memory . "128Mi")))
       (res "100m-/128Mi"))

(format #t "~%~a~%"
        (if (zero? failures)
            "all checks passed"
            (format #f "~a failure(s)" failures)))
(exit (if (zero? failures) 0 1))
