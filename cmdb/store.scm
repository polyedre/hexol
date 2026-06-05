;;; cmdb/store.scm — fact-log CMDB with versioned library.
;;;
;;; A fact is a sexp `(<op-name> <args>...)`. The store looks up
;;; <op-name> in the *currently active* library module, calls it with
;;; <args>, and folds the returned ops into the in-memory state.
;;;
;;; The active library is itself controlled by facts. The reserved op
;;;
;;;     (bump-lib "<sha>")
;;;
;;; switches the active library to module `(cmdb libraries <sha>)`
;;; (file cmdb/libraries/<sha>.scm). It takes effect for every
;;; subsequent fact in the log, both at append and during refold —
;;; replay is contemporaneous, each fact applies through whichever
;;; library was current when it was appended.
;;;
;;; The store starts a refold with the `initial-library` SHA (passed to
;;; make-cmdb); the first bump-lib in the log overrides that for facts
;;; after it.

(define-module (cmdb store)
  #:use-module (hexol kernel)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-cmdb
            cmdb?
            cmdb-state
            cmdb-log-path
            cmdb-initial-library
            cmdb-current-library
            cmdb-get
            cmdb-append-fact!
            cmdb-facts
            cmdb-refold!
            fact->ops))

(define-record-type <cmdb>
  (%make-cmdb initial-lib log-path state-box library-box)
  cmdb?
  (initial-lib  cmdb-initial-library)
  (log-path     cmdb-log-path)
  (state-box    cmdb-state-box)
  (library-box  cmdb-library-box))

(define (cmdb-state c)            (car (cmdb-state-box   c)))
(define (set-cmdb-state! c s)     (set-car! (cmdb-state-box   c) s))
(define (cmdb-current-library c)  (car (cmdb-library-box c)))
(define (set-cmdb-library! c m)   (set-car! (cmdb-library-box c) m))

;; ---------- library loading ----------

(define (sha->module-name sha)
  (list 'cmdb 'libraries (string->symbol sha)))

(define (load-library-by-sha sha)
  (let ((mod-name (sha->module-name sha)))
    (or (resolve-interface mod-name)
        (error "could not load library for sha:" sha))))

;; ---------- fact log ----------

(define (read-fact-log log-path)
  (if (file-exists? log-path)
      (let ((port (open-input-file log-path)))
        (let loop ((acc '()))
          (let ((form (read port)))
            (if (eof-object? form)
                (begin (close-port port) (reverse acc))
                (loop (cons form acc))))))
      '()))

(define (append-fact-to-log! log-path fact)
  (let ((port (open-file log-path "a")))
    (write fact port)
    (newline port)
    (close-port port)))

;; ---------- fact application ----------

(define (bump-lib-fact? fact)
  (and (pair? fact) (eq? (car fact) 'bump-lib)))

(define (fact->ops cmdb fact)
  ;; Look up the op-name in the currently active library; call it with
  ;; the fact's args; normalize to a list of ops.
  (unless (and (pair? fact) (symbol? (car fact)))
    (error "invalid fact (expected (op-name args ...)):" fact))
  (let* ((name (car fact))
         (args (cdr fact))
         (var  (module-variable (cmdb-current-library cmdb) name)))
    (unless var
      (error "unknown op in active library:" name
             'library (module-name (cmdb-current-library cmdb))))
    (let ((proc (variable-ref var)))
      (unless (procedure? proc)
        (error "library binding is not a procedure:" name))
      (let ((result (apply proc args)))
        (cond
          ((op? result) (list result))
          ((and (list? result) (every op? result)) result)
          (else (error "library op did not return ops:" name result)))))))

(define (apply-fact! cmdb fact)
  ;; Mutating: handles bump-lib by swapping the active library; for
  ;; ordinary facts, folds the resulting ops into the state.
  (cond
    ((bump-lib-fact? fact)
     (let ((sha (cadr fact)))
       (set-cmdb-library! cmdb (load-library-by-sha sha))))
    (else
     (let ((ops (fact->ops cmdb fact)))
       (set-cmdb-state! cmdb
                        (fold (lambda (op s) (apply-op op s))
                              (cmdb-state cmdb)
                              ops))))))

;; ---------- public ----------

(define* (make-cmdb log-path #:key (initial-library "v1"))
  (let ((cmdb (%make-cmdb
                initial-library
                log-path
                (list '())
                (list (load-library-by-sha initial-library)))))
    (cmdb-refold! cmdb)
    cmdb))

(define (cmdb-refold! cmdb)
  ;; Reset to initial library + empty state, then replay every fact.
  (set-cmdb-library! cmdb (load-library-by-sha (cmdb-initial-library cmdb)))
  (set-cmdb-state!   cmdb '())
  (for-each (lambda (fact) (apply-fact! cmdb fact))
            (read-fact-log (cmdb-log-path cmdb)))
  (cmdb-state cmdb))

(define (cmdb-get cmdb path)
  (state-get (cmdb-state cmdb) path))

(define (cmdb-append-fact! cmdb fact)
  ;; Append to log first, then apply. If apply throws, the log is still
  ;; consistent (next refold will catch the bad fact at the same point).
  (append-fact-to-log! (cmdb-log-path cmdb) fact)
  (apply-fact! cmdb fact)
  (cmdb-state cmdb))

(define (cmdb-facts cmdb)
  (read-fact-log (cmdb-log-path cmdb)))
