;; Deliberately broken inventory: the body slot gets a list *of lists* of ops,
;; which is one splice too many. test/errors.sh asserts the error stays short.
(define (bundle)
  (list (list (hx-merge (a 1)) (hx-merge (b 2)))))

(hx-ops (bundle))
