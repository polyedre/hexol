;;; hexol/doc.scm — `hexol doc`: render the define-construct schema registry.
;;;
;;; Authors shouldn't have to read k8s.scm to learn which `(key value)` entries
;;; `(app …)` accepts. `define-construct` already records every construct's
;;; schema in (hexol construct)'s registry at definition time; this module only
;;; formats it: an index (one line per construct) or one construct's signature,
;;; fields table and a minimal example built from its required fields.

(define-module (hexol doc)
  #:use-module (hexol construct)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (print-construct-index print-construct-doc))

;; A datum as the author wrote it: `(quote x)` back to `'x`.
(define (datum->string d)
  (if (and (pair? d) (eq? (car d) 'quote) (pair? (cdr d)) (null? (cddr d)))
      (string-append "'" (datum->string (cadr d)))
      (format #f "~s" d)))

(define (module->string m) (format #f "~a" m))

;; The "kind" column: what the field needs / how it reads.
(define (field-shape f)
  (let ((kind (assq-ref f 'kind)) (default (assq-ref f 'default)))
    (cond
      ((assq-ref f 'required?) "required")
      ((eq? kind 'flag)        "flag")
      ((eq? kind 'list)        (if default (format #f "list, default ~a" (datum->string default)) "list"))
      ((eq? kind 'map)         "map")
      ((eq? kind 'construct)   (format #f "~a(~a …)" (if (assq-ref f 'repeated?) "repeated " "")
                                       (assq-ref f 'construct)))
      (default                 (format #f "default ~a" (datum->string default)))
      (else                    "optional"))))

;; How one entry for F reads in a call: `(image …)`, `(debug)`, `(env …)`.
(define (field-form f)
  (let ((n (assq-ref f 'name)))
    (case (assq-ref f 'kind)
      ((flag) (format #f "(~a)" n))
      ((list) (format #f "(~a a b …)" n))
      ((map)  (format #f "(~a (k v) …)" n))
      ((construct) (format #f "(~a …)" n))
      (else (format #f "(~a v)" n)))))

(define (head-placeholders s)
  (map (lambda (h) (string-upcase (symbol->string h))) (assq-ref s 'head)))

(define (signature s)
  (format #f "(~a~{ ~a~}~{ ~a~})" (assq-ref s 'name) (head-placeholders s)
          (map field-form (assq-ref s 'fields))))

;; A minimal valid call: every head param as a placeholder, every required
;; field with a placeholder value.
(define (example s)
  (format #f "(~a~{ ~a~}~{ ~a~})" (assq-ref s 'name) (head-placeholders s)
          (map (lambda (f) (format #f "(~a ~a)" (assq-ref f 'name)
                                   (string-upcase (symbol->string (assq-ref f 'name)))))
               (filter (lambda (f) (assq-ref f 'required?)) (assq-ref s 'fields)))))

(define (pad s n) (string-pad-right s (max n (string-length s))))
(define (widest strings) (apply max 0 (map string-length strings)))

;; One line per registered construct: name, module, one-line doc.
(define (print-construct-index)
  (let* ((schemas (construct-schemas))
         (names   (map (lambda (s) (symbol->string (assq-ref s 'name))) schemas))
         (mods    (map (lambda (s) (module->string (assq-ref s 'module))) schemas))
         (w-name  (widest names))
         (w-mod   (widest mods)))
    (for-each (lambda (s name mod)
                (format #t "~a  ~a  ~a~%" (pad name w-name) (pad mod w-mod)
                        (or (assq-ref s 'doc) "")))
              schemas names mods)))

;; Full doc of one schema: signature, head, fields table, example.
(define (print-construct-doc s)
  (let* ((fields  (assq-ref s 'fields))
         (names   (map (lambda (f) (symbol->string (assq-ref f 'name))) fields))
         (shapes  (map field-shape fields))
         (w-name  (widest names))
         (w-shape (widest shapes)))
    (format #t "~a  ~a~%" (assq-ref s 'name) (module->string (assq-ref s 'module)))
    (when (assq-ref s 'doc) (format #t "  ~a~%" (assq-ref s 'doc)))
    (format #t "~%signature:~%  ~a~%" (signature s))
    (format #t "~%head (positional): ~a~%"
            (if (null? (assq-ref s 'head)) "none"
                (string-join (map symbol->string (assq-ref s 'head)) " ")))
    (unless (null? fields)
      (format #t "~%fields:~%")
      (for-each (lambda (f name shape)
                  (format #t "  ~a  ~a  ~a~%" (pad name w-name) (pad shape w-shape)
                          (or (assq-ref f 'doc) "")))
                fields names shapes))
    (format #t "~%example:~%  ~a~%" (example s))))
