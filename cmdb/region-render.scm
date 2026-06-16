;;; cmdb/region-render.scm — render one region's subtree from attributes.
;;;
;;; Resolves region-body.scm against a fact's attr alist, landing a
;;; `(region <name> <attrs>)` fact's subtree under `(regions <name> …)`.

(define-module (cmdb region-render)
  #:use-module (hexol kernel)
  #:use-module (cmdb region-body)
  #:export (render-region))

(define (render-region attrs)
  (resolve (region-body-ops) attrs))
