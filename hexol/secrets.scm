;;; hexol/secrets.scm — an inline, sops-backed secrets store.
;;;
;;; Render-time secret resolver keeping secrets *in the inventory file*,
;;; encrypted at rest, instead of separate `*.sops.yaml` files. Three pieces:
;;;
;;;   (secrets-store …)        ;; declare the encrypted store (load time)
;;;   (secret-ref 'key)        ;; a marker referencing a secret at a field
;;;   (resolve-secret-refs)    ;; op that decrypts + substitutes (render)
;;;
;;; Marker + terminal op, not decrypt-in-place: resources are built at *load*
;;; time (the quasiquote `,(secret-ref …)` runs then), but we shell out to
;;; `sops` only at *render* time — never for `tree`/`ops`, which load but
;;; never fold. So `secret-ref` bakes a cheap `<secret-ref>` marker into the
;;; resource, and `resolve-secret-refs` (last in the inventory) walks the
;;; resolved state swapping each marker for plaintext. It runs only inside
;;; `resolve`, so `tree`/`ops` stay sops-free.
;;;
;;; One shared envelope: the whole store is ONE sops document — a single
;;; age-encrypted data key and one MAC cover every secret, so each added
;;; secret costs only its `ENC[…]` ciphertext. Data keys emit in sorted order
;;; on both seal and decrypt, so the MAC (computed over values in tree-walk
;;; order) verifies regardless of the author's alist arrangement.
;;;
;;; Decryption is lazy + memoized: the first resolved `secret-ref` forces one
;;; `sops -d`, cached for the render. If `sops` is absent — or the decrypt
;;; fails (deployer's key missing) — resolution degrades to a marked
;;; placeholder + warning, so the example still renders a structurally-valid
;;; stream for anyone without the secrets (like the old `sops-manifest` skip).

(define-module (hexol secrets)
  #:use-module (hexol kernel)
  #:use-module (hexol sh)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:re-export (which-cmd)              ; PATH helper from (hexol sh)
  #:export (secrets-store secret-ref secret-ref? secret-ref-key
            resolve-secret-refs
            ;; reused by (hexol secret-tool): serializer + decrypt path.
            clauses->sops-yaml decrypt-yaml secrets-warn))

;; ---------- the secret-ref marker ----------
;;
;; `(secret-ref 'key)` returns one of these — data, not an op. It sits where
;; the author wrote it until `resolve-secret-refs` swaps in the plaintext.

(define-record-type <secret-ref>
  (make-secret-ref key)
  secret-ref?
  (key secret-ref-key))

(define (secret-ref key)
  "Return a marker standing in for the secret named KEY (a symbol) until
`resolve-secret-refs' decrypts the store and substitutes its plaintext."
  (make-secret-ref key))

;; ---------- the registered store ----------
;;
;; `(secrets-store …)` quotes and records its clauses — it does NOT decrypt.
;; `registered-store` holds the clause alist (version / lastmodified / mac /
;; age / data); `decrypt-memo` caches the one per-render decryption ('unset
;; until forced, then the plaintext string-keyed alist, or #f on failure).

(define registered-store #f)
(define decrypt-memo 'unset)

(define-syntax secrets-store
  (syntax-rules ()
    ((_ clause ...)
     (register-secrets-store! (quote (clause ...))))))

(define (register-secrets-store! clauses)
  "Record the quoted CLAUSES of a (secrets-store …) form for later
decryption.  Resets any cached plaintext."
  (set! registered-store clauses)
  (set! decrypt-memo 'unset)
  *unspecified*)

;; clause accessors: (version "x") → "x" (scalar); (data (k . v) …) → the
;; tail (multi); likewise (age …). `clause-*' take an explicit alist (so the
;; CLI can serialize a parsed store); `store-*' are shorthands over the
;; registered store.
(define (clause-scalar clauses tag)
  (let ((c (and clauses (assq tag clauses))))
    (and c (pair? (cdr c)) (cadr c))))
(define (clause-multi clauses tag)
  (let ((c (and clauses (assq tag clauses))))
    (and c (cdr c))))
(define (store-scalar tag) (clause-scalar registered-store tag))
(define (store-multi tag)  (clause-multi  registered-store tag))

;; ---------- serialization back to a sops document ----------
;;
;; Rebuild the sops YAML tree the store was sealed as: a sorted `data:` map
;; (so the MAC verifies) plus the `sops:` metadata block. sops decrypts off
;; the parsed tree, so indentation is free.
;;
;; The `keys' clause carries recipient groups as structured Scheme —
;; `(pgp (fp …) (created-at …) (enc <line> …))' and/or `(age (recipient …)
;; (enc …))' — emitted as sops YAML grouped under `pgp:`/`age:`. Only `enc'
;; plus the recipient id (`fp'/`recipient') are load-bearing; sops parses the
;; block into a struct, so other field/indent choices are free. `mac'
;; (encrypted with `lastmodified' as AAD) and `lastmodified' kept verbatim so
;; the MAC verifies.

(define (key->string k)
  (if (symbol? k) (symbol->string k) k))

;; accessors over a recipient body, e.g. ((fp "…") (enc "a" "b")):
;; `entry-scalar' → single value; `entry-lines' → list tail.
(define (entry-scalar body k) (let ((c (assq k body))) (and c (cadr c))))
(define (entry-lines  body k) (let ((c (assq k body))) (and c (cdr c))))

;; Emit one item under a `pgp:`/`age:` group: FIELDS an ordered list of
;; (scalar KEY VALUE) / (block KEY CHOMP LINES), the first carrying `- `.
(define (emit-key-entry p fields)
  (let ((first #t))
    (for-each
     (lambda (f)
       (let ((lead (if first "        - " "          ")))
         (set! first #f)
         (match f
           (('scalar key val)
            (format p "~a~a: ~a~%" lead key val))
           (('block key chomp lines)
            (format p "~a~a: ~a~%" lead key chomp)
            (for-each (lambda (l) (format p "            ~a~%" l)) lines)))))
     fields)))

(define (emit-keys p keys)
  (let ((pgps (filter (lambda (e) (eq? (car e) 'pgp)) keys))
        (ages (filter (lambda (e) (eq? (car e) 'age)) keys)))
    (when (pair? pgps)
      (format p "    pgp:~%")
      (for-each
       (lambda (e)
         (let ((b (cdr e)))
           (emit-key-entry p
             (filter (lambda (x) x)
               (list (and (entry-scalar b 'created-at)
                          (list 'scalar "created_at"
                                (string-append "\"" (entry-scalar b 'created-at) "\"")))
                     (list 'block "enc" "|-" (or (entry-lines b 'enc) '()))
                     (and (entry-scalar b 'fp)
                          (list 'scalar "fp" (entry-scalar b 'fp))))))))
       pgps))
    (when (pair? ages)
      (format p "    age:~%")
      (for-each
       (lambda (e)
         (let ((b (cdr e)))
           (emit-key-entry p
             (list (list 'scalar "recipient" (entry-scalar b 'recipient))
                   (list 'block "enc" "|" (or (entry-lines b 'enc) '()))))))
       ages))))

(define (clauses->sops-yaml clauses)
  "Rebuild the sops YAML document the store CLAUSES (the cdr of a
`(secrets-store …)' form) were sealed as — a sorted `data:' map plus the
`sops:' metadata block — so sops can decrypt it."
  (let ((data (sort (or (clause-multi clauses 'data) '())
                    (lambda (a b) (string<? (key->string (car a))
                                            (key->string (car b))))))
        (keys (or (clause-multi clauses 'keys) '())))
    (call-with-output-string
     (lambda (p)
       (format p "data:~%")
       (for-each (lambda (kv)
                   (format p "    ~a: ~a~%" (key->string (car kv)) (cdr kv)))
                 data)
       (format p "sops:~%")
       (emit-keys p keys)
       (format p "    lastmodified: \"~a\"~%" (clause-scalar clauses 'lastmodified))
       (format p "    mac: ~a~%" (clause-scalar clauses 'mac))
       (format p "    version: ~a~%" (clause-scalar clauses 'version))))))

(define (store->sops-yaml) (clauses->sops-yaml registered-store))

;; ---------- decryption (lazy, memoized) ----------
;;
;; `which-cmd` is the shared (hexol sh) PATH resolver, re-exported above.

(define (secrets-warn fmt-str . args)
  (apply format (current-error-port)
         (string-append ";; secrets: " fmt-str "~%") args))

;; Decrypt a sops YAML string, returning its plaintext `data` map (string-
;; keyed alist), or #f + warning when sops is missing or decrypt fails (e.g.
;; deployer's key absent). Ciphertext goes to a temp file for sops to read.
(define (decrypt-yaml yaml)
  (let ((sops (which-cmd "sops")))
    (cond
      ((not sops)
       (secrets-warn "sops not on PATH — secrets render as placeholders")
       #f)
      (else
       (let* ((tmpl (string-copy "/tmp/hexol-store-XXXXXX"))
              (port (mkstemp! tmpl)))
         (display yaml port)
         (close-port port)
         (let* ((cmd    (format #f "~a -d --input-type yaml --output-type json ~a"
                                sops tmpl))
                (in     (open-input-pipe cmd))
                (output (get-string-all in))
                (status (close-pipe in)))
           (delete-file tmpl)
           (cond
             ((not (zero? (status:exit-val status)))
              (secrets-warn "sops -d failed — provide the key to resolve secrets")
              #f)
             (else
              (let ((parsed (json-string->scm output)))
                (or (assoc-ref parsed "data")
                    (begin (secrets-warn "decrypted store has no `data' map") #f)))))))))))

(define (force-store-decrypt!)
  (when (eq? decrypt-memo 'unset)
    (set! decrypt-memo (decrypt-yaml (store->sops-yaml))))
  decrypt-memo)

(define (secret-value key)
  "Resolve the secret named KEY (a symbol) to its plaintext string, or a
placeholder when the store can't be decrypted."
  (unless registered-store
    (error "secrets: (secret-ref) used but no (secrets-store …) was declared"))
  (let ((plain (force-store-decrypt!)))
    (if (not plain)
        (format #f "<unresolved secret: ~a>" key)
        (let ((entry (assoc (key->string key) plain)))
          (if entry
              (cdr entry)
              (error "secrets: no such key in store:" key))))))

;; ---------- the resolution op ----------

(define (replace-refs x)
  "Deep-copy X, replacing every <secret-ref> marker with its plaintext.
Recurs through both alists and plain lists via car/cdr."
  (cond
    ((secret-ref? x) (secret-value (secret-ref-key x)))
    ((pair? x) (cons (replace-refs (car x)) (replace-refs (cdr x))))
    (else x)))

(define (resolve-secret-refs)
  "Return an op that walks the resolved state and replaces every
`(secret-ref 'key)' marker with the secret's plaintext.  Decrypts the store
once (memoized) the first time a marker is found, so it must run after the
resources that reference secrets — place it last in the inventory.  Because
it only runs during `resolve', `tree'/`ops' never invoke sops."
  (make-op 'resolve-secret-refs '(resolve-secret-refs)
    (lambda (state) (replace-refs state))
    "resolve-secret-refs"))
