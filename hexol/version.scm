;;; hexol/version.scm — the one place the release version lives.
;;;
;;; `hexol --version` prints it; CHANGELOG.md's top entry and guix.scm's
;;; `version` field must agree with it (guix.scm can't import this module at
;;; package-definition time, so it carries a copy — see the comment there).

(define-module (hexol version)
  #:export (%hexol-version))

(define %hexol-version "0.1.0")
