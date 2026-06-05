;;; cmdb/libraries/v1.scm — version 1 of the CMDB op library.
;;;
;;; Library versions are addressable from facts via (bump-lib "<sha>").
;;; For the POC, <sha> is a short tag like "v1" that maps to module
;;; (cmdb libraries v<sha>) at file cmdb/libraries/<sha>.scm.

(define-module (cmdb libraries v1)
  #:use-module (hexol kernel)
  #:use-module (cmdb region-render)
  #:export (merge region promote))

(define (merge subtree)
  (list (op:merge subtree '(merge))))

(define (region name attrs)
  (let ((subtree (render-region attrs)))
    (list (op:set (list 'regions name) subtree `(region ,name)))))

(define (promote region path value)
  (let ((full-path (cons 'regions (cons region path))))
    (list (op:set full-path value `(promote ,region ,path ,value)))))
