;; Dependencies for building, testing, and running hexol.
;;   guile        — the interpreter (3.x)
;;   guile-json   — the (json) module, imported by (hexol k8s), terraform,
;;                  secrets, and the cmdb
;;   guile-libyaml — the (yaml) module, imported by (hexol ansible)
;;   jq           — used by the secrets tooling
;; This manifest is the source of truth for dependencies: `guix shell -m
;; manifest.scm` reproduces the dev environment, and CI provisions from it.
(specifications->manifest (list "guile" "guile-json" "guile-libyaml" "jq"))
