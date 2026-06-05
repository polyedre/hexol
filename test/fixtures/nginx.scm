;;; A small loadable inventory fixture: the file evaluates to a list of ops,
;;; the shape `load-inventory-file` expects. With surface macros this would
;;; be written (hx-ops (hx-merge (nginx ...)) (hx-append packages nginx)).

(list
  (op:merge '((nginx (user . "nginx") (workers . 4))) '(merge nginx-defaults))
  (op:append '(packages) 'nginx '(append packages nginx)))
