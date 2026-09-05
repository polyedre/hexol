;;; A renderer that emits something and then dies. Used by
;;; test/render-buffer.sh: stdout must stay EMPTY when a render fails, so
;;; `hexol render … | kubectl apply -f -` can never see a truncated stream.

(renders-with "boom"
  (lambda (state)
    (display "PARTIAL-OUTPUT\n")
    (error "boom: renderer exploded halfway")))

(list
  (op:merge '((marker . "ok")) '(merge marker)))
