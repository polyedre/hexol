;;; cmdb/region-render.scm — render one region's subtree from attributes.
;;;
;;; Resolves the CMDB's own per-region body (cmdb/region-body.scm) against
;;; a fact's attribute alist, so a `(region <name> <attrs>)` fact lands the
;;; region's subtree under `(regions <name> …)`.

(define-module (cmdb region-render)
  #:use-module (hexol kernel)
  #:use-module (cmdb region-body)
  #:export (render-region))

(define (render-region attrs)
  (resolve (region-body-ops) attrs))
