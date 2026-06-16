;;; hexol/ledger.scm — the ledger target library.
;;;
;;; Scheme front-end for a personal ledger on the engine's op model, like
;;; (hexol k8s) and (hexol sql). Every form is an *op*; folding the
;;; inventory appends entries to `(ledger_journal)` (and split rules to
;;; `(ledger_rules)`), so the resolved state *is* the journal. `tree` /
;;; `ops` / `explain` and `render -o sexp | json | yaml` work generically;
;;; `render -o ledger` runs `render-ledger` (registered via `renders-with`)
;;; to emit ledger-cli text.
;;;
;;;   (hx-ops
;;;     (with-default-account 'Asset:Checking
;;;       (in-year 2024 (in-month 'jan (on-day 5
;;;         (tx "Rent" (post 'Expense:Rent 600))))))
;;;     (apply-splits))
;;;
;;; Design notes:
;;;
;;; - Scope wrappers (`in-year`, `in-month`, `on-day`, `in-currency`,
;;;   `with-default-account`) bind dynamic context at construction time —
;;;   date/currency/default bakes into each entry — then bundle into one op.
;;;   Same mechanism as `with-namespace` in (hexol k8s); inner scopes win.
;;;
;;; - Date components must be lexically determined: a leaf outside the
;;;   required scopes errors. The source stays a pure function of itself.
;;;
;;; - `tx` (multi-posting) is the core form; `spent` / `received` /
;;;   `transfer` are sugar. Amount-less postings are balancing (ledger-cli
;;;   semantics); inside `with-default-account` an unbalanced tx gets one.
;;;
;;; - `split-with` records a finance rule into `(ledger_rules)`.
;;;   `apply-splits` is a cross-cutting transform (the k8s `tls-all`
;;;   analogue): placed last, it rewrites every tx in `(ledger_journal)`,
;;;   injecting each matching rule's receivable/counter postings, then
;;;   clears `(ledger_rules)` (its `#:where` procs don't serialize).

(define-module (hexol ledger)
  #:use-module (hexol kernel)
  #:use-module (hexol construct)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:re-export (define-construct construct-map-entries construct-flag)
  #:export (;; scope wrappers
            in-year in-month on-day
            in-currency with-default-account
            ;; leaf transactions
            tx post spent received transfer
            ;; amount tagging
            eur sgd usd
            ;; rules + assertions
            recurring price tags balance-assert
            ;; split rules + their application
            split-with apply-splits
            ;; render adapter (state -> writes ledger-cli text)
            render-ledger))

;; ---------- dynamic context ----------

(define current-year             (make-parameter #f))
(define current-month            (make-parameter #f))
(define current-day              (make-parameter #f))
(define current-currency         (make-parameter 'EUR))
(define current-default-account  (make-parameter #f))

;; ---------- scope wrappers ----------
;;
;; Each binds its parameter at construction time, then bundles into one op
;; (so scopes nest, compose inside `hx-when`, and the most specific location
;; wins via `stamp-loc`). All five share the kernel's `scope-ops`, behind
;; k8s `with-namespace` and sql `with-schema` too.

(define-syntax-rule (in-year y body ...)
  (scope-ops 'in-year (current-year y) "year " body ...))
(define-syntax-rule (in-month m body ...)
  (scope-ops 'in-month (current-month m) "month " body ...))
(define-syntax-rule (on-day d body ...)
  (scope-ops 'on-day (current-day d) "day " body ...))
(define-syntax-rule (in-currency c body ...)
  (scope-ops 'in-currency (current-currency c) "currency " body ...))
(define-syntax-rule (with-default-account a body ...)
  (scope-ops 'with-default-account (current-default-account a) "default-account " body ...))

;; ---------- amount tagging ----------
;;
;; A tagged amount is the pair (currency . number). Bare numbers inherit
;; `current-currency`. The constructors make currency explicit at the call
;; site without a reader extension.

(define (eur n) (cons 'EUR n))
(define (sgd n) (cons 'SGD n))
(define (usd n) (cons 'USD n))

(define (tag-amount x)
  (cond ((pair? x) x)
        ((number? x) (cons (current-currency) x))
        (else (error 'tag-amount "expected number or tagged amount, got:" x))))

;; ---------- date assembly ----------

(define %months
  '((jan . 1) (january . 1)   (feb . 2) (february . 2)
    (mar . 3) (march . 3)     (apr . 4) (april . 4)
    (may . 5)                 (jun . 6) (june . 6)
    (jul . 7) (july . 7)      (aug . 8) (august . 8)
    (sep . 9) (september . 9) (oct . 10) (october . 10)
    (nov . 11) (november . 11) (dec . 12) (december . 12)))

(define (month->int m)
  (cond ((integer? m) m)
        ((assq m %months) => cdr)
        (else (error 'month->int "unknown month:" m))))

(define (require-date who)
  (let ((y (current-year)) (m (current-month)) (d (current-day)))
    (unless (and y m d)
      (error who
             "no date in scope; wrap in (in-year ... (in-month ... (on-day ... ...)))"
             `((year . ,y) (month . ,m) (day . ,d))))
    (list y (month->int m) d)))

;; ---------- entries as data ----------
;;
;; Every entry is a `kind`-tagged alist, so it renders as clean JSON/YAML.
;; A posting splits its amount into number + currency; #f amount means a
;; balancing posting.

(define* (post account #:optional amount #:key (note #f))
  (let ((a (and amount (tag-amount amount))))
    `((account  . ,account)
      (amount   . ,(and a (cdr a)))
      (currency . ,(and a (car a)))
      (note     . ,note))))

(define (posting? x) (and (pair? x) (pair? (car x))))   ; alist, not a tag marker

;; A tx option marker. Only `tags` for now; split rules pivot on it.
(define (tags . xs) (cons 'tags xs))

;; ---------- the journal op ----------
;;
;; Each builder renders its entry now (capturing the scope) and returns an
;; op appending it to `(ledger_journal)`. Like surface's `resource`, we
;; override op:append's generic label.

(define (journal-op entry source label)
  (relabel (op:append '(ledger_journal) entry source) label))

(define-syntax-rule (tx desc post-expr ...)
  (%emit-tx desc (list post-expr ...)))

(define (%emit-tx desc items)
  (let* ((date     (require-date 'tx))
         (default  (current-default-account))
         (tag-list (append-map cdr
                     (filter (lambda (x) (and (pair? x) (eq? (car x) 'tags))) items)))
         (posts    (filter posting? items))
         (has-bal      (any (lambda (p) (not (assq-ref p 'amount))) posts))
         (uses-default (any (lambda (p) (eq? (assq-ref p 'account) default)) posts))
         (posts*   (if (or has-bal (not default) uses-default)
                       posts
                       (append posts (list (post default))))))
    (journal-op `((kind . tx) (date . ,date) (description . ,desc)
                  (tags . ,tag-list) (postings . ,posts*))
                (list 'tx desc)
                (string-append "tx " desc))))

;; ---------- sugar for the common shapes ----------

(define* (spent amount payee #:optional category #:key (from #f) (note #f))
  (let* ((src (or from (current-default-account)
                  (error 'spent "no #:from given and no with-default-account in scope")))
         (cat (or category 'Expense:Unknown))
         (amt (tag-amount amount)))
    (%emit-tx payee (list (post cat amt #:note note) (post src)))))

(define* (received amount source #:optional account #:key (to #f) (note #f))
  (let* ((dst (or to (current-default-account)
                  (error 'received "no #:to given and no with-default-account in scope")))
         (acc (or account 'Income:Unknown))
         (amt (tag-amount amount)))
    (%emit-tx source
              (list (post dst amt #:note note)
                    (post acc (cons (car amt) (- (cdr amt))))))))

(define* (transfer amount from to #:key (note #f))
  (let ((amt (tag-amount amount)))
    (%emit-tx (format #f "Transfer ~a → ~a" from to)
              (list (post to amt #:note note)
                    (post from (cons (car amt) (- (cdr amt))))))))

;; ---------- recurring / price / assertions ----------

;; `recurring` splices postings as a body (like `tx`), date bounds as
;; leading keywords:
;;   (recurring 'monthly #:from '(Y M D) #:to '(Y M D) (post …) (post …) …)
;; `#:to` optional; missing `#:from` errors via %recurring.
(define-syntax recurring
  (syntax-rules ()
    ((_ period #:from f #:to t post ...) (%recurring period f  t  (list post ...)))
    ((_ period #:from f       post ...) (%recurring period f  #f (list post ...)))
    ((_ period                post ...) (%recurring period #f #f (list post ...)))))

(define (%recurring period from to posts)
  (unless from
    (error 'recurring
           "missing #:from — every recurring rule must declare a start date"
           period))
  (journal-op `((kind . recurring) (period . ,period)
                (from . ,from) (to . ,to) (postings . ,posts))
              (list 'recurring period)
              (format #f "recurring ~a" period)))

(define (price date base quote-amount)
  (let ((a (tag-amount quote-amount)))
    (journal-op `((kind . price) (date . ,date) (base . ,base)
                  (amount . ,(cdr a)) (currency . ,(car a)))
                (list 'price date) "price")))

(define* (balance-assert account expected #:key (note #f))
  (let ((date (require-date 'balance-assert))
        (a    (tag-amount expected)))
    (journal-op `((kind . balance-assert) (date . ,date) (account . ,account)
                  (amount . ,(cdr a)) (currency . ,(car a)) (note . ,note))
                (list 'balance-assert account)
                (format #f "balance-assert ~a" account))))

;; ---------- split-with: a finance rule ----------
;;
;; Declares that a matching transaction is shared with `peer` at `fraction`
;; (e.g. 1/2). Stored in `(ledger_rules)`; `apply-splits` applies it.
;; Predicate inputs:
;;   #:from / #:to  '(YYYY MM DD)  inclusive date bounds
;;   #:tag           'symbol        tx must carry this tag
;;   #:account-prefix 'sym          postings under this account are shared
;;   #:where          proc          arbitrary (tx-alist -> bool), ANDed in

(define* (split-with peer fraction
                     #:key (from #f) (to #f) (tag #f)
                           (account-prefix #f) (where #f)
                           (peer-account #f))
  (let ((rule `((peer            . ,peer)
                (fraction        . ,fraction)
                (from            . ,from)
                (to              . ,to)
                (tag             . ,tag)
                (account-prefix  . ,account-prefix)
                (where           . ,where)
                (peer-account    . ,(or peer-account
                                        (string->symbol
                                         (string-append "Asset:Receivable:"
                                           (if (symbol? peer)
                                               (symbol->string peer) peer))))))))
    (relabel (op:append '(ledger_rules) rule (list 'split-with peer))
             (format #f "split-with ~a" peer))))

;; ---------- apply-splits: the cross-cutting expansion ----------

(define (date<=? a b)
  (let loop ((a a) (b b))
    (cond ((null? a) #t)
          ((< (car a) (car b)) #t)
          ((> (car a) (car b)) #f)
          (else (loop (cdr a) (cdr b))))))

(define (expense-posting? p)
  (string-prefix? "Expense" (symbol->string (assq-ref p 'account))))

(define (split-matches-tx? rule tx)
  (let ((from  (assq-ref rule 'from))
        (to    (assq-ref rule 'to))
        (tag   (assq-ref rule 'tag))
        (where (assq-ref rule 'where))
        (date  (assq-ref tx 'date))
        (tgs   (assq-ref tx 'tags)))
    (and (or (not from)  (date<=? from date))
         (or (not to)    (date<=? date to))
         (or (not tag)   (and (memq tag tgs) #t))
         (or (not where) (where tx)))))

(define (split-matches-post? rule p)
  (let ((prefix (assq-ref rule 'account-prefix)))
    (cond ((and prefix (assq-ref p 'amount))
           (string-prefix? (symbol->string prefix)
                           (symbol->string (assq-ref p 'account))))
          (prefix #f)                          ; prefix given, posting has no amount
          ((assq-ref p 'amount) (expense-posting? p))   ; tag/where: only Expense:*
          (else #f))))

(define (expand-tx tx rules)
  ;; Keep each posting, then append (receivable +share, expense -share)
  ;; pairs from every matching rule.
  (state-set tx '(postings)
    (append-map
     (lambda (p)
       (cons p
         (append-map
          (lambda (r)
            (if (and (split-matches-tx? r tx) (split-matches-post? r p))
                (let* ((frac  (assq-ref r 'fraction))
                       (peer  (assq-ref r 'peer-account))
                       (amt   (assq-ref p 'amount))
                       (cur   (assq-ref p 'currency))
                       (share (* amt frac)))
                  (list `((account . ,peer) (amount . ,share)
                          (currency . ,cur) (note . #f))
                        `((account . ,(assq-ref p 'account)) (amount . ,(- share))
                          (currency . ,cur)
                          (note . ,(format #f "split ~a with ~a"
                                           frac (assq-ref r 'peer))))))
                '()))
          rules)))
     (assq-ref tx 'postings))))

(define (apply-splits)
  "Return a cross-cutting op that rewrites every tx in (ledger_journal),
injecting the postings implied by each matching rule in (ledger_rules),
then clears the rules.  Place it last in the inventory, the way k8s
examples end with (tls-all)."
  (make-op 'apply-splits '(apply-splits)
    (lambda (state)
      (let ((rules   (or (state-get state '(ledger_rules)) '()))
            (journal (or (state-get state '(ledger_journal)) '())))
        (state-set
         (state-set state '(ledger_journal)
           (map (lambda (e)
                  (if (eq? (assq-ref e 'kind) 'tx) (expand-tx e rules) e))
                journal))
         '(ledger_rules) '())))   ; rules carry #:where procs; drop after use
    "apply-splits"))

;; ===========================================================================
;; render-ledger: (ledger_journal) -> ledger-cli text
;; ===========================================================================
;;
;; The journal is already split-expanded by now (apply-splits ran in the
;; fold), so rendering is pure formatting.

(define (date-string d)
  (format #f "~4,'0d/~2,'0d/~2,'0d" (car d) (cadr d) (caddr d)))

(define (amount-string n cur)
  (let ((txt (if (integer? n)
                 (number->string (inexact->exact n))
                 (format #f "~,2f" n))))
    (format #f "~a ~a" txt cur)))

(define account-column 36)

(define (pad-account acct)
  (let* ((s (symbol->string acct))
         (n (string-length s)))
    (if (>= n account-column)
        (string-append s "  ")
        (string-append s (make-string (- account-column n) #\space)))))

(define (render-post p)
  (let ((account (assq-ref p 'account))
        (amount  (assq-ref p 'amount))
        (cur     (assq-ref p 'currency))
        (note    (assq-ref p 'note)))
    (string-append
     "    "
     (if amount
         (string-append (pad-account account) (amount-string amount cur))
         (symbol->string account))
     (if note (string-append "  ; " note) ""))))

(define (render-tx e)
  (string-append
   (date-string (assq-ref e 'date)) " " (assq-ref e 'description) "\n"
   (string-join (map render-post (assq-ref e 'postings)) "\n")
   "\n"))

(define (render-recurring e)
  (string-append
   "~ " (case (assq-ref e 'period)
          ((monthly) "Monthly") ((yearly) "Yearly") ((weekly) "Weekly")
          (else (symbol->string (assq-ref e 'period))))
   " from " (date-string (assq-ref e 'from))
   (let ((to (assq-ref e 'to))) (if to (string-append " to " (date-string to)) ""))
   "\n"
   (string-join (map render-post (assq-ref e 'postings)) "\n")
   "\n"))

(define (render-price e)
  (format #f "P ~a ~a ~a\n"
          (date-string (assq-ref e 'date)) (assq-ref e 'base)
          (amount-string (assq-ref e 'amount) (assq-ref e 'currency))))

(define (render-balance-assert e)
  ;; ledger-cli: zero-amount posting with `= EXPECTED`.
  (let ((note (assq-ref e 'note)))
    (string-append
     (date-string (assq-ref e 'date)) " * Balance check"
     (if note (string-append " — " note) "") "\n"
     "    " (pad-account (assq-ref e 'account))
     (format #f "0 ~a = ~a" (assq-ref e 'currency)
             (amount-string (assq-ref e 'amount) (assq-ref e 'currency)))
     "\n")))

(define (render-entry e)
  (case (assq-ref e 'kind)
    ((tx)             (render-tx e))
    ((recurring)      (render-recurring e))
    ((price)          (render-price e))
    ((balance-assert) (render-balance-assert e))
    (else (format #f "; unknown entry: ~a\n" (assq-ref e 'kind)))))

(define (render-ledger state)
  "Registered by the inventory file with `(renders-with \"ledger\"
render-ledger)`, so `hexol render -o ledger` emits ledger-cli text."
  (display (string-join (map render-entry
                             (or (state-get state '(ledger_journal)) '()))
                        "\n")))
