;;; hexol/lint.scm — ordering lint over one resolve.
;;;
;;; docs/model.md: a computed ($ …) value placed before the writes it depends
;;; on silently reads a stale value, and "mitigation belongs in a lint pass".
;;; This is that pass. It folds the inventory once under the kernel's access
;;; log (`resolve-with-access'): every op firing yields the paths its effect
;;; read (surface `get`/`attr`) and, by diffing states, the leaf paths it
;;; wrote. A read of P at step i whose last write (to P, a parent, or a child
;;; of P) lands at a later step j is the stale read. Reads by hx-when/hx-case
;;; predicates count too — a gate on a not-yet-written path is the same bug.

(define-module (hexol lint)
  #:use-module (hexol kernel)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (lint-ops))

(define (alist? x) (and (list? x) (every pair? x)))

;; Leaf paths whose value differs between state nodes A and B, under PATH.
;; Alists recurse key-by-key; anything else is compared whole.
(define (changed-paths a b path)
  (cond
    ((equal? a b) '())
    ((and (alist? a) (alist? b) (pair? a) (pair? b))
     (let ((keys (delete-duplicates (append (map car a) (map car b)) eq?)))
       (append-map (lambda (k)
                     (changed-paths (assq-ref a k) (assq-ref b k)
                                    (append path (list k))))
                   keys)))
    (else (list path))))

;; A write to W touches a read of P when either is a prefix of the other:
;; reading (nginx) sees a later (nginx workers) write; reading (nginx workers)
;; sees a later (nginx) overwrite.
(define (prefix? a b)
  (or (null? a) (and (pair? b) (equal? (car a) (car b)) (prefix? (cdr a) (cdr b)))))
(define (touches? w p) (or (prefix? w p) (prefix? p w)))

(define (op-display op) (or (op-label op) (symbol->string (op-kind op))))
(define (loc->string loc)
  (if (pair? loc) (format #f "~a:~a" (car loc) (cdr loc)) "unknown"))

(define (lint-ops ops)
  "Resolve OPS once (empty query) and return the list of warning strings:
one per path read by an op before that path's last write in the fold."
  (call-with-values (lambda () (resolve-with-access ops '()))
    (lambda (final log)
      ;; Walk fire order collecting (step op path) for every leaf write and
      ;; every read; then each read is checked against later writes.
      (let loop ((prev '((attributes))) (entries log) (i 0) (writes '()) (reads '()))
        (if (pair? entries)
            (let* ((e     (car entries))
                   (op    (car e))
                   (after (caddr e))
                   (leaf? (null? (op-children op))))
              (loop after (cdr entries) (+ i 1)
                    (if leaf?
                        (append (map (lambda (p) (list i op p))
                                     (changed-paths prev after '()))
                                writes)
                        writes)
                    (append (map (lambda (p) (list i op p)) (cadr e)) reads)))
            (filter-map
             (lambda (r)
               (let* ((step (car r)) (op (cadr r)) (path (caddr r))
                      ;; latest write touching PATH after this read, if any
                      ;; (writes is newest-first, so `find` is the last one).
                      (late (find (lambda (w) (and (> (car w) step)
                                                   (touches? (caddr w) path)))
                                  writes)))
                 (and late
                      (format #f "path ~a read by op ~a (~a) before its last write by op ~a (~a)"
                              (path->string path)
                              (op-display op) (loc->string (op-loc op))
                              (op-display (cadr late)) (loc->string (op-loc (cadr late)))))))
             (reverse (delete-duplicates reads))))))))
