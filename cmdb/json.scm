;;; cmdb/json.scm — JSON adapter for CMDB state shapes.
;;;
;;; Delegates to guile-json: it renders lists as JSON objects (alists)
;;; and vectors as arrays. Our state holds arrays as plain lists (e.g.
;;; (kubernetes_resources <r1> <r2>)), so we preprocess: any list whose
;;; entries aren't all (symbol . X) becomes a vector first.
;;;
;;; `()` renders as `{}` (empty alist); for an empty array pass `#()`.

(define-module (cmdb json)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:export (sexp->json-string state->json-ready))

(define (object-shape? obj)
  ;; Non-empty list of (symbol . X) with distinct keys. Unique-keys check
  ;; disambiguates from arrays of symbol-headed elements (e.g. a fact list
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
     ;; dotted pair (k . v) -> one-entry object
     (list (cons (car obj) (state->json-ready (cdr obj)))))
    ((and (pair? obj) (not (list? obj)))
     ;; non-symbol-keyed dotted pair -> 2-element array
     (vector (state->json-ready (car obj))
             (state->json-ready (cdr obj))))
    ((list? obj)
     (list->vector (map state->json-ready obj)))
    (else obj)))

;; guile-json doesn't escape ASCII control chars; raw bytes (ANSI, NUL)
;; pass through and make invalid JSON. Post-process to \uXXXX-encode any
;; control byte. They only appear inside string literals here, so a flat
;; byte-scan suffices.
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
