;;; examples/regions.scm — the region table as an importable module.
;;;
;;; Same three regions as examples/inventory.scm, exported as a module so the
;;; CMDB driver `bin/sync-inventory` can load them and POST one
;;; `(region <name> <attrs>)` fact per entry. The CMDB library expands each
;;; fact into the full per-region subtree via `cmdb/region-render.scm` (which
;;; shares its body with the inventory example). See docs/cmdb.md.
;;;
;;; Dispatch axes as data: dc, geo, hw-profile, network-profile, tier,
;;; sovereignty. Each cdr is the attribute seed. The three entries exercise
;;; the body's branches (gpu/advanced/prod, sovereign/strict, standard/basic/dev).

(define-module (examples regions)
  #:export (regions))

(define regions
  '((alpha5 (region . alpha5) (dc . alpha) (geo . eu) (hw-profile . gpu-dense)
     (network-profile . advanced)  (tier . prod) (sovereignty . none))
    (bravo1 (region . bravo1) (dc . bravo) (geo . eu) (hw-profile . standard)
     (network-profile . sovereign) (tier . prod) (sovereignty . strict))
    (charlie6 (region . charlie6) (dc . charlie) (geo . na) (hw-profile . standard)
     (network-profile . basic)     (tier . dev)  (sovereignty . none))))
