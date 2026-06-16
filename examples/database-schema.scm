;;; examples/database-schema.scm — a worked relational schema.
;;;
;;; Consumes (hexol sql), like kubernetes.scm consumes (hexol k8s). Each
;;; `table` / `index` is an op; folding appends each `CREATE …` to the
;;; `(sql_commands)` accumulator (resolved state). Every CLI view works:
;;;
;;;   ./bin/hexol render -o sql  examples/database-schema.scm   # the DDL
;;;   ./bin/hexol render         examples/database-schema.scm   # resolved state (sexp)
;;;   ./bin/hexol render -o json examples/database-schema.scm   # JSON array
;;;   ./bin/hexol render --path sql_commands examples/database-schema.scm
;;;   ./bin/hexol tree           examples/database-schema.scm   # the op tree
;;;
;;; `-o sql` runs the (state -> SQL text) adapter the next line registers.
;;;
;;; What schema-as-a-program buys over hand-written SQL:
;;;
;;;   • Type sugar — `(id)`, `(text …)`, `(references …)` vs spelling out
;;;     `SERIAL PRIMARY KEY` / `INTEGER … REFERENCES …`.
;;;   • Abstraction — `audit-columns` is a plain function returning a column
;;;     list, spliced into any table (`table` flattens one level; no `apply`).
;;;   • Scope — `with-schema` qualifies every table in it.

(use-modules (hexol sql))

;; Expose SQL text view as `hexol render -o sql`.
(renders-with "sql" render-sql)

;; Reusable column bundle: same two timestamps on every audited table.
;; A function returning columns; `table` flattens it in (SQL would force
;; copy/paste).

(define (audit-columns)
  (list (timestamp 'created_at (not-null) (default (raw "now()")))
        (timestamp 'updated_at (not-null) (default (raw "now()")))))

(hx-ops

  (with-schema "public"

    (table 'users
      (id)
      (text 'email     (not-null) (unique))
      (text 'name      (not-null))
      (boolean 'active (not-null) (default #t))
      (numeric 'balance 12 2 (not-null) (default 0))   ; precision 12, scale 2
      (audit-columns))

    ;; Per-user account; audit columns spliced in via the helper.
    (table 'accounts
      (id)
      (references 'user_id 'users)
      (varchar 'kind 32 (not-null) (check "kind IN ('free', 'pro', 'team')"))
      (audit-columns))

    (table 'posts
      (id)
      (references 'author_id 'users)
      (text 'title     (not-null))
      (text 'body)
      (boolean 'published   (not-null) (default #f))
      (timestamp 'published_at)
      (audit-columns))

    (table 'tags
      (id)
      (text 'label (not-null) (unique)))

    ;; Join table: composite PK, two FKs, no surrogate id.
    (table 'post_tags
      (references 'post_id 'posts)
      (references 'tag_id  'tags)
      (primary-key 'post_id 'tag_id))

    (table 'comments
      (id)
      (references 'post_id   'posts)
      (references 'author_id 'users)
      (text 'body (not-null))
      (audit-columns))

    ;; ---- indexes ----
    (index 'posts    '(author_id))
    (index 'posts    '(published published_at))
    (index 'comments '(post_id))
    (index 'users    '(email) #:unique #t)))
