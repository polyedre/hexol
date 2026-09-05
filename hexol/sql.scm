;;; hexol/sql.scm — the SQL-schema target library.
;;;
;;; SQL-DDL vocabulary (tables, columns, types, constraints, indexes), the
;;; way (hexol terraform) is Terraform vocabulary. Domain-agnostic; the
;;; actual schema lives in the consuming example
;;; (examples/database-schema.scm).
;;;
;;; Every builder is an *op*, like a `terraform-resource` or k8s `resource`.
;;; `table` / `index` render their `CREATE …` at build time into an op that
;;; appends to the `(sql_commands)` accumulator, so resolving the inventory
;;; *is* the build. `tree` / `ops` / `explain` and `render -o sexp | json |
;;; yaml` work generically; `render -o sql` runs `render-sql` (registered
;;; via `renders-with`) to emit runnable DDL.
;;;
;;;   (hx-ops
;;;     (table 'users (id) (text 'email #:unique #t))
;;;     (index 'users '(email) #:unique #t))
;;;     => state with (sql_commands ("CREATE TABLE users (…);" "CREATE …;"))
;;;
;;; Authoring surface:
;;;
;;; - `table`: name then a mix of column builders and table-level
;;;   constraints (all values, so `map`/`if`/helpers work). Flattens one
;;;   level — an item may be a column or a list of them — no `apply` needed.
;;;
;;; - Type sugar (`id`, `text`, `integer`, `boolean`, `timestamp`,
;;;   `varchar`, `numeric`, `references`) wraps the generic `column`, fixing
;;;   TYPE and forwarding `#:not-null / #:unique / #:primary-key / #:default
;;;   / #:check`.
;;;
;;; - `with-schema` bakes a namespace into table/index names at construction
;;;   time (like `with-namespace` in (hexol k8s)), then bundles into one op.

(define-module (hexol sql)
  #:use-module (hexol kernel)
  #:use-module (hexol construct)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:re-export (define-construct construct-map-entries construct-flag)
  #:export (;; scope
            with-schema current-sql-schema
            ;; tables + indexes
            table index column
            id text varchar integer bigint boolean
            timestamp date numeric references
            ;; table-level constraints
            primary-key unique foreign-key check
            ;; default-value helper
            raw
            ;; render adapter (state -> writes SQL text)
            render-sql))

;; ---------------------------------------------------------------------------
;; schema scope
;; ---------------------------------------------------------------------------
;;
;; `with-schema` binds `current-sql-schema` at construction time so the
;; qualifier ("public.users") bakes into each statement. Mirrors
;; `with-namespace` in (hexol k8s).

(define current-sql-schema (make-parameter #f))

;; Build-time scope over the kernel's `scope-ops`.
(define-syntax-rule (with-schema name body ...)
  (scope-ops 'with-schema (current-sql-schema name) "schema " body ...))

;; ---------------------------------------------------------------------------
;; raw SQL marker
;; ---------------------------------------------------------------------------
;;
;; Default/check value that passes through verbatim. `(raw "now()")` renders
;; as `now()`, vs. bare "now()" rendering as the literal 'now()'.

(define (raw s) (cons 'raw s))
(define (raw? x) (and (pair? x) (eq? (car x) 'raw)))

;; ---------------------------------------------------------------------------
;; columns (values, not ops)
;; ---------------------------------------------------------------------------
;;
;; A column is (col NAME TYPE OPTS), OPTS the keyword-flag alist. `column`
;; is generic; the sugar below fixes TYPE.

(define* (column name type
                 #:key (primary-key #f) (not-null #f) (unique #f)
                       (default 'none) (references #f) (check #f))
  (list 'col name type
        `((primary-key . ,primary-key)
          (not-null    . ,not-null)
          (unique      . ,unique)
          (default     . ,default)
          (references  . ,references)
          (check       . ,check))))

;; Each sugar is a value-returning `define-construct`: positional name, then
;; valueless boolean flags — `(text 'email (not-null) (unique))` — plus
;; `(default …)` / `(check …)` value entries. Keeps the `#:`-surface's
;; defaults and unknown-key errors while reading like the other libraries.
(define-syntax-rule (define-type-sugar (name type) ...)
  (begin
    (define-construct name
      #:head (col-name)
      #:value                       ; a column value, consumed by `table'
      #:fields ((primary-key #:flag) (not-null #:flag) (unique #:flag)
                (default #:default 'none) (check #:default #f) (references #:default #f))
      #:build (column col-name type
                      #:primary-key primary-key #:not-null not-null
                      #:unique unique #:default default
                      #:references references #:check check))
    ...))

(define-type-sugar
  (text      "TEXT")
  (integer   "INTEGER")
  (bigint    "BIGINT")
  (boolean   "BOOLEAN")
  (timestamp "TIMESTAMP")
  (date      "DATE"))

;; `id`: the surrogate key `SERIAL PRIMARY KEY`. Plain optional-positional
;; procedure — `(id)` / `(id 'pk)` — no flags to carry.
(define* (id #:optional (name 'id))
  (column name "SERIAL" #:primary-key #t))

;; Parametric types take their argument(s) as extra positional head params.
(define-construct varchar
  #:head (name n)
  #:value
  #:fields ((not-null #:flag) (unique #:flag) (default #:default 'none) (check #:default #f))
  #:build (column name (format #f "VARCHAR(~a)" n)
                  #:not-null not-null #:unique unique
                  #:default default #:check check))

(define-construct numeric
  #:head (name precision scale)
  #:value
  #:fields ((not-null #:flag) (default #:default 'none) (check #:default #f))
  #:build (column name (format #f "NUMERIC(~a, ~a)" precision scale)
                  #:not-null not-null #:default default #:check check))

;; FK column. `(references 'author_id 'users)` makes an INTEGER column
;; referencing users(id); `(on …)` overrides the target column. Not-null by
;; default (dangling FK is usually a bug); opt out via `(nullable)`.
(define-construct references
  #:head (name target)
  #:value
  #:fields ((on #:default 'id) (unique #:flag) (default #:default 'none) (nullable #:flag))
  #:build (column name "INTEGER"
                  #:not-null (not nullable) #:unique unique #:default default
                  #:references (cons target on)))

;; ---------------------------------------------------------------------------
;; table-level constraints (values, not ops)
;; ---------------------------------------------------------------------------
;;
;; `table` items that are constraints, not columns. Tagged `tbl-constraint`
;; with their pre-rendered SQL fragment.

(define (col-list cols)
  (string-join (map symbol->string cols) ", "))

(define (primary-key . cols)
  (list 'tbl-constraint (format #f "PRIMARY KEY (~a)" (col-list cols))))

(define (unique . cols)
  (list 'tbl-constraint (format #f "UNIQUE (~a)" (col-list cols))))

(define* (foreign-key cols target #:optional (target-cols '(id)))
  (list 'tbl-constraint
        (format #f "FOREIGN KEY (~a) REFERENCES ~a (~a)"
                (col-list cols) target (col-list target-cols))))

(define (check expr)
  ;; `expr`: raw SQL boolean string.
  (list 'tbl-constraint (format #f "CHECK (~a)" expr)))

;; ---------------------------------------------------------------------------
;; value / column / statement rendering (build time)
;; ---------------------------------------------------------------------------

(define (qualify name)
  (let ((schema (current-sql-schema)))
    (if schema (format #f "~a.~a" schema name) (format #f "~a" name))))

(define (sql-value v)
  (cond ((raw? v)     (cdr v))
        ((string? v)  (format #f "'~a'" (escape-quotes v)))
        ((boolean? v) (if v "TRUE" "FALSE"))
        ((number? v)  (number->string v))
        ((symbol? v)  (symbol->string v))   ; e.g. CURRENT_TIMESTAMP
        (else (format #f "~a" v))))

(define (escape-quotes s)
  (string-join (string-split s #\') "''"))

(define (opt opts k) (assq-ref opts k))

(define (render-column c)
  ;; (col NAME TYPE OPTS) -> "name TYPE [modifiers...]"
  (let* ((name (cadr c))
         (type (caddr c))
         (opts (cadddr c))
         (refs (opt opts 'references))
         (def  (opt opts 'default))
         (chk  (opt opts 'check))
         (parts
          (filter
           (lambda (s) (not (string-null? s)))
           (list
            (format #f "~a ~a" name type)
            (if (opt opts 'primary-key) "PRIMARY KEY" "")
            (if (opt opts 'not-null) "NOT NULL" "")
            (if (opt opts 'unique) "UNIQUE" "")
            (if (eq? def 'none) "" (format #f "DEFAULT ~a" (sql-value def)))
            (if chk (format #f "CHECK (~a)" chk) "")
            (if refs
                (format #f "REFERENCES ~a (~a)" (car refs) (cdr refs))
                "")))))
    (string-join parts " ")))

;; Flatten one level: an item may be a single column/constraint or a bundle
;; (e.g. `audit-columns`). A tagged list headed by 'col / 'tbl-constraint is
;; a single item; anything else is a bundle to splice. Same flattening
;; `hx-ops` does for ops, so no `(apply table …)` needed.
(define (flatten-items items)
  (append-map (lambda (x)
                (if (and (pair? x) (symbol? (car x))) (list x) x))
              items))

(define (render-create-table name items)
  (let* ((items   (flatten-items items))
         (cols    (filter (lambda (x) (eq? (car x) 'col)) items))
         (constrs (filter (lambda (x) (eq? (car x) 'tbl-constraint)) items))
         (lines   (append (map render-column cols)
                          (map cadr constrs))))
    (string-append
     (format #f "CREATE TABLE ~a (\n" (qualify name))
     (string-join (map (lambda (l) (string-append "  " l)) lines) ",\n")
     "\n);")))

(define* (render-create-index table-name cols #:key (unique #f) (name #f))
  (let ((iname (or name
                   (format #f "idx_~a_~a" table-name
                           (string-join (map symbol->string cols) "_")))))
    (format #f "CREATE ~aINDEX ~a ON ~a (~a);"
            (if unique "UNIQUE " "")
            iname (qualify table-name) (col-list cols))))

;; ---------------------------------------------------------------------------
;; the ops
;; ---------------------------------------------------------------------------
;;
;; Each builder renders now (capturing the schema scope) and returns an op
;; appending the string to `(sql_commands)`. We override op:append's generic
;; label with the statement's identity, like terraform's `block-op`.

(define (sql-command-op command source label)
  (relabel (op:append '(sql_commands) command source) label))

(define (table name . items)
  (sql-command-op (render-create-table name items)
                  (list 'table name)
                  (string-append "table " (symbol->string name))))

(define* (index table-name cols #:key (unique #f) (name #f))
  (sql-command-op (render-create-index table-name cols #:unique unique #:name name)
                  (list 'index table-name)
                  (string-append "index " (symbol->string table-name))))

;; ---------------------------------------------------------------------------
;; render adapter
;; ---------------------------------------------------------------------------
;;
;; (state -> writes text). Registered via `(renders-with "sql" render-sql)`,
;; so `hexol render -o sql` prints the statements as DDL, one per stanza.

(define (render-sql state)
  (for-each (lambda (cmd) (display cmd) (newline) (newline))
            (or (state-get state '(sql_commands)) '())))
