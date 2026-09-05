;;; hexol.scm — the umbrella module.
;;;
;;; `(use-modules (hexol))` pulls in the engine (kernel) and the author
;;; surface (hx-ops / hx-merge / hx-when / hx-case / hx-append / hx-late /
;;; attrs / $ / resource), plus `scope-ops` for building your own scope form. Target libraries are separate submodules you opt into
;;; explicitly, e.g. `(use-modules (hexol) (hexol k8s))`.

(define-module (hexol)
  #:use-module (hexol kernel)
  #:use-module (hexol surface)
  #:re-export (;; kernel
               make-op op? op-kind op-source op-effect op-label op-children
               apply-op resolve compose-ops for-each-into
               op:merge op:set op:append op:when op:case op:late
               scope-ops
               state-get state-set state-append deep-merge
               current-trace resolve-with-trace path-get load-inventory-file
               current-timings resolve-with-timings
               renders-with
               ;; surface
               hx-ops hx-each hx-merge hx-when hx-case hx-append hx-late
               $ attr get attrs str fmt block body
               resource transform-resources annotate-all label-all
               semver-compare semver> semver< semver=))
