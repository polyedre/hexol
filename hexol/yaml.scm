;;; hexol/yaml.scm — emit resolved state as YAML.
;;;
;;; Resource alists use symbol keys, scalar leaves (string / number / boolean
;;; / symbol), nested alists (maps), and lists (sequences). `object-shape?`
;;; tells map from sequence: a non-empty list whose every element is a
;;; (symbol . X) pair with distinct keys is a map; else a sequence.
;;;
;;;   (emit-yaml-document port obj)   one `--- …` document
;;;   (emit-yaml-stream   port objs)  a `---`-separated multi-doc stream
;;;
;;; The `helm template` back-end for k8s inventories, but format-only —
;;; knows nothing about k8s, renders any state.

(define-module (hexol yaml)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (emit-yaml-document emit-yaml-stream object-shape?))

(define (object-shape? obj)
  "Return #t if OBJ should render as a YAML map: a non-empty list whose
every element is a (symbol . X) pair with distinct keys.  A string key
such as requests.cpu counts too — hand-written and imported alists carry them.
Anything else is treated as a sequence."
  (and (pair? obj)
       (list? obj)
       (every (lambda (e) (and (pair? e) (or (symbol? (car e)) (string? (car e))))) obj)
       (let ((keys (map car obj)))
         (= (length keys) (length (delete-duplicates keys equal?))))))

(define (scalar? x)
  (or (string? x) (number? x) (boolean? x) (symbol? x) (null? x)))

;; YAML 1.1 boolean / null tokens. Downstream parsers (go-yaml, via
;; kubectl/sigs.k8s.io/yaml) coerce these *in any case* — `True`, `Yes`,
;; `Off`, `NULL` — so a string spelling one must be quoted to survive
;; (e.g. a CRD's `enum: ["True","False","Unknown"]`).
(define yaml-reserved-words
  '("true" "false" "null" "yes" "no" "on" "off" "y" "n" "~"))

(define (numeric-looking? s)
  ;; `string->number' RAISES on some numeric spellings (e.g. an out-of-range
  ;; exponent, "266437e999999999"), so guard it; and treat a string built only
  ;; of number characters as numeric anyway, so it still gets quoted rather
  ;; than emitted bare for a YAML parser to coerce.
  (or (false-if-exception (string->number s))
      (and (string-any char-numeric? s)
           (string-every (lambda (c)
                           (or (char-numeric? c)
                               (memv c '(#\+ #\- #\. #\e #\E))))
                         s))))

(define (needs-quote? s)
  ;; Quote when the string could be misread as another YAML type or holds
  ;; structural characters.
  (or (string=? s "")
      (numeric-looking? s)
      (member (string-downcase s) yaml-reserved-words)
      (string-any (lambda (c) (memv c '(#\: #\# #\{ #\} #\[ #\] #\, #\& #\*
                                        #\? #\| #\< #\> #\= #\! #\% #\@ #\` #\"
                                        #\'))) s)
      (char-whitespace? (string-ref s 0))))

(define (escape s)
  (string-concatenate
    (map (lambda (c)
           (cond ((char=? c #\") "\\\"")
                 ((char=? c #\\) "\\\\")
                 (else (string c))))
         (string->list s))))

(define (scalar->yaml x)
  (cond
    ((eq? x #t) "true")
    ((eq? x #f) "false")
    ((null? x)  "{}")                     ; empty map, e.g. serviceMonitorSelector
    ((number? x) (number->string x))
    ((symbol? x) (scalar->yaml (symbol->string x)))
    ((string? x) (if (needs-quote? x)
                     (string-append "\"" (escape x) "\"")
                     x))
    (else (format #f "~a" x))))

(define (key->yaml k) (if (string? k) k (symbol->string k)))
(define (indent n) (make-string n #\space))

;; Multiline string as a YAML block scalar (`|`).
(define (emit-block-string port s pad)
  (display " |\n" port)
  (for-each (lambda (ln)
              (display (indent (+ pad 2)) port)
              (display ln port)
              (newline port))
            (string-split s #\newline)))

;; Emit `obj` as the *value* after a "key:" the caller already printed.
;; `pad` is the key's indentation.
(define (emit-value port obj pad)
  (cond
    ((and (string? obj) (string-index obj #\newline))
     (emit-block-string port obj pad))
    ((scalar? obj)
     (display " " port)
     (display (scalar->yaml obj) port)
     (newline port))
    ((object-shape? obj)
     (newline port)
     (emit-map port obj (+ pad 2)))
    ((pair? obj)                          ; sequence (list)
     (newline port)
     (emit-seq port obj pad))
    (else
     (display " " port)
     (display (scalar->yaml obj) port)
     (newline port))))

(define (emit-map port alist pad)
  (for-each
    (lambda (entry)
      (display (indent pad) port)
      (display (key->yaml (car entry)) port)
      (display ":" port)
      (emit-value port (cdr entry) pad))
    alist))

(define (emit-seq-item port item pad)
  (cond
    ((object-shape? item)
     ;; First key on the dash line, rest indented under it.
     (display (indent pad) port)
     (display "- " port)
     (let ((first (car item)) (rest (cdr item)))
       (display (key->yaml (car first)) port)
       (display ":" port)
       (emit-value port (cdr first) (+ pad 2))
       (emit-map port rest (+ pad 2))))
    ((scalar? item)
     (display (indent pad) port)
     (display "- " port)
     (display (scalar->yaml item) port)
     (newline port))
    ;; Defensive: a one-element-list item (e.g. a hand-authored spec that
    ;; double-wrapped a single map) renders as that entry, not a nested dash.
    ((and (pair? item) (null? (cdr item)))
     (emit-seq-item port (car item) pad))
    (else                                  ; nested sequence
     (display (indent pad) port)
     (display "-" port)
     (emit-value port item (+ pad 2)))))

(define (emit-seq port items pad)
  (for-each (lambda (item) (emit-seq-item port item pad)) items))

;; One YAML document: `---` then the map (or bare scalar/seq).
(define (emit-yaml-document port obj)
  "Write OBJ to PORT as one YAML document: a `---' line followed by the map
(or a bare scalar/sequence)."
  (display "---\n" port)
  (cond
    ((object-shape? obj) (emit-map port obj 0))
    ((scalar? obj) (display (scalar->yaml obj) port) (newline port))
    ((pair? obj) (emit-seq port obj 0))
    (else (display (scalar->yaml obj) port) (newline port))))

;; Multi-document stream: one `--- …` document per element.
(define (emit-yaml-stream port objs)
  "Write OBJS to PORT as a `---'-separated multi-document YAML stream, one
document per element."
  (for-each (lambda (o) (emit-yaml-document port o)) objs))
