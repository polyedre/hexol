;;; test/fixtures/tree-realize.scm — fixture for test/tree-cli.sh.
;;;
;;; A deferred construct plus an op whose effect touches the filesystem. `tree`
;;; must load this without folding — the marker file is the proof — while
;;; `tree --realize` folds and shows the resources the construct produced.

(use-modules (hexol) (hexol k8s))

(define marker (or (getenv "HEXOL_TEST_MARKER") "/dev/null"))

(hx-ops
  ;; Side-effecting op: fires only during a real fold.
  (make-op 'touch-marker '(touch-marker)
           (lambda (state)
             (call-with-output-file marker (lambda (p) (display "fired" p)))
             state)
           "touch-marker")
  (configmap "cfg" (namespace "demo") (data (K "v"))))
