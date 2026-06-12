;;; hexol/sh.scm — tiny shell/PATH helpers shared by the target libraries.
;;;
;;; `which-cmd` was duplicated in (hexol k8s) and (hexol secrets) — both need
;;; to resolve a binary's absolute path before shelling out (helm/yq/curl,
;;; sops). Two independent exports of the same name make any inventory that
;;; imports both modules warn about a clashing binding, so the one definition
;;; lives here and both libraries re-export it (the same variable, so no
;;; clash). Kept deliberately dependency-free.

(define-module (hexol sh)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (which-cmd))

;; Absolute path of COMMAND on PATH, or #f. We resolve it ourselves (rather
;; than rely on the shell) so a `cmd | yq …` pipe can call binaries by absolute
;; path — robust even when PATH carries an unexpanded leading `~/` entry, which
;; a bare command name in a child shell would miss.
(define (which-cmd command)
  "Return the absolute path of COMMAND on PATH, or #f if not found/executable."
  (let* ((home   (or (getenv "HOME") ""))
         (expand (lambda (dir)
                   (if (string-prefix? "~/" dir) (string-append home (substring dir 1)) dir))))
    (find (lambda (f) (and (file-exists? f) (access? f X_OK)))
          (map (lambda (dir) (string-append (expand dir) "/" command))
               (string-split (or (getenv "PATH") "") #\:)))))
