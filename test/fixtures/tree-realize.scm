;;; test/fixtures/tree-realize.scm — fixture for test/tree-cli.sh.
;;;
;;; A deferred construct plus an op whose effect touches the filesystem. `tree`
;;; folds by default and shows the resources the construct produced; `tree
;;; --no-fold` must load this without folding — the marker file is the proof.

(use-modules (hexol) (hexol k8s))

(define marker (or (getenv "HEXOL_TEST_MARKER") "/dev/null"))

(hx-ops
  ;; Side-effecting op: fires only during a real fold.
  (make-op 'touch-marker '(touch-marker)
           (lambda (state)
             (call-with-output-file marker (lambda (p) (display "fired" p)))
             state)
           "touch-marker")
  (configmap "cfg" (namespace "demo") (data (K "v")))
  (hx-merge (cfg (suffix "late")))
  ;; A head arg read from state: no wrapper needed, the label resolves on fold.
  (configmap (str "cfg-" (get '(cfg suffix))) (namespace "demo") (data (K "v")))
  ;; `hx-late` must be reachable through `(use-modules (hexol))` alone — this
  ;; file imports nothing else that exports it.
  (hx-late "late block"
    (configmap (str "cfg-hx-" (get '(cfg suffix))) (namespace "demo") (data (K "v")))))
