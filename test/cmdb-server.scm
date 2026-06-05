;;; test/cmdb-server.scm — integration tests for the HTTP server.
;;;
;;; Forks a child that runs the server on a high port, exercises the
;;; routes from the parent via Guile's web client, then kills the child.

(add-to-load-path (dirname (dirname (current-filename))))

(use-modules (cmdb store)
             (cmdb server)
             ((web client) #:renamer (lambda (s)
                                       (case s
                                         ((http-post) 'web:http-post)
                                         ((http-get)  'web:http-get)
                                         (else s))))
             (web response)
             (rnrs bytevectors)
             (json)
             (ice-9 format))

(define failures 0)
(define port (+ 19000 (modulo (getpid) 1000)))
(define base-url (format #f "http://127.0.0.1:~a" port))
(define tmp-log
  (string-append "/tmp/cmdb-server-test-" (number->string (getpid)) ".log"))

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

(define (decode-body body)
  (cond ((not body) "")
        ((bytevector? body) (utf8->string body))
        (else body)))

(define (get-status+body url)
  (call-with-values (lambda () (web:http-get url))
    (lambda (r b) (values (response-code r) (decode-body b)))))

(define (get-json url)
  (call-with-values
    (lambda () (web:http-get url
                             #:headers '((accept . ((application/json))))))
    (lambda (r b)
      (values (response-code r)
              (assq-ref (response-headers r) 'content-type)
              (decode-body b)))))

(define (post-sexp url sexp)
  (call-with-values
    (lambda ()
      (web:http-post url
                     #:body (string->utf8
                              (call-with-output-string
                                (lambda (p) (write sexp p))))
                     #:headers '((content-type . (application/scheme)))))
    (lambda (r b) (values (response-code r) (decode-body b)))))

(define (sexp-of s) (call-with-input-string s read))

(define (wait-for-server max-attempts)
  (let loop ((n max-attempts))
    (cond
      ((zero? n) (error "server didn't come up"))
      (else
       (let ((up? (catch #t
                    (lambda ()
                      (call-with-values
                        (lambda () (web:http-get (string-append base-url "/health")))
                        (lambda (r b) (= (response-code r) 200))))
                    (lambda _ #f))))
         (if up?
             #t
             (begin (usleep 100000) (loop (- n 1)))))))))

(when (file-exists? tmp-log) (delete-file tmp-log))

(format #t "~%cmdb/server: forking server on port ~a~%" port)
(define child-pid (primitive-fork))
(cond
  ((zero? child-pid)
   ;; child: run the server
   (let ((c (make-cmdb tmp-log)))
     (start-server c #:port port))
   (exit 0))
  (else
   ;; parent: run tests
   (wait-for-server 50)

   (format #t "~%cmdb/server: GET /health~%")
   (call-with-values (lambda () (get-status+body (string-append base-url "/health")))
     (lambda (code body)
       (check "health 200" 200 code)
       (check "health body" "ok\n" body)))

   (format #t "~%cmdb/server: POST /facts + GET /state~%")
   (call-with-values
     (lambda () (post-sexp (string-append base-url "/facts")
                           '(merge ((regions (alpha5 (attributes (dc . alpha) (geo . eu))))))))
     (lambda (code body)
       (check "post merge (attrs) 200" 200 code)
       (let ((reply (sexp-of body)))
         (check "post reply ok" #t (assq-ref reply 'ok)))))

   (call-with-values
     (lambda () (post-sexp (string-append base-url "/facts")
                           '(merge ((apps (api (image (tag . "v1.0.0"))))))))
     (lambda (code body) (check "post merge (default) 200" 200 code)))

   (call-with-values
     (lambda () (post-sexp (string-append base-url "/facts")
                           '(merge ((regions (alpha5 (apps (api (image (tag . "v2.0.0"))))))))))
     (lambda (code body) (check "post merge (override) 200" 200 code)))

   (call-with-values
     (lambda () (get-status+body
                  (string-append base-url "/state/regions.alpha5.apps.api.image.tag")))
     (lambda (code body)
       (check "get path 200" 200 code)
       (check "get path returns promoted tag" "v2.0.0" (sexp-of body))))

   (call-with-values
     (lambda () (get-status+body
                  (string-append base-url "/state/apps.api.image.tag")))
     (lambda (code body)
       (check "get default tag" "v1.0.0" (sexp-of body))))

   (call-with-values
     (lambda () (get-status+body
                  (string-append base-url "/state/regions.alpha5.attributes")))
     (lambda (code body)
       (check "get region attrs as sexp"
              '((dc . alpha) (geo . eu))
              (sexp-of body))))

   (format #t "~%cmdb/server: 404 on missing path~%")
   (call-with-values
     (lambda () (get-status+body (string-append base-url "/state/nope.nope")))
     (lambda (code body) (check "missing path -> 404" 404 code)))

   (format #t "~%cmdb/server: GET /facts~%")
   (call-with-values
     (lambda () (get-status+body (string-append base-url "/facts")))
     (lambda (code body)
       (check "facts 200" 200 code)
       (check "facts has 3 entries" 3 (length (sexp-of body)))))

   (format #t "~%cmdb/server: json output~%")
   (call-with-values
     (lambda () (get-json (string-append base-url "/state/regions.alpha5.attributes")))
     (lambda (code ctype body)
       (check "json 200" 200 code)
       (check "json content-type" '(application/json)
              (and ctype (list (car ctype))))
       (check "json parses + correct value" "alpha"
              (assoc-ref (json-string->scm body) "dc"))))

   ;; symbol leaf -> JSON string
   (call-with-values
     (lambda () (get-json (string-append base-url "/state/regions.alpha5.attributes.dc")))
     (lambda (code ctype body)
       (check "json scalar (symbol -> string)" "alpha"
              (json-string->scm body))))

   ;; array (list of symbols) -> JSON array of strings
   (post-sexp (string-append base-url "/facts")
              '(merge ((regions (alpha5 (packages a b c))))))
   (call-with-values
     (lambda () (get-json (string-append base-url "/state/regions.alpha5.packages")))
     (lambda (code ctype body)
       (check "json array of symbols" '#("a" "b" "c")
              (json-string->scm body))))

   (call-with-values
     (lambda () (get-json (string-append base-url "/facts")))
     (lambda (code ctype body)
       (let ((v (json-string->scm body)))
         (check "json /facts is array" #t (vector? v))
         (check "json /facts entry count" 4 (vector-length v)))))

   ;; ?fmt=json query param
   (call-with-values
     (lambda () (get-status+body
                  (string-append base-url
                                 "/state/regions.alpha5.attributes.dc?fmt=json")))
     (lambda (code body)
       (check "?fmt=json works without Accept" "alpha" (json-string->scm body))))

   ;; teardown
   (kill child-pid SIGTERM)
   (waitpid child-pid)
   (when (file-exists? tmp-log) (delete-file tmp-log))

   (format #t "~%~a~%"
           (if (zero? failures)
               "all cmdb-server checks passed"
               (format #f "~a cmdb-server failure(s)" failures)))
   (exit (if (zero? failures) 0 1))))
