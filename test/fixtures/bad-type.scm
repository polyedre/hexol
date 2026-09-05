;; Deliberately broken inventory: the top-level form starting on line 3 calls
;; string-append on a symbol at load time. test/errors.sh asserts the error
;; names this file and that line (forms are blamed on the line they open on).
(define app-label
  (string-append "app-" 'payments-api))

(hx-ops (hx-merge (app ($ app-label))))
