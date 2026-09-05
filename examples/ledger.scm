;;; examples/ledger.scm — a worked personal-ledger journal.
;;;
;;; Consumes (hexol ledger), like database-schema.scm consumes (hexol sql).
;;; Every form is an op; folding accumulates the journal into
;;; `(ledger_journal)` (split rules into `(ledger_rules)`), and the trailing
;;; `(apply-splits)` expands rules into transactions. Every CLI view works:
;;;
;;;   ./bin/hexol render -o ledger -i examples/ledger.scm   # ledger-cli text
;;;   ./bin/hexol render           -i examples/ledger.scm   # resolved state (sexp)
;;;   ./bin/hexol render -o json   -i examples/ledger.scm   # JSON
;;;   ./bin/hexol render --path ledger_journal -i examples/ledger.scm
;;;   ./bin/hexol tree             -i examples/ledger.scm   # the op tree
;;;
;;; `-o ledger` runs the (state -> ledger-cli text) adapter registered below.
;;; Numbers and names are made up.

(use-modules (hexol ledger)
             (srfi srfi-1))        ; any, filter-map

;; Expose ledger-cli text view as `hexol render -o ledger`.
(renders-with "ledger" render-ledger)

(hx-ops

  ;; ---------- monthly recurring bundle ----------

  (recurring 'monthly
    #:from '(2024 1 1)
    #:to   '(2024 12 31)   ; lease ends; rules without a stop date drift forever
    (post 'Expense:Gas        45)
    (post 'Expense:Electric   25)
    (post 'Expense:Internet   30)
    (post 'Expense:Rent       600)
    (post 'Liability:Loan     20.00)
    (post 'Asset:Checking))

  ;; ---------- split-finance rules ----------
  ;;
  ;; Roommate "Alex" splits groceries and utilities 50/50 all of 2024. Each
  ;; matching expense gets a counter-posting into Asset:Receivable:Alex (an
  ;; IOU). Declarative intent; `apply-splits` below expands it.

  (split-with 'alex 1/2
    #:from '(2024 1 1)
    #:to   '(2024 12 31)
    #:account-prefix 'Expense:Groceries
    #:peer-account 'Asset:Receivable:Alex)

  (split-with 'alex 1/2
    #:from '(2024 1 1)
    #:to   '(2024 12 31)
    #:tag  'shared-utility
    #:peer-account 'Asset:Receivable:Alex)

  ;; Trip with two friends: three-way split, tag-driven.
  (split-with 'jamie 1/3
    #:from '(2024 7 1) #:to '(2024 7 31)
    #:tag 'trip-2024
    #:peer-account 'Asset:Receivable:Jamie)
  (split-with 'morgan 1/3
    #:from '(2024 7 1) #:to '(2024 7 31)
    #:tag 'trip-2024
    #:peer-account 'Asset:Receivable:Morgan)

  ;; Custom predicate over the tx alist — any "team lunch" in the
  ;; description or a posting note is expensed against the employer.
  (split-with 'employer 1
    #:from '(2024 1 1) #:to '(2024 12 31)
    #:where (lambda (tx)
              (let* ((desc  (assq-ref tx 'description))
                     (posts (assq-ref tx 'postings))
                     (notes (filter-map (lambda (p) (assq-ref p 'note)) posts))
                     (haystacks (cons desc (filter string? notes))))
                (any (lambda (s)
                       (string-contains (string-downcase s) "team lunch"))
                     haystacks)))
    #:peer-account 'Asset:Receivable:Employer)

  ;; ---------- the journal itself ----------

  (with-default-account 'Asset:Checking

    (in-year 2024
      (in-month 'january
        (on-day 1
          (tx "Opening Balances"
            (post 'Asset:Cash             200)
            (post 'Asset:Checking         4200.00)
            (post 'Asset:Savings          8500.00)
            (post 'Asset:Brokerage        12500.00)
            (post 'Equity:Opening)))

        (on-day 5
          (tx "Rent"
            (post 'Expense:Rent 600))

          (tx "Groceries"
            (tags 'shared-grocery)
            (post 'Expense:Groceries 87.40)))

        (on-day 15
          (tx "Salary"
            (post 'Asset:Checking  2800)
            (post 'Income:Salary  -2800)))

        (on-day 22
          (tx "Electric bill"
            (tags 'shared-utility)
            (post 'Expense:Electric 42.10 #:note "January usage"))

          (tx "Internet"
            (tags 'shared-utility)
            (post 'Expense:Internet 30)))

        (on-day 31
          (balance-assert 'Asset:Checking 6357.90
            #:note "Bank statement 2024-01-31")))

      (in-month 'february
        (on-day 5
          (tx "Rent"          (post 'Expense:Rent 600))
          (tx "Groceries"
            (post 'Expense:Groceries 64.20)))

        (on-day 10
          (tx "Team lunch"
            (post 'Expense:Meals 38.50 #:note "team lunch with onboarding cohort")))

        (on-day 15
          (tx "Salary"
            (post 'Asset:Checking  2800)
            (post 'Income:Salary  -2800)))

        (on-day 28
          (balance-assert 'Asset:Checking 8423.10)))

      ;; July: weekend trip abroad. Currency scope swaps EUR for USD;
      ;; tagged so the 3-way split rules above apply.
      (in-month 'july
        (on-day 12
          (in-currency 'USD
            (tx "Hotel"
              (tags 'trip-2024)
              (post 'Expense:Travel:Hotel 320 #:note "2 nights, group rate"))

            (tx "Dinner"
              (tags 'trip-2024)
              (post 'Expense:Travel:Meals 78.40))

            (tx "Taxi from airport"
              (tags 'trip-2024)
              (post 'Expense:Travel:Transport 42))))

        (on-day 20
          (price '(2024 7 20) 'EUR (usd 1.09)))

        (on-day 25
          ;; Jamie pays back their share — partially clears the IOU.
          ;; Balancing post is the receivable, not with-default-account.
          (tx "Reimbursement from Jamie"
            (post 'Asset:Checking            146.80)
            (post 'Asset:Receivable:Jamie))))

      (in-month 'december
        (on-day 24
          (tx "Holiday gifts"
            (post 'Expense:Gifts:Family 220)))

        (on-day 31
          (balance-assert 'Asset:Checking      7240.00
            #:note "Bank statement EOY")
          (balance-assert 'Liability:Loan      0
            #:note "Loan fully repaid 2024")
          (balance-assert 'Asset:Brokerage     14200.00
            #:note "Brokerage YE statement")))))

  ;; Expand split rules into the accumulated transactions. Last, like
  ;; k8s examples end with (tls-all) / (compliance-all …).
  (apply-splits))
