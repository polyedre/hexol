;;; hexol/secrets.scm — an inline, sops-backed secrets store.
;;;
;;; Render-time secret resolver keeping secrets *in the inventory file*,
;;; encrypted at rest, instead of separate `*.sops.yaml` files. Three pieces:
;;;
;;;   (secrets-store …)        ;; declare the encrypted store (load time)
;;;   (secret-ref 'key)        ;; a marker referencing a secret at a field
;;;   (resolve-secret-refs)    ;; op that decrypts + substitutes (render)
;;;
;;; Marker + terminal op, not decrypt-in-place: we shell out to `sops` only at
;;; *render* time — never for a plain `tree`/`ops`, which load but never fold.
;;; So `secret-ref` bakes a cheap `<secret-ref>` marker into the resource, and
;;; `resolve-secret-refs` (last in the inventory) walks the resolved state
;;; swapping each marker for plaintext. It runs only inside `resolve`, so
;;; `tree`/`ops` stay sops-free — with the two flags that explicitly ask for a
;;; fold as the exception: `tree --realize` and `tree -v` resolve, and
;;; therefore decrypt, like `render` does.
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
  #:export (secrets-store secret-ref secret-ref? secret-ref-key secret-ref-cipher
            hx-secret resolve-secret-refs secret-resolution-disabled
            ;; reused by (hexol secret-tool): doc gather + serializer + decrypt.
            marker-doc clauses->sops-yaml decrypt-yaml secrets-warn))

;; ---------- the secret-ref marker ----------
;;
;; A marker is data, not an op — it sits where the author wrote it until
;; `resolve-secret-refs' swaps in the plaintext. It carries two optional bits:
;;
;;   KEY    an explicit symbol id, or #f → the secret is keyed by its *path*
;;          in the resolved state (where it ends up in the tree).
;;   CIPHER the inline `ENC[…]' ciphertext, or #f → a pure reference that
;;          borrows another marker's (or the store block's) ciphertext by id.
;;
;; So `(hx-secret "ENC")' is path-keyed inline data; `(hx-secret 'id "ENC")' is
;; symbol-keyed inline data (rename-safe, re-usable); `(secret-ref 'id)' is a
;; pure reference. All resolve through the SAME store envelope (one age key,
;; one MAC) — only the source layout and the choice of key differ.

(define-record-type <secret-ref>
  (make-secret-ref key cipher)
  secret-ref?
  (key    secret-ref-key)
  (cipher secret-ref-cipher))

(define (secret-ref key)
  "Reference the secret named KEY (a symbol), declared elsewhere by
`(hx-secret 'KEY …)' or in the store's `(data …)' block.  A marker with no
ciphertext of its own."
  (make-secret-ref key #f))

(define hx-secret
  ;; (hx-secret "ENC[…]")     → keyed by its path in the resolved state.
  ;; (hx-secret 'id "ENC[…]") → keyed by the explicit symbol ID (survives
  ;;                            renames, and re-usable via (secret-ref 'id)).
  (case-lambda
    ((cipher)
     (unless (string? cipher)
       (error "secrets: (hx-secret CIPHER) wants a ciphertext string, got:" cipher))
     (make-secret-ref #f cipher))
    ((id cipher)
     (unless (and (symbol? id) (string? cipher))
       (error "secrets: (hx-secret 'ID CIPHER) wants a symbol then a string, got:" id cipher))
     (make-secret-ref id cipher))))

;; ---------- the registered store (the envelope) ----------
;;
;; `(secrets-store …)` quotes and records its clauses — it does NOT decrypt.
;; `registered-store` holds the clause alist (version / lastmodified / mac /
;; keys / optional data). Inline ciphertexts no longer register here; they are
;; gathered from the resolved state at resolve time (see `marker-doc').

(define registered-store #f)

(define-syntax secrets-store
  (syntax-rules ()
    ((_ clause ...)
     (register-secrets-store! (quote (clause ...))))))

(define (register-secrets-store! clauses)
  "Record the quoted CLAUSES of a (secrets-store …) form for later decryption."
  (set! registered-store clauses)
  *unspecified*)

;; When parameterized to #t, `resolve-secret-refs' leaves the markers in place
;; instead of decrypting — so (hexol secret-tool) can fold the inventory to the
;; marker-bearing state, read each secret's path/ciphertext, and never shell
;; out to sops just to inspect the layout.
(define secret-resolution-disabled (make-parameter #f))

;; clause accessors over an explicit clause alist: (version "x") → "x"
;; (scalar); (data (k . v) …) → the tail (multi); likewise (keys …).
(define (clause-scalar clauses tag)
  (let ((c (and clauses (assq tag clauses))))
    (and c (pair? (cdr c)) (cadr c))))
(define (clause-multi clauses tag)
  (let ((c (and clauses (assq tag clauses))))
    (and c (cdr c))))

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

;; ---------- walking the resolved state by path ----------
;;
;; A secret's key is its explicit symbol id, or — lacking one — its PATH in the
;; resolved state: the dotted chain of alist keys and sequence labels leading
;; to it. resolve and (hexol secret-tool) both compute it from the same walk
;; over the same state, so the sops data-map key (which is each value's GCM
;; AAD) matches between seal and decrypt.

(define (alist-get alist k) (let ((c (assq k alist))) (and c (cdr c))))

;; A value is alist-like when it is a non-empty proper list of (key . _) pairs
;; with symbol/string keys; a proper list that is not alist-like is a sequence.
(define (alist-like? v)
  (and (pair? v) (list? v)
       (every (lambda (e) (and (pair? e) (let ((k (car e))) (or (symbol? k) (string? k)))))
              v)))
(define (seq-like? v) (and (pair? v) (list? v) (not (alist-like? v))))

(define (comp->string c)
  (cond ((symbol? c) (symbol->string c)) ((number? c) (number->string c)) (else c)))
(define (path->key parts) (string-join (map comp->string (reverse parts)) "."))

;; A sequence element's label: its `name' (top-level or under `metadata') when
;; present and unique among siblings, else its index — keeps k8s resource paths
;; readable and reorder-stable where resources are named.
(define (element-name e)
  (and (alist-like? e)
       (let* ((md (alist-get e 'metadata))
              (n  (or (alist-get e 'name)
                      (and (alist-like? md) (alist-get md 'name)))))
         (and (string? n) n))))
(define (seq-labels elements)
  (let ((names (map element-name elements)))
    (map (lambda (nm i)
           (if (and nm (= 1 (length (filter (lambda (x) (equal? x nm)) names)))) nm i))
         names (iota (length elements)))))

;; KEY of a marker reached at PARTS: its explicit id, else its path.
(define (marker-key m parts)
  (if (secret-ref-key m) (key->string (secret-ref-key m)) (path->key parts)))

;; Merge (keystr . cipher) pairs into ACC, erroring on a divergent ciphertext
;; for a key already present (they seal as one document).
(define (doc-add acc k c)
  (let ((cur (assoc k acc)))
    (cond ((not cur) (cons (cons k c) acc))
          ((equal? (cdr cur) c) acc)
          (else (error "secrets: two different ciphertexts for key:" k)))))

;; Gather every cipher-bearing marker in STATE as (keystr . ciphertext), keyed
;; by id or path — the inline secrets, in first-seen order. (Excludes the
;; store's `(data …)' block; see `full-doc'.)
(define (marker-doc state)
  (let ((acc '()))
    (define (walk v parts)
      (cond
        ((secret-ref? v)
         (when (secret-ref-cipher v)
           (set! acc (doc-add acc (marker-key v parts) (secret-ref-cipher v)))))
        ((alist-like? v) (for-each (lambda (e) (walk (cdr e) (cons (car e) parts))) v))
        ((seq-like? v)
         (for-each (lambda (e lbl) (walk e (cons lbl parts))) v (seq-labels v)))
        (else #t)))
    (walk state '())
    (reverse acc)))

;; The full sops document: inline markers plus the store's `(data …)' block.
(define (full-doc state)
  (fold (lambda (kv acc) (doc-add acc (key->string (car kv)) (cdr kv)))
        (marker-doc state)
        (or (clause-multi registered-store 'data) '())))

;; The store envelope with its `data' clause set to DOC — the sops document to
;; (de/en)crypt.
(define (store-with-data doc)
  (append (filter (lambda (c) (not (eq? (car c) 'data))) registered-store)
          (list (cons 'data doc))))

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

;; Decrypt the gathered DOC ((keystr . cipher) …) under the store envelope,
;; returning a (keystr . plaintext) alist, or #f when sops can't decrypt.
(define (decrypt-doc doc)
  (cond
    ((null? doc) '())
    ((not registered-store)
     (error "secrets: secrets referenced but no (secrets-store …) envelope declared"))
    (else (decrypt-yaml (clauses->sops-yaml (store-with-data doc))))))

;; ---------- the resolution op ----------

;; Rebuild STATE replacing each marker with its plaintext, keyed exactly as
;; `marker-doc' gathered it (same walk → same key). PLAIN is the decrypted map,
;; or #f → every secret renders a placeholder (sops absent / key missing).
(define (substitute-refs state plain)
  (define (lookup k)
    (if (not plain)
        (format #f "<unresolved secret: ~a>" k)
        (let ((e (assoc k plain))) (if e (cdr e) (error "secrets: no such secret:" k)))))
  (define (walk v parts)
    (cond
      ((secret-ref? v) (lookup (marker-key v parts)))
      ((alist-like? v) (map (lambda (e) (cons (car e) (walk (cdr e) (cons (car e) parts)))) v))
      ((seq-like? v) (map (lambda (e lbl) (walk e (cons lbl parts))) v (seq-labels v)))
      (else v)))
  (walk state '()))

(define (resolve-secret-refs)
  "Return an op that walks the resolved state, gathers every marker's
ciphertext (keyed by id or path), decrypts the store once, and substitutes the
plaintext.  Place it last in the inventory — it must run after the resources
that reference secrets.  A no-op when `secret-resolution-disabled' is set (so
the secret tooling can read the marker layout), and sops-free for a plain
`tree'/`ops' since it only fires during `resolve' (which `tree --realize' and
`tree -v' do run)."
  (make-op 'resolve-secret-refs '(resolve-secret-refs)
    (lambda (state)
      (if (secret-resolution-disabled)
          state
          (substitute-refs state (decrypt-doc (full-doc state)))))
    "resolve-secret-refs"))
