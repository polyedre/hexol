;;; examples/regions.scm — the region table as an importable module.
;;;
;;; The dispatch axes as plain data, split out of examples/inventory.scm so
;;; more than one consumer can share the same table: the inventory folds a
;;; per-region body over it (see inventory.scm), and any other program can
;;; `(use-modules (examples regions))` to read the same source of truth.
;;;
;;; Each entry is `(name . attribute-seed)` — the cdr is exactly the query
;;; attributes the body resolves against for that region.

(define-module (examples regions)
  #:export (regions))

(define regions
  '((alpha5 (region . alpha5) (dc . alpha) (geo . eu) (hw-profile . gpu-dense)
     (network-profile . advanced)  (tier . prod) (sovereignty . none))
    (bravo1 (region . bravo1) (dc . bravo) (geo . eu) (hw-profile . standard)
          (network-profile . sovereign) (tier . prod) (sovereignty . strict))
    (charlie6 (region . charlie6) (dc . charlie) (geo . na) (hw-profile . standard)
          (network-profile . basic)     (tier . dev)  (sovereignty . none))))
