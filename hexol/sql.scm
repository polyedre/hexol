;;; hexol/sql.scm — the SQL-schema target library.
;;;
;;; Relational-schema vocabulary, the way (hexol terraform) is Terraform
;;; vocabulary. It knows about *SQL DDL* — tables, columns, types,
;;; constraints, indexes — but nothing domain-specific; the actual schema
;;; (users, posts, …) is content that lives in the example that consumes
;;; this library (examples/database-schema.scm).
;;;
;;; Every builder is an *op*, exactly like a `terraform-resource` or a k8s
;;; `resource`. A `table` / `index` form renders its own `CREATE …`
;;; statement at build time and returns an op whose effect appends that
;;; string to the `(sql_commands)` accumulator. So resolving an inventory
;;; of these ops *is* the build: the resolved state carries the ordered
;;; list of SQL commands. `tree` / `ops` / `explain` and `render -o sexp |
;;; json | yaml` all work on that state generically; `render -o sql` runs
;;; `render-sql` (registered by the file via `renders-with`) to print the
;;; statements as runnable DDL.
;;;
;;;   (hx-ops
;;;     (table 'users (id) (text 'email #:unique #t))
;;;     (index 'users '(email) #:unique #t))
;;;     => state with (sql_commands ("CREATE TABLE users (…);" "CREATE …;"))
;;;
;;; Authoring surface:
;;;
;;; - `table` takes a name then a mix of column builders and table-level
;;;   constraints. Columns are values (so `map` / `if` / helper functions
;;;   work). It flattens one level, so an item may be a single column or a
;;;   list of them (a reusable bundle) — no `apply` needed.
;;;
;;; - Column type sugar (`id`, `text`, `integer`, `boolean`, `timestamp`,
;;;   `varchar`, `numeric`, `references`) are thin wrappers over the
;;;   generic `column`; each fixes the SQL type and forwards the shared
;;;   `#:not-null / #:unique / #:primary-key / #:default / #:check` keywords.
;;;
;;; - `with-schema` bakes a namespace into the table/index names while
;;;   their ops are *constructed* — the same build-time scope mechanism as
;;;   `with-namespace` in (hexol k8s) — then bundles them into one op.

(define-module (hexol sql)
  #:use-module (hexol kernel)
  #:use-module (hexol construct)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
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
;; `with-schema` binds `current-sql-schema` while the body's ops are
;; constructed, so the schema qualifier ("public.users") bakes into each
;; rendered statement, then bundles them into one op. Mirrors
;; `with-namespace` in (hexol k8s).

(define current-sql-schema (make-parameter #f))

;; Build-time scope over the kernel's `scope-ops`: bind the schema while the
;; body's table/index ops are constructed, then bundle them into one op.
(define-syntax-rule (with-schema name body ...)
  (scope-ops 'with-schema (current-sql-schema name) "schema " body ...))

;; ---------------------------------------------------------------------------
;; raw SQL marker
;; ---------------------------------------------------------------------------
;;
;; A default value (or check expression) that must pass through verbatim —
;; a function call or a server keyword. `(raw "now()")` renders as `now()`,
;; where the bare string "now()" would render as the quoted literal
;; 'now()'.

(define (raw s) (cons 'raw s))
(define (raw? x) (and (pair? x) (eq? (car x) 'raw)))

;; ---------------------------------------------------------------------------
;; columns (values, not ops)
;; ---------------------------------------------------------------------------
;;
;; A column is (col NAME TYPE OPTS), OPTS an alist of the keyword flags.
;; `column` is the generic constructor; the sugar below fixes TYPE.

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

;; Each sugar is a value-returning `define-construct`: a positional column
;; name, then boolean flags written valuelessly — `(text 'email (not-null)
;; (unique))` — plus `(default …)` / `(check …)` value entries. The schema
;; recovers what the `#:`-keyword surface gave (defaults, unknown-key errors)
;; while reading like the rest of the libraries.
(define-syntax-rule (define-type-sugar (name type) ...)
  (begin
    (define-construct name
      #:head (col-name)
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

;; `id` is the near-universal surrogate key: `SERIAL PRIMARY KEY`. It stays a
;; plain (optional-positional) procedure — `(id)` / `(id 'pk)` — since it
;; carries no flags and the optional name reads best positionally.
(define* (id #:optional (name 'id))
  (column name "SERIAL" #:primary-key #t))

;; Parametric types take their argument(s) as extra positional head params.
(define-construct varchar
  #:head (name n)
  #:fields ((not-null #:flag) (unique #:flag) (default #:default 'none) (check #:default #f))
  #:build (column name (format #f "VARCHAR(~a)" n)
                  #:not-null not-null #:unique unique
                  #:default default #:check check))

(define-construct numeric
  #:head (name precision scale)
  #:fields ((not-null #:flag) (default #:default 'none) (check #:default #f))
  #:build (column name (format #f "NUMERIC(~a, ~a)" precision scale)
                  #:not-null not-null #:default default #:check check))

;; A foreign-key column. `(references 'author_id 'users)` makes an INTEGER
;; column referencing users(id); `(on …)` overrides the target column.
;; Not-null by default — a dangling FK is usually a bug — so opt out with the
;; `(nullable)` flag rather than a not-null default.
(define-construct references
  #:head (name target)
  #:fields ((on #:default 'id) (unique #:flag) (default #:default 'none) (nullable #:flag))
  #:build (column name "INTEGER"
                  #:not-null (not nullable) #:unique unique #:default default
                  #:references (cons target on)))

;; ---------------------------------------------------------------------------
;; table-level constraints (values, not ops)
;; ---------------------------------------------------------------------------
;;
;; Items in a `table` that are constraints rather than columns. Tagged
;; `tbl-constraint` with their already-rendered SQL fragment.

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
  ;; `expr` is a raw SQL boolean string.
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
  ;; c = (col NAME TYPE OPTS) -> "name TYPE [modifiers...]"
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

;; Flatten one level, so an item may be a single column/constraint *or* a
;; list of them (a reusable bundle like `audit-columns`). A single item is
;; a tagged list whose head is the symbol 'col / 'tbl-constraint; anything
;; else is a bundle to splice — the same one-level flattening `hx-ops` does
;; for ops, so authors never need `(apply table …)`.
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
;; Each builder renders its statement now (capturing the current schema
;; scope) and returns an op whose effect appends that string to the
;; `(sql_commands)` accumulator. We override op:append's generic label with
;; the statement's identity, the way terraform's `block-op` does.

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
;; (state -> writes text). Registered by the inventory file with
;; `(renders-with "sql" render-sql)`, so `hexol render -o sql` prints the
;; accumulated statements as runnable DDL, one per stanza.

(define (render-sql state)
  (for-each (lambda (cmd) (display cmd) (newline) (newline))
            (or (state-get state '(sql_commands)) '())))
