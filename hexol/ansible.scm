;;; hexol/ansible.scm — the ansible target library.
;;;
;;; In-memory inventory + role-rendering vocabulary (cf. (hexol k8s) for K8s).
;;; Opt in with `(use-modules (hexol ansible))`, consume from a role example
;;; (examples/ansible.scm).
;;;
;;; Vocabulary only: loads inventory.yml into a state alist, gives role
;;; authors read helpers (host-attr, group-hosts, …), play-body forms (tasks,
;;; as, each, only, handlers), and one sink op — `play` — appending an assembled play into
;;; the `(ansible_plays)` accumulator (Ansible analogue of
;;; `(kubernetes_resources)`).
;;;
;;; NOT here: fanning a role over a group (one play per host) is an
;;; *example's* structure, built from kernel compose-ops/map — see
;;; examples/ansible.scm. *Rendering* is the CLI's job: `hexol render -o
;;; ansible` JSON-encodes `(ansible_plays)` (a playbook is valid JSON).
;;; State is a nested alist built once from inventory.yml.
;;;
;;; State shape:
;;;
;;;   ((hosts  (<host-name> (vars (<key> . <val>) ...)) ...)
;;;    (groups (<group-name> (hosts <h1> <h2> ...)
;;;                          (vars  (<key> . <val>) ...)) ...))
;;;
;;; `inventory.yml` is the source of truth; this module is the bridge.

(define-module (hexol ansible)
  #:use-module (hexol kernel)
  #:use-module ((hexol surface) #:select (block body))
  #:use-module (hexol construct)
  #:use-module (yaml)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:re-export (define-construct construct-map-entries construct-flag)
  #:export (load-inventory
            ;; helpers for role authors
            host-attr host-attrs host-groups in-group?
            all-hosts group-hosts group-var-of
            effective-host-var
            state-ref
            ;; play bodies
            tasks task handlers as each only
            ;; play sink
            play))

;; ---------- YAML -> Scheme normalisation ----------
;;
;; (yaml) returns string-keyed alists, vectors for sequences, strings for
;; scalars (not auto-typed). Convert to symbol-keyed alists with typed
;; scalars.

(define (looks-like-bool s) (or (string=? s "true") (string=? s "false")))
(define (string->bool s) (string=? s "true"))

(define (try-number s)
  (and (> (string-length s) 0) (string->number s)))

(define (scalar->scm s)
  (cond ((not (string? s)) s)
        ((looks-like-bool s) (string->bool s))
        ((try-number s) => (lambda (n) n))
        (else s)))

(define (yaml->scm obj)
  (cond
    ((vector? obj) (map yaml->scm (vector->list obj)))
    ((and (pair? obj) (every pair? obj))
     (map (lambda (e)
            (cons (string->symbol (car e))
                  (yaml->scm (cdr e))))
          obj))
    ((string? obj) (scalar->scm obj))
    (else obj)))

;; ---------- inventory walk ----------

(define (kv block key) (and (pair? block) (assq-ref block key)))

(define (host-names hosts-block)
  (if (pair? hosts-block) (map car hosts-block) '()))

(define (collect-hosts inv)
  ;; ((host-name . merged-attrs) ...) from all.hosts plus inline overrides
  ;; under all.children.<g>.hosts.<h>.<inline-vars>.
  (let* ((all      (assq-ref inv 'all))
         (top      (or (kv all 'hosts) '()))
         (children (or (kv all 'children) '()))
         (acc (map (lambda (e) (cons (car e) (or (cdr e) '()))) top)))
    (for-each
      (lambda (group-entry)
        (let ((hosts (or (kv (cdr group-entry) 'hosts) '())))
          (for-each
            (lambda (h)
              (let ((name (car h))
                    (inline (or (cdr h) '())))
                (when (pair? inline)
                  (let ((existing (assq name acc)))
                    (if existing
                        (set-cdr! existing (append (cdr existing) inline))
                        (set! acc (cons (cons name inline) acc)))))))
            hosts)))
      children)
    (reverse acc)))

(define (collect-groups inv)
  ;; ((group-name . (host-name ...)) ...), incl. implicit `all`.
  (let* ((all      (assq-ref inv 'all))
         (children (or (kv all 'children) '()))
         (all-hs   (host-names (or (kv all 'hosts) '())))
         (per-g    (map (lambda (g)
                          (cons (car g)
                                (host-names (or (kv (cdr g) 'hosts) '()))))
                        children)))
    (cons (cons 'all all-hs) per-g)))

(define (collect-group-vars inv)
  ;; ((group-name (key . value) ...) ...) — all.vars plus children.<g>.vars.
  (let* ((all      (assq-ref inv 'all))
         (top-vars (or (kv all 'vars) '()))
         (children (or (kv all 'children) '()))
         (per-g    (filter-map
                     (lambda (g)
                       (let ((vars (kv (cdr g) 'vars)))
                         (and vars (cons (car g) vars))))
                     children)))
    (cons (cons 'all top-vars) per-g)))

(define (load-inventory inventory-path)
  "Read the Ansible inventory YAML at INVENTORY-PATH and return the full
state alist with `hosts' and `groups' roots, normalising YAML scalars to
proper Scheme types and folding in per-group and inline host vars."
  ;; Full state alist in one shot.
  (let* ((raw   (read-yaml-file inventory-path))
         (inv   (yaml->scm raw))
         (hosts (collect-hosts inv))
         (groups (collect-groups inv))
         (gvars (collect-group-vars inv))
         (hosts-alist
           (map (lambda (h) (cons (car h) (list (cons 'vars (cdr h))))) hosts))
         (groups-alist
           (map (lambda (g)
                  (let* ((gname (car g))
                         (gh    (cdr g))
                         (gv    (or (assq-ref gvars gname) '())))
                    (cons gname
                          (filter pair?
                                  (list (cons 'hosts gh)
                                        (and (pair? gv) (cons 'vars gv)))))))
                groups)))
    (list (cons 'hosts hosts-alist)
          (cons 'groups groups-alist))))

;; ---------- helpers ----------

(define (state-ref state path)
  "Walk STATE by PATH, a list of symbol alist-keys, returning the value
found or #f if any key is missing."
  (let loop ((s state) (p path))
    (cond
      ((null? p) s)
      ((not (pair? s)) #f)
      (else
       (let ((e (assq (car p) s)))
         (and e (loop (cdr e) (cdr p))))))))

(define (host-attrs host-name state)
  "Return HOST-NAME's vars alist from STATE, or '() if the host is unknown."
  (or (state-ref state (list 'hosts host-name 'vars)) '()))

(define (host-attr host-name key state)
  "Return HOST-NAME's var at KEY from STATE.  KEY may be a single symbol or
a path (list of symbols) into a nested var."
  (let ((path (if (pair? key) key (list key))))
    (state-ref (host-attrs host-name state) path)))

(define (all-hosts state)
  "Return the list of all host names defined in STATE."
  (let ((hs (state-ref state '(hosts))))
    (if hs (map car hs) '())))

(define (group-hosts gname state)
  "Return the list of host names belonging to group GNAME in STATE."
  (or (state-ref state (list 'groups gname 'hosts)) '()))

(define (host-groups host-name state)
  "Return the list of group names that HOST-NAME belongs to in STATE."
  (let ((groups (state-ref state '(groups))))
    (if groups
        (filter-map (lambda (g)
                      (let ((hs (state-ref (cdr g) '(hosts))))
                        (and hs (memq host-name hs) (car g))))
                    groups)
        '())))

(define (in-group? host-name gname state)
  "Return #t if HOST-NAME is a member of group GNAME in STATE."
  (and (memq host-name (group-hosts gname state)) #t))

(define (group-var-of gname key state)
  "Return group GNAME's var at KEY from STATE, or #f if undefined."
  (state-ref state (list 'groups gname 'vars key)))

(define (%var-defined? host-name key state)
  ;; `key` present at top level of host's vars (host-level explicit #f must
  ;; beat group-level defaults).
  (let ((vars (host-attrs host-name state)))
    (and (pair? vars) (assq key vars) #t)))

;; ---------- task bodies ----------
;;
;; A play body is a list of *entries*, one grammar shared by every body form
;; (`tasks`, `as`, `each`, `only`, `handlers`):
;;
;;   ("Install nginx" (apt (name "nginx") (state "present")) #:notify "Reload nginx")
;;     a task: NAME, the module dict, then task-level keywords, in YAML order.
;;     NAME is a string or an expression like (fmt …). A module symbol without a
;;     dot is `ansible.builtin.<module>`; dotted names are taken as written.
;;     Module args use the shared `body` surface (nested dict: `(block k …)`).
;;
;;   (map apt packages)   (user-tasks h u)   (if … …)
;;     anything whose head is a symbol is a Scheme expression yielding a task
;;     or a task list, spliced in place.
;;
;; A bare variable as NAME reads as an expression call — write `(str www)`.
;;
;; Body forms:
;;   (tasks entry …)             flat task list
;;   (as root entry …)           become scope (become_user for non-root); nests
;;   (each (p ports) entry …)    entries once per element, p bound
;;   (only (var h 'backup) entry …)   '() when the test is false
;;   (handlers entry …)          same as `tasks`, for a play's handler list
;;   (task entry)                one task, outside a body

(define (%module sym)
  (let ((n (symbol->string sym)))
    (if (string-index n #\.) sym (symbol-append 'ansible.builtin. sym))))

(define (%splice x)
  ;; a task alist (caar is the `name` symbol) or a list of them
  (if (or (null? x) (pair? (caar x))) x (list x)))

;; (%task-kws NAME MODULE-ALIST (acc …) kw val …) — collect trailing keywords
(define-syntax %task-kws
  (lambda (x)
    (syntax-case x ()
      ((_ nm mod (kv ...) kw val rest ...)
       (keyword? (syntax->datum #'kw))
       (with-syntax ((k (datum->syntax #'kw (keyword->symbol (syntax->datum #'kw)))))
         #'(%task-kws nm mod (kv ... (k . val)) rest ...)))
      ((_ nm mod ((k . v) ...))
       #'(cons* (cons 'name nm) mod (list (cons 'k v) ...))))))

(define-syntax %entry
  (lambda (x)
    (syntax-case x ()
      ((_ (head . rest))
       (identifier? #'head)
       #'(%splice (head . rest)))
      ((_ (nm (module arg ...) kw ...))
       #'(list (%task-kws nm (cons (%module 'module) (body arg ...)) () kw ...))))))

(define-syntax tasks
  (syntax-rules ()
    ((_ entry ...) (append (%entry entry) ...))))

(define-syntax handlers
  (syntax-rules ()
    ((_ entry ...) (tasks entry ...))))

(define-syntax task
  (syntax-rules ()
    ((_ nm (module arg ...) kw ...)
     (%task-kws nm (cons (%module 'module) (body arg ...)) () kw ...))))

(define-syntax each
  (syntax-rules ()
    ((_ (v lst) entry ...) (append-map (lambda (v) (tasks entry ...)) lst))))

(define-syntax only
  (syntax-rules ()
    ((_ test entry ...) (if test (tasks entry ...) '()))))

;; `(as root entry …)`: a Scheme-level scope replacing Ansible's `block:
;; become:`. Each task not already declaring `become` gets `become: #t` and,
;; for a non-root user, `become_user`. Nests — innermost `as` wins. USER is a
;; bare symbol or an expression.
(define-syntax as
  (lambda (x)
    (syntax-case x ()
      ((_ user entry ...) (identifier? #'user) #'(%as 'user (tasks entry ...)))
      ((_ user entry ...)                      #'(%as user (tasks entry ...))))))

(define (%as user tasks)
  (let ((user-str (if (symbol? user) (symbol->string user) user)))
    (map (lambda (t)
           (cond
             ((assq 'become t) t)
             ((equal? user-str "root") (append t '((become . #t))))
             (else (append t `((become . #t) (become_user . ,user-str))))))
         tasks)))

(define (effective-host-var host-name key state)
  "Resolve HOST-NAME's effective value for KEY in STATE: a host-level var
wins (even an explicit #f), otherwise the first defining group, falling
back to the `all' group's var."
  (cond
    ((%var-defined? host-name key state)
     (host-attr host-name (if (pair? key) key (list key)) state))
    (else
     (let loop ((gs (host-groups host-name state)))
       (cond
         ((null? gs) (group-var-of 'all key state))
         ((let ((v (group-var-of (car gs) key state)))
            (and (not (eq? v #f)) v)))
         (else (loop (cdr gs))))))))

;; ---------- the play sink ----------
;;
;; `(play host-name tasks [handlers])` emits one Ansible play as a *bundle of
;; ops*, not a single append: a skeleton (hosts + gather_facts) under
;; `(ansible_plays <host>)`, then one op per task/handler appending into the
;; play's list. Each task being its own op, the op tree descends play ->
;; tasks (so `explain` reaches a task's path). The accumulator is host-keyed;
;; the CLI flattens it into the playbook's top-level list at render time
;; (`hexol render -o ansible`).
;;
;; Fanning a role over a group (one play per host) stays an example's
;; structure, built from kernel make-op/fold.

(define (%task-op host-sym key t)
  ;; append task/handler `t` into (ansible_plays <host> tasks|handlers),
  ;; labelled by its name.
  (let* ((lead (if (eq? key 'handlers) "handler " "task "))
         (name (or (assq-ref t 'name) "?"))
         (op   (op:append (list 'ansible_plays host-sym key) t `(task ,name))))
    (relabel op (string-append lead name))))

(define* (play host-name tasks #:optional (handlers '()))
  "Return an op bundle emitting one Ansible play for HOST-NAME under
(ansible_plays <host>): a hosts/gather_facts skeleton plus one op per task
in TASKS and per handler in HANDLERS, so the op tree descends play -> tasks.
The CLI flattens the host-keyed accumulator back into the playbook at render
time."
  (let* ((host (if (symbol? host-name) (symbol->string host-name) host-name))
         (hsym (string->symbol host))
         (kids (append (map (lambda (t) (%task-op hsym 'tasks t)) tasks)
                       (map (lambda (h) (%task-op hsym 'handlers h)) handlers))))
    (make-op 'play `(play ,host-name)
             (lambda (state)
               (let* ((path   (list 'ansible_plays hsym))
                      (seeded (state-set state path
                                         `((hosts . ,host) (gather_facts . #f))))
                      (built  (fold (lambda (op s) (apply-op op s)) seeded kids))
                      (p      (state-get built path))
                      ;; appends prepend keys; restore play order.
                      (ordered (filter-map (lambda (k) (assq k p))
                                           '(hosts gather_facts tasks handlers))))
                 (state-set built path ordered)))
             (string-append "play " host)
             kids)))
