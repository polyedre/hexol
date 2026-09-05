;; A helper op nested inside hx-when: the fold-time throw crosses two
;; %with-location layers (the inner op and the enclosing one), and the
;; message must still carry exactly one FILE:LINE prefix.
(define (labelled)
  (hx-merge (name ($ (string-append "app-" 'oops)))))

(hx-ops (hx-when #t (labelled)))
