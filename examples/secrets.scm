;;; examples/secrets.scm — inline, sops-backed secrets, end to end.
;;;
;;; Self-contained: it carries the encrypted store AND a throwaway age key, so
;;; `hexol render` decrypts and substitutes real plaintext on a fresh clone.
;;; The secrets it guards are fake.
;;;
;;;   (secrets-store …)     the envelope — one age recipient + one MAC, no data
;;;   (hx-secret "ENC[…]")  a ciphertext at its point of use, keyed by its path
;;;                         in the output (pin a name with (hx-secret 'id "…"))
;;;   (resolve-secret-refs) decrypts once and swaps each marker for plaintext
;;;
;;; Render:  ./bin/hexol render -o yaml -i examples/secrets.scm
;;; Manage:  ./bin/hexol secret ls|get|set|edit|rekey -i examples/secrets.scm

(use-modules (hexol k8s)
             (hexol secrets))

;; sops decrypts with the age identity it finds in the environment; hexol just
;; has to put it there. `fetch-age-key' is the hook — here a hardcoded
;; throwaway key; in a real inventory return yours instead, e.g.
;;   (define (fetch-age-key) (getenv "HEXOL_AGE_KEY"))
(define (fetch-age-key)
  "AGE-SECRET-KEY-1E3W2J9G97YCKVJS0FNWSRD7VC7CMYF77TUPYKAQ2MMLF0HS3WHLQ2CM4FW")

(setenv "SOPS_AGE_KEY" (fetch-age-key))

;; The envelope: crypto metadata for one sops document, sealed to the throwaway
;; key's recipient. No data block — ciphertexts live inline below.
(secrets-store
  (version "3.12.2")
  (lastmodified "2026-06-21T13:41:25Z")
  (mac "ENC[AES256_GCM,data:oIN8GNRf3fCK2iLrrOJkuwXSQITUK6lJ3WRrfybDwFEwZjWXklKsk3CqdytLm5Zmtbc0RJO5f+pTuQ4GzAHqlLxTSRmZX+UOlhMVdG2lD4Vm2DKDclZ8s18+fxWPviQP3IgwHzeMTIrNaf7alXEE765aYCom3G5aC4mNE1uThAE=,iv:CkoYhk0oBDpi3txa97c8cvyzIvpH9LARIaAL+WAT7CA=,tag:vOxJCMdGITlPvoBBkdIZLw==,type:str]")
  (keys
    (age
      (recipient "age10fet6zvr3h2dldc36630g93qp6zyd77pfmn63r48fkkwmzauucaq3tem02")
      (enc
        "-----BEGIN AGE ENCRYPTED FILE-----"
        "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBvb2luOG54TVo2MVNwbUJY"
        "WFpKWms4SWxYQzltR2licFBhVTJqWTFlUEcwCmZmSk81UnhnQ1l5UXdWQ1VreHpk"
        "K1NhSkk3SFd1cmRIZENCZkErKytieTQKLS0tIGhJbWo5cFFLUlFVQ2RHVThvbWdM"
        "V0NubTNldi96QmwrRWFwQXh3QXMraVEKPH0Gbnm9ygDW34kSlXJVecgOJ57wYQwr"
        "wInFC7JEUDYli9Gb0z/hzIq1mPaIVvNRNsJ/chv1tvMsBLBr4jJb1A=="
        "-----END AGE ENCRYPTED FILE-----"))))

;; Each (hx-secret "ENC[…]") resolves to its plaintext at render. Using
;; `string-data' (plaintext side of a k8s Secret) shows the decrypted values.
(hx-ops
  (with-namespace "tintin"
    (secret "app-secrets"
      (string-data
        (DB_PASSWORD (hx-secret "ENC[AES256_GCM,data:zZw60P1n7VDwgyWx3Kg4xsW1tw==,iv:iKO5lh40stVRKZwv6dBNVi46cNNbYpZjflanijxI/n8=,tag:LvnSOK4zDk+F0NprFeTu6g==,type:str]"))
        (API_TOKEN   (hx-secret "ENC[AES256_GCM,data:09mmjPNA3QKWjf/S6f+DUj/znvs=,iv:+Gr+CkAYJQakLfJbQYeJoh/W7kg/Jcse75/Kzg2MP3k=,tag:7NcJl8TKalOKUcM/Bv7gpg==,type:str]"))))
    (secret "tls-params"
      (string-data
        (dhparam.pem (hx-secret "ENC[AES256_GCM,data:xsF6bl936FdZoP1nY/DehNSPr4xEJNuiOdivydLJmjB/8I79IeQNDNO7qsdFguSDs5PgKtkdB82Ec7khOE5R2Y6oHawwhWpRQLxXqbY+LnX1vt5FwjpTZq7t,iv:qnCpHwtnZm8JhuDMZijjwym3U1xzJvvOdvyP8PqyqR4=,tag:86BYrKZqRN7wJzK9i68qnQ==,type:str]")))))
  (resolve-secret-refs))
