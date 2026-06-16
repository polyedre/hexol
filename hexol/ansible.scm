;;; hexol/ansible.scm — the ansible target library.
;;;
;;; In-memory inventory + role-rendering vocabulary (cf. (hexol k8s) for K8s).
;;; Opt in with `(use-modules (hexol ansible))`, consume from a role example
;;; (examples/ansible.scm).
;;;
;;; Vocabulary only: loads inventory.yml into a state alist, gives role
;;; authors read helpers (host-attr, group-hosts, …), task sugar (task,
;;; handler, as), and one sink op — `play` — appending an assembled play into
;;; the `(ansible_plays)` accumulator (Ansible analogue of
;;; `(kubernetes_resources)`).
;;;
;;; NOT here: fanning a role over a group (one play per host) is an
;;; *example's* structure, built from kernel compose-ops/map — see
;;; examples/ansible.scm. *Rendering* is the CLI's job: `hexol render -o
;;; ansible` JSON-encodes `(ansible_plays)` (a playbook is valid JSON). No
;;; CMDB, no HTTP — state is a nested alist built once from inventory.yml.
;;;
;;; State shape (mirrors what we'd put in the CMDB if we did):
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
            ;; task constructors
            task handler
            ;; task transformers
            as
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

;; ---------- task constructors ----------
;;
;; `task`/`handler` are macros over the shared `block`/`body` surface (same
;; one terraform-resource uses): each entry is an attribute `(key <expr>)`
;; (evaluated Scheme) or a nested module dict `(block <module> <entry>…)`. A
;; task reads like its YAML, no quasiquote/dotted pairs:
;;
;;   (task
;;     (name "Install nginx")
;;     (block ansible.builtin.apt (name "nginx") (state "present"))
;;     (become #t)
;;     (notify "Reload nginx"))
;;
;; `%check-task` raises early on a missing `name` (Ansible accepts nameless
;; tasks but they're miserable to debug).

(define (%check-task tag alist)
  (unless (assq 'name alist)
    (error tag "missing `name` key in:" alist))
  alist)

(define-syntax task
  (syntax-rules ()
    ((_ entry ...) (%check-task 'task (body entry ...)))))

(define-syntax handler
  (syntax-rules ()
    ((_ entry ...) (%check-task 'handler (body entry ...)))))

;; ---------- task transformers ----------
;;
;; `(as user tasks)` defaults `become: #t` (and `become_user: <user>` for
;; non-root) on each task not already declaring `become`. A Scheme-level
;; scope replacing Ansible's `block: become:`. Nests — innermost `as` wins:
;;
;;   (as 'root
;;     (list
;;       (task ...)                                   ; runs as root
;;       (as 'www-data (list (task ...)))))           ; runs as www-data

(define (as user tasks)
  "Wrap TASKS so each one that doesn't already declare `become' runs as
USER: defaulting `become: #t' and, for a non-root USER, `become_user:
USER'.  A Scheme-level scope replacing Ansible's `block:'; nests with the
innermost `as' winning."
  (let ((user-str (if (symbol? user) (symbol->string user) user)))
    (map (lambda (t)
           (cond
             ((assq 'become t) t)
             ((or (eq? user 'root) (equal? user-str "root"))
              (append t '((become . #t))))
             (else
              (append t `((become . #t)
                          (become_user . ,user-str))))))
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
