;;; hexol/secret-tool.scm — the engine behind `hexol secret …`.
;;;
;;; Each mutating verb is one pipeline: locate the `(secrets-store …)' form
;;; (tracking its span), decrypt to a plaintext map, mutate, re-seal with
;;; sops, regenerate the structured form, splice back into *just that span* —
;;; the rest of the file stays byte-for-byte identical.
;;;
;;;   ls    list `data' keys                             (no decrypt)
;;;   get   decrypt, print one value
;;;   set   decrypt, add/replace a key, re-seal, splice
;;;   edit  decrypt one value into $EDITOR, re-seal on change, splice
;;;   rm    decrypt, drop a key, re-seal, splice
;;;   rekey decrypt, re-seal to current .sops.yaml recipients, splice
;;;   init  splice an empty `(secrets-store (data))' form
;;;
;;; Re-sealing re-encrypts the whole map afresh (one sops doc, one data key,
;;; one MAC), so a verb never needs prior metadata — just the decrypted values
;;; plus a `.sops.yaml' creation rule.

(define-module (hexol secret-tool)
  #:use-module (hexol secrets)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:export (secret-ls secret-get secret-set secret-edit secret-edit-all
            secret-rm secret-rekey secret-init))

;; ---------- clause accessors (a store form's cdr is an alist) ----------

(define (clause-tail clauses tag)
  (let ((c (assq tag clauses))) (and c (cdr c))))
(define (clause-val clauses tag)
  (let ((c (assq tag clauses))) (and c (pair? (cdr c)) (cadr c))))
(define (store-data clauses) (or (clause-tail clauses 'data) '()))
(define (store-keys clauses) (map (lambda (kv) (car kv)) (store-data clauses)))

;; Raise in the (scm-error) shape bin/hexol's reporter formats cleanly:
;; ~a/~p holes in FMT filled with ARGS.
(define (fail fmt . args)
  (scm-error 'misc-error #f fmt args #f))

;; ---------- position-aware reader ----------
;;
;; Read top-level forms; on the `(secrets-store …)' one, return its parsed
;; clauses plus the [start,end) span, so a mutated form splices back over it.
;;
;; Offsets are *byte* offsets into the file's UTF-8 — `ftell' reports bytes,
;; so multibyte chars (the `—' em-dashes) would desync a char-indexed splice.
;; We keep the file as a bytevector, scan/splice on bytes, decode to a string
;; only for `read'. `read' reports the offset just past a form (end); the
;; matching `(' is the first paren at/after the previous end (start), skipping
;; whitespace and `;'/`#| |#' comments between forms (all ASCII).

(define (slurp-bytes path)
  (call-with-input-file path get-bytevector-all #:binary #t))

(define (subbv bv s e)
  (let ((r (make-bytevector (- e s))))
    (bytevector-copy! bv s r 0 (- e s))
    r))

(define b/lparen 40) (define b/semi 59) (define b/hash 35)
(define b/bar 124)   (define b/nl 10)

;; From byte I in BV, skip whitespace/comments; return the byte index of the
;; next `(' (start of the upcoming form).
(define (scan-to-open bv i)
  (let ((n (bytevector-length bv)))
    (let loop ((i i))
      (if (>= i n)
          (fail "store form vanished while scanning (file changed?)")
          (let ((c (bytevector-u8-ref bv i)))
            (cond
              ((= c b/lparen) i)
              ((memv c '(32 9 10 13 12)) (loop (+ i 1)))   ; whitespace
              ((= c b/semi)                                 ; ; line comment
               (let nl ((j i))
                 (cond ((>= j n) n)
                       ((= (bytevector-u8-ref bv j) b/nl) (loop (+ j 1)))
                       (else (nl (+ j 1))))))
              ((and (= c b/hash) (< (+ i 1) n)              ; #| block |#
                    (= (bytevector-u8-ref bv (+ i 1)) b/bar))
               (let bk ((j (+ i 2)))
                 (cond ((>= (+ j 1) n) n)
                       ((and (= (bytevector-u8-ref bv j) b/bar)
                             (= (bytevector-u8-ref bv (+ j 1)) b/hash))
                        (loop (+ j 2)))
                       (else (bk (+ j 1))))))
              (else (fail "unexpected text before store form at byte ~a" i))))))))

;; Find the `(secrets-store …)' form: (values CLAUSES START END BV), or
;; (values #f #f #f BV) if none. START/END are byte offsets.
(define (find-store-form path)
  (let* ((bv   (slurp-bytes path))
         (port (open-input-string (utf8->string bv))))
    (let loop ()
      (let ((before (ftell port))
            (form   (read port)))
        (cond
          ((eof-object? form) (values #f #f #f bv))
          ((and (pair? form) (eq? (car form) 'secrets-store))
           (values (cdr form) (scan-to-open bv before) (ftell port) bv))
          (else (loop)))))))

(define (require-store path)
  (call-with-values (lambda () (find-store-form path))
    (lambda (clauses start end bv)
      (unless clauses
        (fail "no (secrets-store …) form in ~a — run `hexol secret init` first" path))
      (values clauses start end bv))))

;; ---------- decrypt / plaintext ----------

;; Plaintext map ((kstr . value) …). Empty `data' means never sealed (e.g.
;; just `init'd) — no sops call, just '().
(define (load-plaintext clauses)
  (if (null? (store-data clauses))
      '()
      (or (decrypt-yaml (clauses->sops-yaml clauses))
          (fail "could not decrypt the store (is your key available?)"))))

;; ---------- sealing (mutate → fresh sops doc → structured clauses) ----------

;; Search upward from the inventory's dir for the `.sops.yaml' carrying the
;; creation rule (recipients + encrypted_regex) to seal with.
(define (find-sops-config inv)
  (let loop ((dir (dirname (canonicalize-path inv))))
    (let ((cand (string-append dir "/.sops.yaml")))
      (cond
        ((file-exists? cand) cand)
        ((string=? dir "/")
         (fail "no .sops.yaml found above ~a — needed for the creation rule" inv))
        (else (loop (dirname dir)))))))

(define (mk-seal-dir) (mkdtemp "/tmp/hexol-seal-XXXXXX"))

;; Encrypt PLAIN ((kstr . val) …) into fresh structured store clauses via the
;; creation rule in SOPS-CONFIG. An empty map seals to `((data))'.
(define (seal-data plain sops-config)
  (if (null? plain)
      '((data))
      (let* ((sops (or (which-cmd "sops") (fail "sops not on PATH")))
             (dir  (mk-seal-dir))
             (file (string-append dir "/store.sops.yaml"))
             ;; Sort in the same order `clauses->sops-yaml' feeds sops at
             ;; decrypt: the MAC covers data values in tree order, so the two
             ;; orders must agree or decrypt fails with a MAC mismatch.
             (sorted (sort plain (lambda (a b) (string<? (car a) (car b)))))
             (json (scm->json-string (list (cons "data" sorted)))))
        (call-with-output-file file (lambda (p) (display json p)))
        (let* ((cmd (format #f "~a -e --config ~a --input-type json --output-type json ~a"
                            sops sops-config file))
               (in     (open-input-pipe cmd))
               (output (get-string-all in))
               (status (close-pipe in)))
          (delete-file file)
          (rmdir dir)
          (unless (zero? (status:exit-val status))
            (fail "sops -e failed (check the .sops.yaml creation rule)"))
          (json->clauses (json-string->scm output))))))

(define (lines-of s) (if (string? s) (string-split s #\newline) '()))

;; sops emits the recipient id under varying field names; keep only the
;; load-bearing ones, dropping any the encrypt left empty.
(define (pgp-entry->clause e)
  `(pgp ,@(filter identity
            (list (let ((fp (assoc-ref e "fp")))
                    (and fp `(fp ,fp)))
                  (let ((c (assoc-ref e "created_at")))
                    (and c `(created-at ,c)))
                  `(enc ,@(lines-of (assoc-ref e "enc")))))))

(define (age-entry->clause e)
  `(age (recipient ,(assoc-ref e "recipient"))
        (enc ,@(lines-of (assoc-ref e "enc")))))

(define (vec->list x) (if (vector? x) (vector->list x) '()))

;; sops' encrypted JSON ({data, sops}) → structured store clauses.
(define (json->clauses parsed)
  (let* ((data (or (assoc-ref parsed "data") '()))
         (sops (or (assoc-ref parsed "sops") '()))
         (pgp  (vec->list (assoc-ref sops "pgp")))
         (age  (vec->list (assoc-ref sops "age"))))
    (for-each
     (lambda (k)
       (when (pair? (vec->list (assoc-ref sops k)))
         (fail "unsupported recipient type `~a' in the sealed store" k)))
     '("kms" "gcp_kms" "azure_kv" "hc_vault"))
    `((version      ,(assoc-ref sops "version"))
      (lastmodified ,(assoc-ref sops "lastmodified"))
      (mac          ,(assoc-ref sops "mac"))
      (keys ,@(append (map pgp-entry->clause pgp)
                      (map age-entry->clause age)))
      (data ,@(map (lambda (kv) (cons (string->symbol (car kv)) (cdr kv)))
                   data)))))

;; ---------- emit the structured (secrets-store …) form ----------

(define (sym->text s) (call-with-output-string (lambda (p) (write s p))))

(define (emit-enc p lines)
  (format p "      (enc")
  (if (null? lines)
      (format p ")~%")
      (begin (newline p)
             (let loop ((ls lines))
               (format p "        ~s" (car ls))
               (if (null? (cdr ls))
                   (format p ")~%")
                   (begin (newline p) (loop (cdr ls))))))))

(define (emit-recipient p tag body)
  (format p "    (~a~%" tag)
  (let ((rest (filter (lambda (f) (not (eq? (car f) 'enc))) body))
        (enc  (assq 'enc body)))
    (for-each (lambda (f) (format p "      (~a ~s)~%" (car f) (cadr f))) rest)
    (emit-enc p (if enc (cdr enc) '()))
    (format p "      )")))     ; close recipient

(define (emit-store-form clauses)
  (call-with-output-string
   (lambda (p)
     (let ((ver  (clause-val clauses 'version))
           (lm   (clause-val clauses 'lastmodified))
           (mac  (clause-val clauses 'mac))
           (keys (or (clause-tail clauses 'keys) '()))
           (data (sort (store-data clauses)
                       (lambda (a b)
                         (string<? (symbol->string (car a))
                                   (symbol->string (car b)))))))
       (format p "(secrets-store~%")
       (when ver (format p "  (version ~s)~%" ver))
       (when lm  (format p "  (lastmodified ~s)~%" lm))
       (when mac (format p "  (mac ~s)~%" mac))
       (unless (null? keys)
         (format p "  (keys~%")
         (let loop ((ks keys))
           (let ((k (car ks)))
             (emit-recipient p (car k) (cdr k))
             (if (null? (cdr ks))
                 (format p ")~%")        ; close keys
                 (begin (newline p) (loop (cdr ks)))))))
       (format p "  (data")
       (if (null? data)
           (format p ")"))
       (unless (null? data)
         (newline p)
         (let loop ((ds data))
           (let ((kv (car ds)))
             (format p "    (~a . ~s)" (sym->text (car kv)) (cdr kv))
             (if (null? (cdr ds))
                 (format p ")")          ; close data
                 (begin (newline p) (loop (cdr ds)))))))
       (format p ")")))))                ; close secrets-store

;; ---------- splice ----------

;; Replace bytes [START,END) with NEW-FORM (a string), leaving the rest of
;; the file untouched.
(define (splice-store! path start end new-form)
  (let ((bv (slurp-bytes path)))
    (call-with-output-file path
      (lambda (p)
        (put-bytevector p (subbv bv 0 start))
        (put-bytevector p (string->utf8 new-form))
        (put-bytevector p (subbv bv end (bytevector-length bv))))
      #:binary #t)))

;; Re-seal PLAIN and write the regenerated form over [START,END).
(define (reseal! path start end plain)
  (let* ((cfg     (find-sops-config path))
         (clauses (seal-data plain cfg)))
    (splice-store! path start end (emit-store-form clauses))
    clauses))

;; ---------- the verbs ----------

(define (secret-ls path)
  (call-with-values (lambda () (require-store path))
    (lambda (clauses start end text)
      (let ((keys (store-keys clauses)))
        (for-each (lambda (k) (format #t "~a~%" k)) keys)
        (let ((kinds (map car (or (clause-tail clauses 'keys) '()))))
          (format #t ";; ~a secret~p~@[ · sealed ~a~]~@[ · recipients: ~a~]~%"
                  (length keys) (length keys)
                  (clause-val clauses 'lastmodified)
                  (and (pair? kinds)
                       (string-join (map symbol->string kinds) ", "))))))))

(define (secret-get path key)
  (call-with-values (lambda () (require-store path))
    (lambda (clauses start end text)
      (let* ((plain (load-plaintext clauses))
             (entry (assoc (symbol->string key) plain)))
        (unless entry (fail "no such key: ~a" key))
        (display (cdr entry))
        (newline)))))

;; VALUE is a string, or #f to read the value from stdin.
(define (secret-set path key value)
  (call-with-values (lambda () (require-store path))
    (lambda (clauses start end text)
      (let* ((v     (or value (string-trim-right (get-string-all (current-input-port)) #\newline)))
             (plain (load-plaintext clauses))
             (kstr  (symbol->string key))
             (next  (assoc-set! (alist-copy plain) kstr v)))
        (reseal! path start end next)
        (format (current-error-port) "✓ sealed ~a secret~p → ~a~%"
                (length next) (length next) path)))))

(define (secret-rm path key)
  (call-with-values (lambda () (require-store path))
    (lambda (clauses start end text)
      (let* ((kstr  (symbol->string key))
             (plain (load-plaintext clauses)))
        (unless (assoc kstr plain) (fail "no such key: ~a" key))
        (let ((next (alist-delete kstr (alist-copy plain))))
          (reseal! path start end next)
          (format (current-error-port) "✓ removed ~a — sealed ~a secret~p → ~a~%"
                  key (length next) (length next) path))))))

(define (secret-edit path key)
  (call-with-values (lambda () (require-store path))
    (lambda (clauses start end text)
      (let* ((kstr  (symbol->string key))
             (plain (load-plaintext clauses))
             (cur   (let ((e (assoc kstr plain))) (if e (cdr e) "")))
             (editor (or (getenv "EDITOR") "vi"))
             (tmpl  (string-copy "/tmp/hexol-edit-XXXXXX"))
             (tp    (mkstemp! tmpl)))
        (display cur tp)
        (close-port tp)
        (let ((status (system (string-append editor " " tmpl))))
          (unless (zero? (status:exit-val status))
            (delete-file tmpl)
            (fail "$EDITOR exited non-zero — leaving the store unchanged")))
        (let ((new (string-trim-right (call-with-input-file tmpl get-string-all) #\newline)))
          (delete-file tmpl)
          (cond
            ((string=? new cur)
             (format (current-error-port) ";; ~a unchanged — nothing to seal~%" key))
            (else
             (let ((next (assoc-set! (alist-copy plain) kstr new)))
               (reseal! path start end next)
               (format (current-error-port) "✓ updated ~a — sealed ~a secret~p → ~a~%"
                       key (length next) (length next) path)))))))))

;; ---------- whole-store edit (the decrypted alist in $EDITOR) ----------
;;
;; `edit` with no KEY opens the *entire* decrypted store as one editable
;; alist of (KEY . "VALUE") — add/remove/change keys, then save to re-encrypt
;; the whole thing. The plaintext counterpart of the sealed `(data …)' clause.
;; Comments ignored; values are Scheme strings, so a multi-line secret
;; round-trips as "line1\nline2". Plaintext lives only in a 0600 temp file
;; deleted the moment the editor exits — same exposure as single-key `edit`.

;; Render PLAIN ((kstr . val) …) as editable alist text, keys sorted for
;; stable diffs. Keys print as symbols, values via ~s, so it reads back
;; unambiguously even for `/`-bearing keys or odd chars.
(define (render-plain-sexp plain)
  (let ((sorted (sort plain (lambda (a b) (string<? (car a) (car b))))))
    (call-with-output-string
     (lambda (p)
       (format p ";;; hexol secret edit — the decrypted store as an editable alist.~%")
       (format p ";;;~%")
       (format p ";;; Each entry is (KEY . \"VALUE\"): KEY a symbol, VALUE a string.~%")
       (format p ";;; Add, remove, or change entries freely, then save — the whole~%")
       (format p ";;; store is re-encrypted from exactly what you leave below. These~%")
       (format p ";;; comment lines are ignored. This file is plaintext on disk and is~%")
       (format p ";;; deleted the moment the editor exits.~%")
       (if (null? sorted)
           (format p "()~%")
           (begin
             (format p "(~%")
             (for-each (lambda (kv)
                         (format p "  (~s . ~s)~%" (string->symbol (car kv)) (cdr kv)))
                       sorted)
             (format p ")~%")))))))

;; Parse edited alist text back into a plaintext map ((kstr . val) …),
;; validating shape and rejecting duplicate keys (last-wins would silently
;; drop a secret).
(define (parse-plain-sexp text)
  (let* ((port (open-input-string text))
         (form (read port)))
    (when (eof-object? form)
      (fail "the edited store is empty — expected a list of (KEY . \"VALUE\") pairs"))
    (unless (list? form)
      (fail "the edited store must be a list of (KEY . \"VALUE\") pairs, got ~s" form))
    (let ((extra (read port)))
      (unless (eof-object? extra)
        (fail "unexpected extra form after the store alist: ~s" extra)))
    (let ((pairs (map (lambda (e)
                        (unless (and (pair? e) (symbol? (car e)) (string? (cdr e)))
                          (fail "bad entry ~s — each must be (SYMBOL . \"STRING\")" e))
                        (cons (symbol->string (car e)) (cdr e)))
                      form)))
      (let ((ks (map car pairs)))
        (unless (= (length ks) (length (delete-duplicates ks string=?)))
          (fail "duplicate key in the edited store — keys must be unique")))
      pairs)))

(define (secret-edit-all path)
  (call-with-values (lambda () (require-store path))
    (lambda (clauses start end text)
      (let* ((plain  (load-plaintext clauses))
             (editor (or (getenv "EDITOR") "vi"))
             (tmpl   (string-copy "/tmp/hexol-edit-XXXXXX"))
             (tp     (mkstemp! tmpl)))
        (display (render-plain-sexp plain) tp)
        (close-port tp)
        (let ((status (system (string-append editor " " tmpl))))
          (unless (zero? (status:exit-val status))
            (delete-file tmpl)
            (fail "$EDITOR exited non-zero — leaving the store unchanged")))
        (let ((new-text (call-with-input-file tmpl get-string-all)))
          (delete-file tmpl)                       ; plaintext off disk before parsing
          (let* ((next (parse-plain-sexp new-text))
                 (norm (lambda (m) (sort (map (lambda (kv) (cons (car kv) (cdr kv))) m)
                                         (lambda (a b) (string<? (car a) (car b)))))))
            (cond
              ((equal? (norm next) (norm plain))
               (format (current-error-port) ";; store unchanged — nothing to seal~%"))
              (else
               (reseal! path start end next)
               (format (current-error-port) "✓ sealed ~a secret~p → ~a~%"
                       (length next) (length next) path)))))))))

(define (secret-rekey path)
  (call-with-values (lambda () (require-store path))
    (lambda (clauses start end text)
      (let ((plain (load-plaintext clauses)))
        (reseal! path start end plain)
        (format (current-error-port) "✓ rekeyed ~a secret~p to ~a → ~a~%"
                (length plain) (length plain) (find-sops-config path) path)))))

;; Insert an empty store form; refuses if one exists. Spliced just before the
;; inventory's final top-level form (typically the `(hx-ops …)' the secret-refs
;; feed), so a later `set' has somewhere to land.
(define (secret-init path)
  (call-with-values (lambda () (find-store-form path))
    (lambda (existing s e bv)
      (when existing (fail "~a already has a (secrets-store …) form" path))
      (let ((at (last-form-start bv)))
        (call-with-output-file path
          (lambda (p)
            (put-bytevector p (subbv bv 0 at))
            (put-bytevector p (string->utf8 "(secrets-store\n  (data))\n\n"))
            (put-bytevector p (subbv bv at (bytevector-length bv))))
          #:binary #t)
        (format (current-error-port)
                "✓ inserted an empty (secrets-store …) — add secrets with `hexol secret set`~%")))))

;; Byte offset of the last top-level form's `(' — where `init' inserts.
(define (last-form-start bv)
  (let ((port (open-input-string (utf8->string bv))))
    (let loop ((last 0))
      (let ((before (ftell port))
            (form   (read port)))
        (if (eof-object? form)
            (scan-to-open bv last)
            (loop before))))))
