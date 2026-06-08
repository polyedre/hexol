;;; hexol/secret-tool.scm — the engine behind `hexol secret …`.
;;;
;;; Every mutating verb is one pipeline: locate the `(secrets-store …)' form
;;; in an inventory file (tracking its exact character span), decrypt it to a
;;; plaintext map, mutate the map, re-seal it with sops, regenerate the
;;; structured Scheme form, and splice the new text back into *just that span*
;;; — the rest of the file stays byte-for-byte identical.
;;;
;;;   ls    parse the form, list `data' keys            (no decrypt)
;;;   get   decrypt, print one value
;;;   set   decrypt, add/replace a key, re-seal, splice
;;;   edit  decrypt one value into $EDITOR, re-seal on change, splice
;;;   rm    decrypt, drop a key, re-seal, splice
;;;   rekey decrypt, re-seal to the current .sops.yaml recipients, splice
;;;   init  splice an empty `(secrets-store (data))' form
;;;
;;; Re-sealing always re-encrypts the whole plaintext map afresh (one sops
;;; doc, one data key, one MAC), so a verb never needs the prior metadata —
;;; it just needs the decrypted values plus a `.sops.yaml' creation rule.

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
  #:export (secret-ls secret-get secret-set secret-edit
            secret-rm secret-rekey secret-init))

;; ---------- clause accessors (a store form's cdr is a plain alist) ----------

(define (clause-tail clauses tag)
  (let ((c (assq tag clauses))) (and c (cdr c))))
(define (clause-val clauses tag)
  (let ((c (assq tag clauses))) (and c (pair? (cdr c)) (cadr c))))
(define (store-data clauses) (or (clause-tail clauses 'data) '()))
(define (store-keys clauses) (map (lambda (kv) (car kv)) (store-data clauses)))

;; Raise in the (scm-error) shape bin/hexol's reporter formats cleanly:
;; the ~a/~p holes in FMT are filled with ARGS.
(define (fail fmt . args)
  (scm-error 'misc-error #f fmt args #f))

;; ---------- position-aware reader ----------
;;
;; Read top-level forms from the file, and when we hit the `(secrets-store …)'
;; one return its parsed clauses plus the [start,end) span it occupies, so a
;; mutated form can be spliced back over exactly that region.
;;
;; All offsets are *byte* offsets into the file's UTF-8 bytes — `ftell' on the
;; reader port reports bytes, not characters, so multibyte characters (the `—'
;; em-dashes in the comments) would desync a char-indexed splice. We keep the
;; file as a bytevector, scan and splice on bytes, and only decode to a string
;; for `read'. `read' reports the offset just past a form (end); the matching
;; `(' is the first paren at/after the previous form's end (start), skipping
;; the whitespace and `;'/`#| |#' comments between forms (all ASCII bytes).

(define (slurp-bytes path)
  (call-with-input-file path get-bytevector-all #:binary #t))

(define (subbv bv s e)
  (let ((r (make-bytevector (- e s))))
    (bytevector-copy! bv s r 0 (- e s))
    r))

(define b/lparen 40) (define b/semi 59) (define b/hash 35)
(define b/bar 124)   (define b/nl 10)

;; From byte I in BV, skip whitespace and comments; return the byte index of
;; the next `(' (the start of the upcoming form).
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
;; (values #f #f #f BV) when there is none. START/END are byte offsets.
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

;; The plaintext map ((kstr . value) …).  An empty `data' clause means the
;; store was never sealed (e.g. just `init'd) — no sops call, just '().
(define (load-plaintext clauses)
  (if (null? (store-data clauses))
      '()
      (or (decrypt-yaml (clauses->sops-yaml clauses))
          (fail "could not decrypt the store (is your key available?)"))))

;; ---------- sealing (mutate → fresh sops doc → structured clauses) ----------

;; Search upward from the inventory's directory for the `.sops.yaml' that
;; carries the creation rule (recipients + encrypted_regex) to seal with.
(define (find-sops-config inv)
  (let loop ((dir (dirname (canonicalize-path inv))))
    (let ((cand (string-append dir "/.sops.yaml")))
      (cond
        ((file-exists? cand) cand)
        ((string=? dir "/")
         (fail "no .sops.yaml found above ~a — needed for the creation rule" inv))
        (else (loop (dirname dir)))))))

(define (mk-seal-dir) (mkdtemp "/tmp/hexol-seal-XXXXXX"))

;; Encrypt the plaintext map PLAIN ((kstr . val) …) into fresh structured
;; store clauses, using the creation rule in SOPS-CONFIG.  An empty map seals
;; to just `((data))' (nothing to encrypt).
(define (seal-data plain sops-config)
  (if (null? plain)
      '((data))
      (let* ((sops (or (which-cmd "sops") (fail "sops not on PATH")))
             (dir  (mk-seal-dir))
             (file (string-append dir "/store.sops.yaml"))
             ;; Seal in the same sorted key order `clauses->sops-yaml' feeds
             ;; sops at decrypt time: the MAC is computed over the data values
             ;; in tree order, so the two orders must agree or decrypt fails
             ;; with a MAC mismatch.
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

;; sops emits the recipient id under different field names; keep only the
;; load-bearing ones, dropping any the encrypt didn't populate.
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

;; Turn sops' encrypted JSON ({data, sops}) into structured store clauses.
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
    (format p "      )")))     ; close the recipient

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
                 (format p ")~%")        ; close (keys …)
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
                 (format p ")")          ; close (data …)
                 (begin (newline p) (loop (cdr ds)))))))
       (format p ")")))))                ; close (secrets-store …)

;; ---------- splice ----------

;; Replace the bytes [START,END) of the file with NEW-FORM (a string), leaving
;; everything outside that span untouched.
(define (splice-store! path start end new-form)
  (let ((bv (slurp-bytes path)))
    (call-with-output-file path
      (lambda (p)
        (put-bytevector p (subbv bv 0 start))
        (put-bytevector p (string->utf8 new-form))
        (put-bytevector p (subbv bv end (bytevector-length bv))))
      #:binary #t)))

;; Re-seal PLAIN and write the regenerated form over the [START,END) span.
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

(define (secret-rekey path)
  (call-with-values (lambda () (require-store path))
    (lambda (clauses start end text)
      (let ((plain (load-plaintext clauses)))
        (reseal! path start end plain)
        (format (current-error-port) "✓ rekeyed ~a secret~p to ~a → ~a~%"
                (length plain) (length plain) (find-sops-config path) path)))))

;; Insert an empty store form.  Refuses if one already exists.  We splice it
;; just before the inventory's final top-level form (typically the `(hx-ops …)'
;; the secret-refs feed into), so a subsequent `set' has somewhere to land.
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

;; Byte offset of the last top-level form's opening `(' — where `init' inserts.
(define (last-form-start bv)
  (let ((port (open-input-string (utf8->string bv))))
    (let loop ((last 0))
      (let ((before (ftell port))
            (form   (read port)))
        (if (eof-object? form)
            (scan-to-open bv last)
            (loop before))))))
