;;; hexol/apply.scm — appliers: push the resolved state to the world.
;;;
;;; `render` turns an inventory into artifacts and stops; this module is the
;;; other half — the procedures that take a *resolved state* and actually
;;; apply it. They are deliberately the only place hexol shells out to act on
;;; the world (`tofu`, `kubectl`); the `(hexol terraform)` / `(hexol k8s)`
;;; libraries stay pure language-to-data translators.
;;;
;;; An *applier* is a `(state dry? -> effects)` procedure: it reads its slice of
;;; the resolved state and acts (or, under DRY?, delegates to its tool's native
;;; plan). Every constructor here — `terraform-applier', `kubectl-applier', and
;;; the check builders `wait-for'/`check'/`report' — simply *returns* such a
;;; procedure; none of them register. Registration is one explicit step, the
;;; `appliers' form, which names a sequence and runs it in textual order:
;;;
;;;   (appliers
;;;     ("terraform"  (terraform-applier #:workdir "deploy"
;;;                     #:output->file '(("kubeconfig" . "deploy/kubeconfig"))))
;;;     ("check-api"  (wait-for "kube-API up"
;;;                     (cmd "kubectl" "--kubeconfig=deploy/kubeconfig"
;;;                          "get" "--raw=/readyz")))
;;;     ("kubernetes" (kubectl-applier #:kubeconfig "deploy/kubeconfig"))
;;;     ("check-apps" (check "apps Ready" my-predicate #:fatal? #f)))
;;;
;;; The CLI's `hexol apply` resolves the inventory once, then runs the named
;;; appliers in order (optionally filtered to `--only NAME'), passing the shared
;;; state and the `--dry-run' flag. So they run *from the state*, in order, and
;;; only under `apply' — never during render/tree/ops, where the collector is
;;; unbound and `appliers' is a harmless no-op.
;;;
;;; Two ways to place a check:
;;;   * a standalone `appliers' entry — a visible, independently `--only'-able
;;;     step (e.g. "check-api" above);
;;;   * a deploy applier's `#:pre'/`#:post' — a gate *bound to its owner*, so it
;;;     travels with `--only kubernetes' instead of being skipped. Use this for
;;;     a precondition the deploy can't run without. `#:pre'/`#:post' each take
;;;     one check proc or a list of them.
;;;
;;; Order is what makes this a one-command bootstrap: terraform first, so the
;;; infra is built and its kubeconfig dumped to a known path before the cluster
;;; applier reads (kubernetes_resources) and `kubectl apply`s it against that
;;; file. The hand-off is an explicit conventional path, so each applier stays
;;; an independent (state -> effects) with no hidden state threading.
;;;
;;; (`applies-with' is still the primitive underneath `appliers'; use it
;;; directly to register a single one-off applier.)
;;;
;;; This module also offers `terraform-destroyer', which returns not an applier
;;; but a CLI *action* — a (state args -> effects) procedure an inventory
;;; registers with `defines-action'/`actions' to contribute its own `hexol'
;;; verb (e.g. `hexol destroy'). An action is a standalone verb, not a pipeline
;;; step: it never runs during `hexol apply', only when its verb is named.

(define-module (hexol apply)
  #:use-module (hexol kernel)
  #:use-module ((hexol terraform) #:select (emit-terraform-json))
  #:use-module ((hexol yaml) #:select (emit-yaml-stream))
  #:use-module (hexol sh)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  ;; `report'/`check' predicates read the resolved state directly; re-export the
  ;; accessor so an inventory's own report lambdas (e.g. derive URLs from the
  ;; rendered resources) can reach into it without importing (hexol kernel).
  #:re-export (state-get)
  #:export (terraform-applier kubectl-applier terraform-destroyer
            terraform-outputter
            appliers actions wait-for check report cmd sh-ok?))

;; ---------- shell helpers ----------

(define (find-binary name)
  (or (which-cmd name) (error "apply: command not found on PATH:" name)))

;; Log a progress line to stderr and flush immediately. Without the flush,
;; Guile block-buffers stderr when it is a pipe and emits these lines only at
;; exit — *after* any subprocess (tofu/kubectl) output, which writes to the
;; same fd directly. Flushing keeps the phase markers interleaved with the
;; tool's own output, so a failure reads as belonging to the right phase.
(define (log fmt . args)
  (apply format (current-error-port) fmt args)
  (force-output (current-error-port)))

;; Run PROG with ARGS inheriting this process's stdio, so an interactive
;; prompt (`tofu apply`'s y/N) reaches the user's terminal. Errors on a
;; non-zero / signalled exit.
(define (run* prog . args)
  (force-output (current-error-port))      ; flush our logs before the child writes
  (let ((code (status:exit-val (apply system* prog args))))
    (unless (eqv? code 0)
      (error "apply: command failed" (cons prog args)))))

;; Run PROG ARGS, return stdout as a string (trailing newline trimmed).
(define (capture prog . args)
  (force-output (current-error-port))
  (let* ((port   (apply open-pipe* OPEN_READ prog args))
         (out    (get-string-all port))
         (status (close-pipe port)))
    (unless (eqv? (status:exit-val status) 0)
      (error "apply: command failed" (cons prog args)))
    (string-trim-right out)))

(define (write-file path content)
  (call-with-output-file path (lambda (p) (display content p))))

;; Run PROG with ARGS, discard stdout, return #t iff it exited 0. The building
;; block for shell-based checks: a readiness probe or smoke test is just "does
;; this command succeed?". (PROG is found on PATH; stderr is left to flow
;; through, so a failing probe's reason shows up while a `wait-for' polls.)
(define (sh-ok? prog . args)
  (let* ((port (apply open-pipe* OPEN_READ prog args))
         (_    (get-string-all port)))
    (eqv? 0 (status:exit-val (close-pipe port)))))

;; ---------- checks: intermediate appliers ----------
;;
;; A check is an ordinary applier — a `(state dry? -> effects)' — whose effect
;; is *observation* (poll, assert, report) rather than mutation. These builders
;; return one; drop it into an `appliers' entry or a deploy applier's
;; #:pre/#:post. PRED is a `(state -> boolean)'; `cmd' lifts a shell command
;; into one. They differ only in dry-run and failure policy:
;;   wait-for  block until PRED holds (or time out → fatal); skipped on DRY?.
;;   check     assert PRED once; #:fatal? (default #t) → error, else warn;
;;             skipped on DRY? (there is nothing yet to check during a plan).
;;   report    run THUNK for its side output; always, never fatal.

;; Lift a shell command into a state predicate: ignores state, true iff the
;; command exits 0.  (cmd "kubectl" "get" "--raw=/readyz")
(define (cmd prog . args)
  (lambda (state) (apply sh-ok? prog args)))

;; True unless #:needs names a binary that is absent; logs a skip note when so.
;; Lets a check that shells out to an optional tool no-op (rather than fail the
;; run) when that tool isn't installed — the same posture as `helm-template`.
(define (needs-ok? phase desc needs)
  (or (not needs) (which-cmd needs)
      (begin (log ";; apply[~a]: ~a — `~a' not on PATH, skipped~%" phase desc needs)
             #f)))

(define* (wait-for desc pred #:key (timeout 120) (interval 5) (needs #f))
  "Return an applier that polls PRED every INTERVAL seconds until it holds,
erroring after TIMEOUT seconds.  A no-op under DRY? (the infra it waits on may
not exist during a plan), or when #:needs names a binary absent from PATH."
  (lambda (state dry?)
    (cond
      (dry? (log ";; apply[wait]: would wait for ~a~%" desc))
      ((not (needs-ok? 'wait desc needs)) #f)
      (else
        (let ((deadline (+ (current-time) timeout)))
          (log ";; apply[wait]: waiting for ~a (timeout ~as)…~%" desc timeout)
          (let loop ()
            (cond
              ((pred state) (log ";; apply[wait]: ~a — ready~%" desc))
              ((>= (current-time) deadline)
               (error "apply[wait]: timed out waiting for:" desc))
              (else (sleep interval) (loop)))))))))

(define* (check desc pred #:key (fatal? #t) (needs #f))
  "Return an applier that asserts PRED once.  On failure it errors when FATAL?
(the default) or warns otherwise.  A no-op under DRY?, or when #:needs names a
binary absent from PATH (so a check shelling out to an optional tool skips
rather than fails when the tool is missing)."
  (lambda (state dry?)
    (cond
      (dry?        (log ";; apply[check]: ~a (dry-run, skipped)~%" desc))
      ((not (needs-ok? 'check desc needs)) #f)
      ((pred state) (log ";; apply[check]: ~a — ok~%" desc))
      (fatal?      (error "apply[check]: failed:" desc))
      (else        (log ";; apply[check]: ~a — FAILED (non-fatal)~%" desc)))))

(define (report desc thunk)
  "Return an applier that runs THUNK (state -> any) for its side output and
never fails.  Runs even under DRY?."
  (lambda (state dry?)
    (log ";; apply[report]: ~a~%" desc)
    (thunk state)))

;; #:pre/#:post accept a single check or a list of them; normalise to a list.
(define (as-checks x) (if (procedure? x) (list x) x))
(define (run-checks cs state dry?) (for-each (lambda (c) (c state dry?)) cs))

;; ---------- registration ----------

;; The sugar over a sequence of appliers: name each and register it, in textual
;; order.  Each PROC is an expression evaluating to a `(state dry? -> effects)'
;; — a deploy applier or a check.  Expands to plain `applies-with' calls, so it
;; is a no-op outside `hexol apply' just like the primitive.
(define-syntax appliers
  (syntax-rules ()
    ((_ (name proc) ...)
     (begin (applies-with name proc) ...))))

;; The sugar over a set of CLI actions (custom `hexol' verbs the inventory
;; contributes), paralleling `appliers'.  Each entry is (NAME SYNOPSIS PROC):
;; PROC evaluates to a `(state args -> effects)' action, SYNOPSIS the one-line
;; usage `hexol --help' shows.  Expands to plain `defines-action' calls, so it
;; is a no-op outside the CLI's action discovery just like the primitive.
(define-syntax actions
  (syntax-rules ()
    ((_ (name synopsis proc) ...)
     (begin (defines-action name proc synopsis) ...))))

;; ---------- terraform applier ----------

(define* (terraform-applier #:key (workdir "deploy") (binary "tofu")
                            (config-file "infra.tf.json") (output->file '())
                            (pre '()) (post '()))
  "Return an applier for the (terraform_config) subtree: write WORKDIR/CONFIG-FILE,
`BINARY -chdir=WORKDIR init`, then `plan` (when DRY?) or `apply`.  After a real
apply, every (OUTPUT . FILE) pair in OUTPUT->FILE is written from `BINARY
-chdir=WORKDIR output -raw OUTPUT` — the cred hand-off, e.g. (\"kubeconfig\"
. \"deploy/kubeconfig\").  BINARY defaults to `tofu`; pass #:binary \"terraform\"
for stock Terraform.  #:pre / #:post run their checks (one or a list) before
init and after the outputs are written; name the result in an `appliers' form."
  (lambda (state dry?)
    (run-checks (as-checks pre) state dry?)
    (let ((tf     (find-binary binary))
          (config (or (state-get state '(terraform_config))
                      (error "apply[terraform]: no (terraform_config) in state")))
          (chdir  (string-append "-chdir=" workdir)))
      (unless (file-exists? workdir) (mkdir workdir))
      (let ((path (string-append workdir "/" config-file)))
        (call-with-output-file path
          (lambda (p) (emit-terraform-json p config)))
        (log ";; apply[terraform]: wrote ~a~%" path))
      (run* tf chdir "init" "-input=false")
      (cond
        (dry? (run* tf chdir "plan"))
        (else
         (run* tf chdir "apply")            ; tofu's own y/N prompt gates this
         (for-each
           (lambda (pair)
             (let ((val (capture tf chdir "output" "-raw" (car pair))))
               (write-file (cdr pair) val)
               (log ";; apply[terraform]: output ~a -> ~a~%" (car pair) (cdr pair))))
           output->file))))
    (run-checks (as-checks post) state dry?)))

;; ---------- terraform destroyer (a CLI action, not a pipeline step) ----------

(define* (terraform-destroyer #:key (workdir "deploy") (binary "tofu"))
  "Return an *action* (a (state args -> effects) CLI verb, not an applier) that
tears the terraform-managed infra down: `BINARY -chdir=WORKDIR destroy', gated
by the tool's own y/N prompt.  With `--dry-run' in ARGS it runs `plan -destroy'
instead.  Register it with `defines-action'/`actions' so it becomes its own
explicit `hexol' verb — never a step in a bare `hexol apply'."
  (lambda (state args)
    (let ((tf    (find-binary binary))
          (chdir (string-append "-chdir=" workdir)))
      (if (member "--dry-run" args)
          (begin (log ";; destroy: ~a ~a plan -destroy~%" binary chdir)
                 (run* tf chdir "plan" "-destroy"))
          (begin (log ";; destroy: ~a ~a destroy~%" binary chdir)
                 (run* tf chdir "destroy"))))))

;; ---------- terraform outputter (a CLI action, not a pipeline step) ----------

(define* (terraform-outputter #:key (workdir "deploy") (binary "tofu") (outputs '()))
  "Return an *action* (a (state args -> effects) CLI verb, not an applier) that
fetches terraform outputs out of the state and writes them to files: for each
(OUTPUT . FILE) pair in OUTPUTS, capture `BINARY -chdir=WORKDIR output -raw
OUTPUT' and write it to FILE.  Same hand-off `terraform-applier's #:output->file
does after an apply, but on demand — so a `hexol output' verb can re-fetch the
kubeconfig / talosconfig from existing state without re-running apply.  Register
it with `defines-action'/`actions' to make it its own `hexol' verb."
  (lambda (state args)
    (let ((tf    (find-binary binary))
          (chdir (string-append "-chdir=" workdir)))
      (for-each
        (lambda (pair)
          (let ((val (capture tf chdir "output" "-raw" (car pair))))
            (write-file (cdr pair) val)
            (log ";; output: ~a -> ~a~%" (car pair) (cdr pair))))
        outputs))))

;; ---------- kubectl applier ----------

;; Float Namespaces then CustomResourceDefinitions to the front so a kind's
;; CRD is applied before any custom resource of that kind, and a namespace
;; before resources scoped into it. (`filter` is stable, so order within each
;; group is preserved.)
(define (order-resources rs)
  (let ((kind-is (lambda (k) (lambda (r) (equal? (assq-ref r 'kind) k)))))
    (append (filter (kind-is "Namespace") rs)
            (filter (kind-is "CustomResourceDefinition") rs)
            (filter (lambda (r)
                      (not (member (assq-ref r 'kind)
                                   '("Namespace" "CustomResourceDefinition"))))
                    rs))))

;; Pipe YAML to `kubectl ARGS` (which include `apply … -f -`) and return the
;; exit code, letting the caller decide whether a non-zero pass is fatal.
(define (kubectl-pipe kubectl args yaml)
  (force-output (current-error-port))
  (let ((port (apply open-pipe* OPEN_WRITE kubectl args)))
    (display yaml port)
    (status:exit-val (close-pipe port))))

(define* (kubectl-applier #:key (binary "kubectl") (kubeconfig #f)
                          (server-side #t) (passes 2) (pre '()) (post '()))
  "Return an applier for (kubernetes_resources): render the manifest stream —
Namespaces and CRDs floated to the front — and `kubectl apply` it.  With DRY?,
runs one `--dry-run=server` pass.  Otherwise applies up to PASSES times (default
2): a custom resource whose CRD is created earlier in the *same* run fails the
first pass (kubectl caches API types per invocation), so a second pass — not a
wait — lands it.  CRDs created out of band (e.g. cert-manager's, installed later
by Flux) converge on a subsequent `hexol apply --only kubernetes`.  #:kubeconfig
sets --kubeconfig; #:server-side toggles --server-side (the default — big CRD
bundles exceed client-side apply's annotation-size limit).  #:pre / #:post run
their checks (one or a list) before and after applying — e.g. a #:pre `wait-for'
that blocks until the API answers, so the gate travels with `--only kubernetes'."
  (lambda (state dry?)
    (run-checks (as-checks pre) state dry?)
    (let* ((kc    (find-binary binary))
           (rs    (or (state-get state '(kubernetes_resources))
                      (error "apply[kubernetes]: no (kubernetes_resources) in state")))
           (yaml  (call-with-output-string
                    (lambda (p) (emit-yaml-stream p (order-resources rs)))))
           (base  (append (if kubeconfig (list (string-append "--kubeconfig=" kubeconfig)) '())
                          (list "apply")
                          (if server-side '("--server-side" "--force-conflicts") '()))))
      (cond
        (dry?
         (unless (eqv? 0 (kubectl-pipe kc (append base '("--dry-run=server" "-f" "-")) yaml))
           (error "apply[kubernetes]: dry-run reported errors")))
        (else
         (let loop ((n 1))
           (let ((code (kubectl-pipe kc (append base '("-f" "-")) yaml)))
             (cond
               ((eqv? code 0)
                (log ";; apply[kubernetes]: applied (pass ~a)~%" n))
               ((< n passes)
                (log ";; apply[kubernetes]: pass ~a had errors (CRDs registering); retrying~%" n)
                (loop (+ n 1)))
               (else
                (log ";; apply[kubernetes]: pass ~a still had errors — re-run `--only kubernetes` once out-of-band CRDs (e.g. cert-manager via Flux) exist~%"
                     n))))))))
    (run-checks (as-checks post) state dry?)))
