;;; hexol/diff.scm — a tiny structural differ over state-shaped alists.
;;;
;;; `hexol diff --explain' compares a *rendered* resource (the resolved alist)
;;; against its *live* counterpart (`kubectl get -o json', parsed back into the
;;; same shape) and reports each leaf that differs, as a state path — so the
;;; explain machinery can name the op that set it. Pure data; nothing here
;;; shells out.
;;;
;;; The comparison is one-sided on purpose: it walks the DESIRED side's keys
;;; only. A live object carries everything the API server defaulted or
;;; computed (status, uid, resourceVersion, managedFields…), none of which the
;;; inventory ever set, so "in live, not in desired" is noise, not drift.

(define-module (hexol diff)
  #:use-module ((hexol yaml) #:select (object-shape?))
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (structural-diff json->state))

;; Parse a JSON document into hexol's state shape: guile-json gives string
;; keys and vectors; state uses symbol keys and lists (as the yaml emitter
;; reads them). JSON null stays the symbol `null' — #f would be
;; indistinguishable from "absent" to `path-get'.
(define (json->state text)
  (let loop ((v (json-string->scm text)))
    (cond
      ((vector? v) (map loop (vector->list v)))
      ((and (list? v) (every (lambda (e) (and (pair? e) (string? (car e)))) v))
       (map (lambda (e) (cons (string->symbol (car e)) (loop (cdr e)))) v))
      (else v))))

;; Scalars compare by their printed form, so a rendered 80 matches a live 80
;; and a symbol-valued field its string spelling — the YAML round-trip through
;; kubectl loses that distinction anyway.
(define (same-scalar? a b)
  (or (equal? a b)
      (and (not (pair? a)) (not (pair? b))
           (string=? (format #f "~a" a) (format #f "~a" b)))))

(define (structural-diff desired live . path)
  "Leaf-diff DESIRED against LIVE (both state-shaped alists); return a list of
(PATH LIVE-VALUE DESIRED-VALUE) for every leaf under DESIRED whose live value
differs — LIVE-VALUE is #f when the path is absent live.  Only DESIRED's keys
are walked (see the module comment).  PATH, if given, prefixes every result."
  (let ((path (if (null? path) '() (car path))))
    (cond
      ((and (object-shape? desired) (object-shape? live))
       (append-map (lambda (e)
                     (structural-diff (cdr e) (assq-ref live (car e))
                                      (append path (list (car e)))))
                   desired))
      ;; sequences of equal length compare element-wise (so a container list
      ;; drills to the field); otherwise the whole sequence is the leaf.
      ((and (pair? desired) (list? desired) (list? live)
            (not (object-shape? desired)) (not (object-shape? live))
            (= (length desired) (length live)))
       (append-map (lambda (d l i) (structural-diff d l (append path (list i))))
                   desired live (iota (length desired))))
      ((same-scalar? desired live) '())
      (else (list (list path live desired))))))
