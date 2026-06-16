;;; cmdb/libraries/v2.scm — version 2.
;;;
;;; Like v1, but `region` patches EU NTP pool from "europe.pool.ntp.org"
;;; (v1's shared region-body value) to "paris.pool.ntp.org".
;;;
;;; Demonstrates a library bump as an in-log event: facts before
;;; `(bump-lib "v2")` keep the v1 pool, facts after get v2. Replay is
;;; contemporaneous — each fact applies through the then-current library.

(define-module (cmdb libraries v2)
  #:use-module (hexol kernel)
  #:use-module (cmdb region-render)
  #:export (merge region promote))

(define (merge subtree)
  (list (op:merge subtree '(merge))))

(define (region name attrs)
  (let* ((subtree (render-region attrs))
         (subtree (if (eq? (assq-ref attrs 'geo) 'eu)
                      (deep-merge subtree
                                  '((ntp (pool . "paris.pool.ntp.org"))))
                      subtree)))
    (list (op:set (list 'regions name) subtree `(region ,name)))))

(define (promote region path value)
  (let ((full-path (cons 'regions (cons region path))))
    (list (op:set full-path value `(promote ,region ,path ,value)))))
