;;; cmdb/server.scm — HTTP front-end for the CMDB.
;;;
;;; Routes:
;;;   GET  /health             -> "ok"
;;;   GET  /state              -> entire materialized state as a sexp
;;;   GET  /state/<dot.path>   -> subtree or leaf at path; 404 if missing
;;;   GET  /facts              -> sexp list of all facts
;;;   POST /facts              -> body is one fact sexp; appended + applied
;;;
;;; Bodies in are application/scheme (s-expressions). Bodies out default
;;; to application/scheme; pass `Accept: application/json` or `?fmt=json`
;;; to get JSON instead. The server is single-threaded; the underlying
;;; CMDB store is not safe for concurrent writes.

(define-module (cmdb server)
  #:use-module (cmdb store)
  #:use-module (cmdb json)
  #:use-module (web server)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (make-handler
            start-server
            path-string->keys))

(define (sexp->bv obj)
  (string->utf8 (call-with-output-string (lambda (p) (write obj p) (newline p)))))

(define (json->bv obj)
  (string->utf8 (string-append (sexp->json-string obj) "\n")))

(define (text-bv s) (string->utf8 s))

;; Picks output format from request:
;;   ?fmt=json query param OR Accept: application/json header  -> 'json
;;   otherwise -> 'sexp
;; Query param wins over Accept so the dot-suffix style is curl-friendly.
(define (uri-query-pairs uri)
  (let ((q (uri-query uri)))
    (if (or (not q) (string=? q ""))
        '()
        (map (lambda (pair)
               (let ((idx (string-index pair #\=)))
                 (if idx
                     (cons (substring pair 0 idx) (substring pair (+ idx 1)))
                     (cons pair ""))))
             (string-split q #\&)))))

(define (request-format request)
  (let* ((uri    (request-uri request))
         (params (uri-query-pairs uri))
         (fmt    (assoc-ref params "fmt"))
         (accept (request-headers request))
         (accept-hdr (assq-ref accept 'accept)))
    (cond
      ((and fmt (string=? fmt "json")) 'json)
      ((and fmt (string=? fmt "sexp")) 'sexp)
      ((and accept-hdr
            (any (lambda (a)
                   ;; guile parses "application/json" into the symbol
                   ;; `application/json`; the entry is a one-element list.
                   (and (pair? a) (eq? (car a) 'application/json)))
                 accept-hdr))
       'json)
      (else 'sexp))))

(define (read-sexp-body request body)
  (let ((s (cond
             ((not body) "")
             ((bytevector? body) (utf8->string body))
             ((string? body) body)
             (else (error "unexpected body type" body)))))
    (call-with-input-string s read)))

(define (response code content-type body-bv)
  (values (build-response
            #:code code
            #:headers `((content-type . (,content-type))))
          body-bv))

(define (sexp-response code obj)
  (response code 'application/scheme (sexp->bv obj)))

(define (json-response code obj)
  (response code 'application/json (json->bv obj)))

(define (data-response request code obj)
  (case (request-format request)
    ((json) (json-response code obj))
    (else   (sexp-response code obj))))

(define (text-response code s)
  (response code 'text/plain (text-bv s)))

(define (path-string->keys s)
  ;; "regions.alpha5.apps.api.image.tag" -> '(regions alpha5 apps api image tag)
  (if (string=? s "")
      '()
      (map string->symbol (string-split s #\.))))

(define (split-path uri-path)
  ;; uri-path is like "/state/regions.alpha5" -> ("state" "regions.alpha5").
  ;; Empty segments are dropped.
  (filter (lambda (s) (not (string=? s "")))
          (string-split uri-path #\/)))

(define (handle-get-state cmdb request keys)
  (let ((v (cmdb-get cmdb keys)))
    (cond
      ((and (null? keys) (null? v))
       (data-response request 200 '()))
      ((not v)
       (text-response 404 (format #f "not found: ~a\n" keys)))
      (else
       (data-response request 200 v)))))

(define (handle-post-fact cmdb request body)
  (let ((fact (read-sexp-body request body)))
    (cmdb-append-fact! cmdb fact)
    (data-response request 200 `((ok . #t) (fact . ,fact)))))

(define (handle-get-facts cmdb request)
  (data-response request 200 (cmdb-facts cmdb)))

(define (make-handler cmdb)
  (lambda (request body)
    (let* ((method (request-method request))
           (uri    (request-uri request))
           (path   (uri-path uri))
           (parts  (split-path path)))
      (match (cons method parts)
        (('GET) (text-response 200 "cmdb\n"))
        (('GET "health") (text-response 200 "ok\n"))
        (('GET "state") (handle-get-state cmdb request '()))
        (('GET "state" rest) (handle-get-state cmdb request (path-string->keys rest)))
        (('GET "facts") (handle-get-facts cmdb request))
        (('POST "facts") (handle-post-fact cmdb request body))
        (_ (text-response 404 (format #f "no route: ~a ~a\n" method path)))))))

(define* (start-server cmdb #:key (port 8080) (addr "127.0.0.1"))
  (format #t "cmdb: listening on http://~a:~a/~%" addr port)
  (run-server (make-handler cmdb) 'http
              `(#:port ,port #:addr ,(inet-pton AF_INET addr))))
