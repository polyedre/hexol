;;; cmdb/json.scm — JSON adapter for CMDB state shapes.
;;;
;;; Delegates to guile-json. guile-json renders Scheme lists as JSON
;;; objects (treating them as alists) and Scheme vectors as JSON arrays.
;;; Our state stores arrays as plain lists (e.g. (kubernetes_resources
;;; <r1> <r2>)), so we preprocess: any list that isn't a list of
;;; (symbol . X) entries gets converted to a vector first.
;;;
;;; Empty list `()` is rendered as `{}` (typical for empty alists in our
;;; state); to force an empty array, pass `#()`.

(define-module (cmdb json)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:export (sexp->json-string state->json-ready))

(define (object-shape? obj)
  ;; An object is a non-empty list whose entries are all (symbol . X)
  ;; with distinct keys. The unique-keys check disambiguates from arrays
  ;; that happen to have symbol-headed elements (e.g. a list of facts
  ;; `((merge ...) (merge ...))` is an array, not an object).
  (and (pair? obj)
       (list? obj)
       (every (lambda (e) (and (pair? e) (symbol? (car e)))) obj)
       (let ((keys (map car obj)))
         (= (length keys) (length (delete-duplicates keys eq?))))))

(define (state->json-ready obj)
  (cond
    ((null? obj) '())                       ; -> {}
    ((object-shape? obj)
     (map (lambda (e) (cons (car e) (state->json-ready (cdr e)))) obj))
    ((and (pair? obj) (not (list? obj)) (symbol? (car obj)))
     ;; standalone dotted pair (k . v) -> one-entry object
     (list (cons (car obj) (state->json-ready (cdr obj)))))
    ((and (pair? obj) (not (list? obj)))
     ;; dotted pair without a symbol key — best-effort 2-element array
     (vector (state->json-ready (car obj))
             (state->json-ready (cdr obj))))
    ((list? obj)
     (list->vector (map state->json-ready obj)))
    (else obj)))

;; guile-json doesn't escape ASCII control characters in strings; raw
;; bytes (ANSI escapes, NULs, etc.) pass through verbatim and produce
;; invalid JSON. We post-process the output to encode any control byte
;; as a \uXXXX sequence. Control bytes only legitimately appear inside
;; string literals in our outputs, so a flat byte-scan is sufficient.
(define (escape-control-chars s)
  (let loop ((chars (string->list s)) (acc '()))
    (cond
      ((null? chars) (string-concatenate (reverse acc)))
      (else
       (let* ((c (car chars))
              (n (char->integer c)))
         (loop (cdr chars)
               (cons (cond
                       ((or (= n #x09) (= n #x0a) (= n #x0d)) (string c))
                       ((< n #x20) (format #f "\\u~4,'0x" n))
                       (else (string c)))
                     acc)))))))

(define (sexp->json-string obj)
  (escape-control-chars (scm->json-string (state->json-ready obj))))
