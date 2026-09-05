;;; test/fixtures/tree-throw.scm — fixture for test/tree-cli.sh.
;;;
;;; An op that raises the short `(throw key subr msg)' form, which carries no
;;; message-args list. `tree --realize' must report it as a note, not crash
;;; while formatting it.

(use-modules (hexol))

(hx-ops
  (make-op 'boom '(boom)
           (lambda (state) (throw 'oops 'some-subr "the fold went wrong"))
           "boom"))
