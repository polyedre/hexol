;;; examples/database-schema.scm — a worked relational schema.
;;;
;;; A consumer of (hexol sql), the same way examples/kubernetes.scm consumes
;;; (hexol k8s). Each `table` / `index` form is an op; folding the inventory
;;; appends each rendered `CREATE …` statement to the `(sql_commands)`
;;; accumulator, which is just resolved state. So every CLI view works:
;;;
;;;   ./bin/hexol render -o sql  examples/database-schema.scm   # the DDL
;;;   ./bin/hexol render         examples/database-schema.scm   # resolved state (sexp)
;;;   ./bin/hexol render -o json examples/database-schema.scm   # JSON array
;;;   ./bin/hexol render --path sql_commands examples/database-schema.scm
;;;   ./bin/hexol tree           examples/database-schema.scm   # the op tree
;;;
;;; `-o sql` runs the (state -> SQL text) adapter the next line registers.
;;;
;;; The point is what a schema-as-a-program buys over hand-written SQL:
;;;
;;;   • Type sugar — `(id)`, `(text …)`, `(references …)` instead of
;;;     spelling out `SERIAL PRIMARY KEY` / `INTEGER … REFERENCES …`.
;;;   • Real abstraction — `audit-columns` is an ordinary function that
;;;     returns a list of columns, spliced into any table (`table` flattens
;;;     one level, so no `apply` is needed).
;;;   • A namespace scope — `with-schema` qualifies every table in it.

(use-modules (hexol sql))

;; Expose the SQL text view as `hexol render -o sql`.
(renders-with "sql" render-sql)

;; A reusable column bundle: every audited table gets the same two
;; timestamps. A function returning a list of columns; `table` flattens it
;; in (SQL has no equivalent — you copy/paste the columns).

(define (audit-columns)
  (list (timestamp 'created_at #:not-null #t #:default (raw "now()"))
        (timestamp 'updated_at #:not-null #t #:default (raw "now()"))))

(hx-ops

  (with-schema "public"

    (table 'users
      (id)
      (text 'email     #:not-null #t #:unique #t)
      (text 'name      #:not-null #t)
      (boolean 'active #:not-null #t #:default #t)
      (numeric 'balance 12 2 #:not-null #t #:default 0)   ; precision 12, scale 2
      (audit-columns))

    ;; A per-user account row, with audit columns spliced in via the helper.
    (table 'accounts
      (id)
      (references 'user_id 'users)
      (varchar 'kind 32 #:not-null #t #:check "kind IN ('free', 'pro', 'team')")
      (audit-columns))

    (table 'posts
      (id)
      (references 'author_id 'users)
      (text 'title     #:not-null #t)
      (text 'body)
      (boolean 'published   #:not-null #t #:default #f)
      (timestamp 'published_at)
      (audit-columns))

    (table 'tags
      (id)
      (text 'label #:not-null #t #:unique #t))

    ;; Join table: composite primary key, two foreign keys, no surrogate id.
    (table 'post_tags
      (references 'post_id 'posts)
      (references 'tag_id  'tags)
      (primary-key 'post_id 'tag_id))

    (table 'comments
      (id)
      (references 'post_id   'posts)
      (references 'author_id 'users)
      (text 'body #:not-null #t)
      (audit-columns))

    ;; ---- indexes ----
    (index 'posts    '(author_id))
    (index 'posts    '(published published_at))
    (index 'comments '(post_id))
    (index 'users    '(email) #:unique #t)))
