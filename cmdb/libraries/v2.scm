;;; cmdb/libraries/v2.scm — version 2.
;;;
;;; Same shape as v1, but the `region` op patches EU regions' NTP pool
;;; from the legacy "europe.pool.ntp.org" (which v1 writes via the
;;; shared region-body) to "paris.pool.ntp.org".
;;;
;;; This demonstrates a library bump as an in-log event: facts written
;;; before `(bump-lib "v2")` keep their v1-rendered NTP pool; facts
;;; written after get the v2 one. Replay is contemporaneous — each fact
;;; applies through whichever library was current when it landed.

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
