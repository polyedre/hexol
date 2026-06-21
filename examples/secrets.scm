;;; examples/secrets.scm — inline, sops-backed secrets, end to end.
;;;
;;; Unlike examples/homelab.scm (whose real `(secrets-store …)` lives in a
;;; gitignored homelab.secrets.scm and only its deployer can decrypt), this
;;; file is fully self-contained: it carries both the encrypted store AND a
;;; THROWAWAY age key, so `hexol render` decrypts and substitutes real
;;; plaintext for *anyone* on a fresh clone. The secrets it guards are fake.
;;;
;;; Three moving parts (all from (hexol secrets)):
;;;   (secrets-store …)   — the encrypted store, sealed to an age recipient
;;;   (secret-ref 'key)   — a marker that stands in for a secret at a field
;;;   (resolve-secret-refs) — terminal op: decrypts once, swaps in plaintext
;;;
;;; Render it:  ./bin/hexol render -o yaml -i examples/secrets.scm

(use-modules (hexol k8s)
             (hexol secrets))

;; ---- where the decryption key comes from ----
;;
;; sops needs the age *identity* (private key) to decrypt the store below.
;; hexol never touches the key itself — it shells out to `sops -d`, which
;; hunts for the identity in the environment (SOPS_AGE_KEY, then
;; SOPS_AGE_KEY_FILE, …). So the only thing an inventory has to do is put the
;; key somewhere sops already looks.
;;
;; `fetch-age-key' is that single hook. The default below returns a throwaway
;; key hardcoded in this file, so the example is reproducible for everyone. In
;; a real inventory you would REDEFINE it to source the key from wherever you
;; actually keep it — anything that returns the `AGE-SECRET-KEY-1…` string —
;; e.g. one of:
;;
;;   (define (fetch-age-key) (getenv "HEXOL_AGE_KEY"))           ; from the env
;;
;;   (define (fetch-age-key)                                     ; from a file
;;     (call-with-input-file "/run/secrets/age.key"
;;       (@ (ice-9 textual-ports) get-string-all)))
;;
;;   (define (fetch-age-key)                                     ; from `pass`
;;     (let* ((p ((@ (ice-9 popen) open-input-pipe) "pass show age/hexol"))
;;            (k ((@ (ice-9 textual-ports) get-string-all) p)))
;;       (close-pipe p) k))
;;
(define (fetch-age-key)
  "AGE-SECRET-KEY-1E3W2J9G97YCKVJS0FNWSRD7VC7CMYF77TUPYKAQ2MMLF0HS3WHLQ2CM4FW")

;; Hand it to sops via the environment it already searches. (SOPS_AGE_KEY
;; takes the key material directly; no temp file needed.)
;;
;; NOTE: this runs at inventory *load* time, so it covers `hexol render`. The
;; `hexol secret` management commands (edit/set/rekey/…) do NOT evaluate the
;; inventory — they parse the (secrets-store …) form for byte-accurate
;; rewriting — so they won't see this. To manage the store, export the key
;; yourself first:
;;   export SOPS_AGE_KEY=AGE-SECRET-KEY-1E3W2J9G97YCKVJS0FNWSRD7VC7CMYF77TUPYKAQ2MMLF0HS3WHLQ2CM4FW
(setenv "SOPS_AGE_KEY" (fetch-age-key))

;; ---- the encrypted store ----
;;
;; One sops document, sealed to the age recipient
;; `age10fet6zvr3h2dldc36630g93qp6zyd77pfmn63r48fkkwmzauucaq3tem02' (its
;; identity is the throwaway key above). A single age stanza + one MAC cover
;; every secret; `data' keys are kept sorted so the MAC verifies on decrypt.
;; To rotate or add secrets, manage it with `hexol secret set|edit|rekey`.
(secrets-store
  (version "3.12.2")
  (lastmodified "2026-06-21T11:45:44Z")
  (mac "ENC[AES256_GCM,data:qxcrOTSo4weQ/8PSFPWxTa7+aLsAYA120iW4bLEmxEssX16az5t3U0HecSvrxdxgDoYih1ZERT3Mx5lM0dkWs4qhDdSfVAxHpzB0vCwqAuULuKAYVJl10DXS/Hh/v/y21wY38nWSs9zi6qReWI6laeIaFOzgzmgNEunuUfDCBCs=,iv:Jq8ZP1p0NpjMr0Eg7Y4MGnjf5yeOJm5Ar5VaLZ4q0qw=,tag:Spdcx+h4KazMcW6hBoxedA==,type:str]")
  (keys
    (age
      (recipient "age10fet6zvr3h2dldc36630g93qp6zyd77pfmn63r48fkkwmzauucaq3tem02")
      (enc
        "-----BEGIN AGE ENCRYPTED FILE-----"
        "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBFV1JjNlFVU0xjRkdMRkFl"
        "Qm5aeGJDanBnOHhVZ0tUM1MrSDJLSC90YkEwCkh2ZHBTZmFsMThaTWtxMTVMdnUx"
        "cUpoN25vaVVlaFdsS2FIUWlyelF0cTQKLS0tICtSQ2IzTWF0Wit1ZmlxOE9zZ2NU"
        "UVBoV0FONEQ4Z01BQ3BSK2VUWHJjejAK1ih8/M9sO/1uq0ofzjw80exph4XN2dZq"
        "xh5UyEpbIeW7b0FcxRSRcIfB6o/JIndR2M9MCRVwvEHiLrdOeoQWAg=="
        "-----END AGE ENCRYPTED FILE-----")))
  (data
    (api/token       . "ENC[AES256_GCM,data:5eOoONOPZIIwTV+jC5LvWIlmiRo=,iv:I6uShjyWuWsfcgH6jeIGb+ejT5BPOyPprPq7oNADaf4=,tag:qzfJytikUrikVtpJrgv1mA==,type:str]")
    (db/password     . "ENC[AES256_GCM,data:xcg/hKLvdBv0aGYpcVBfa+P5tw==,iv:3oU1CC5r7BFAFl4MBWUXMy4aOZ0eUqHsFMrJwWRORVA=,tag:9CqsWE70lJNrwXhDWp4a1Q==,type:str]")
    (tls/dhparam.pem . "ENC[AES256_GCM,data:Fi2NcXaqcYks7rVM3eoIg7+OTrae9j56tr1HtBC98huJyR+g/8xZaMPvBJVpmin7mRLVHDu8l6sRcj6RlGpbHeJxtk+odPDAa/S2s7TZ4Q6PWxgn+01urxd7,iv:PYFF1cfum3/LD0oJaZPJVSrBa/GLivebT9+q2/ttN7s=,tag:6snTwnpljmmJBhszyo1kxg==,type:str]")))

;; ---- consume the secrets ----
;;
;; `(secret-ref 'key)' bakes a marker into the resource at load time; the
;; render-time `resolve-secret-refs' op below decrypts the store once and
;; swaps each marker for its plaintext. We put them in `string-data' (the
;; plaintext side of a k8s Secret — Kubernetes base64s it at apply), so the
;; rendered YAML shows the decrypted values verbatim.
(hx-ops
  (with-namespace "tintin"
    (secret "app-secrets"
      (string-data
        (DB_PASSWORD (secret-ref 'db/password))
        (API_TOKEN   (secret-ref 'api/token))))
    (secret "tls-params"
      (string-data
        (dhparam.pem (secret-ref 'tls/dhparam.pem)))))

  ;; Resolve last: it must run after every resource that holds a marker.
  (resolve-secret-refs))
