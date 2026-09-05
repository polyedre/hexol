;; Same mistake, but deferred to fold time inside ($ …) — the blame line is
;; the authored op on line 6.
(define (label name)
  (string-append "app-" name))

(hx-ops (hx-merge (app ($ (label 'payments-api)))))
