;;; hexol/apply.scm — appliers: push the resolved state to the world.
;;;
;;; `render` stops at artifacts; this module's procedures take a *resolved
;;; state* and apply it. The only place hexol shells out (`tofu`, `kubectl`);
;;; `(hexol terraform)` / `(hexol k8s)` stay pure data translators.
;;;
;;; An *applier* is a `(state dry? -> effects)`: reads its slice of state and
;;; acts (under DRY?, delegates to the tool's native plan). The constructors
;;; here — `terraform-applier', `kubectl-applier', and the checks
;;; `wait-for'/`check'/`report' — only *return* one; none register.
;;; Registration is the `appliers' form, naming a sequence run in textual order:
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
;;; `hexol apply` resolves once, then runs the named appliers in order
;;; (optionally `--only NAME'), passing the shared state and `--dry-run'. Only
;;; under `apply' — elsewhere the collector is unbound and `appliers' no-ops.
;;;
;;; Two ways to place a check:
;;;   * an `appliers' entry — a visible, independently `--only'-able step;
;;;   * a deploy applier's `#:pre'/`#:post' — a gate bound to its owner, so it
;;;     travels with `--only kubernetes'. Use for a precondition the deploy
;;;     can't run without. Each takes one check or a list.
;;;
;;; Order makes this a one-command bootstrap: terraform first, so the infra is
;;; built and its kubeconfig dumped to a known path before the cluster applier
;;; reads (kubernetes_resources) and `kubectl apply`s against it. The hand-off
;;; is an explicit conventional path, so each applier stays an independent
;;; (state -> effects) with no hidden state threading.
;;;
;;; (`applies-with' is the primitive under `appliers'; use it to register a
;;; single one-off applier.)
;;;
;;; Also `terraform-destroyer': returns not an applier but a CLI *action* — a
;;; (state args -> effects) registered with `defines-action'/`actions' for its
;;; own `hexol' verb (e.g. `hexol destroy'). A standalone verb, not a pipeline
;;; step: never runs during `hexol apply', only when named.

(define-module (hexol apply)
  #:use-module (hexol kernel)
  #:use-module ((hexol terraform) #:select (emit-terraform-json))
  #:use-module ((hexol yaml) #:select (emit-yaml-stream))
  #:use-module (hexol sh)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  ;; `report'/`check' predicates read the state directly; re-export the
  ;; accessor so an inventory's report lambdas can reach in without importing
  ;; (hexol kernel).
  #:re-export (state-get)
  #:export (terraform-applier kubectl-applier terraform-destroyer
            terraform-outputter talos-config-applier
            appliers actions wait-for check report cmd sh-ok?))

;; ---------- shell helpers ----------

(define (find-binary name)
  (or (which-cmd name) (error "apply: command not found on PATH:" name)))

;; Log a progress line to stderr, flushing now. Guile block-buffers a piped
;; stderr and would emit these only at exit — *after* subprocess output on the
;; same fd. Flushing interleaves phase markers with tool output, so a failure
;; reads as belonging to the right phase.
(define (log fmt . args)
  (apply format (current-error-port) fmt args)
  (force-output (current-error-port)))

;; Run PROG ARGS inheriting stdio, so an interactive prompt (`tofu apply`'s
;; y/N) reaches the terminal. Errors on non-zero / signalled exit.
(define (run* prog . args)
  (force-output (current-error-port))      ; flush logs before the child writes
  (let ((code (status:exit-val (apply system* prog args))))
    (unless (eqv? code 0)
      (error "apply: command failed" (cons prog args)))))

;; Run PROG ARGS, return stdout (trailing newline trimmed).
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

;; Run PROG ARGS, discard stdout, return #t iff it exited 0 — the building
;; block for shell-based checks (a readiness probe is just "did it succeed?").
;; PROG found on PATH; stderr flows through, so a failing probe's reason shows
;; while a `wait-for' polls.
(define (sh-ok? prog . args)
  (let* ((port (apply open-pipe* OPEN_READ prog args))
         (_    (get-string-all port)))
    (eqv? 0 (status:exit-val (close-pipe port)))))

;; ---------- checks: intermediate appliers ----------
;;
;; A check is an applier whose effect is *observation* (poll, assert, report),
;; not mutation. These builders return one; drop it into an `appliers' entry or
;; a #:pre/#:post. PRED is a `(state -> boolean)'; `cmd' lifts a shell command.
;; They differ only in dry-run and failure policy:
;;   wait-for  block until PRED holds (or time out → fatal); skipped on DRY?.
;;   check     assert PRED once; #:fatal? (default #t) → error, else warn;
;;             skipped on DRY? (nothing to check during a plan).
;;   report    run THUNK for its side output; always, never fatal.

;; Lift a shell command into a state predicate: ignores state, true iff the
;; command exits 0.  (cmd "kubectl" "get" "--raw=/readyz")
(define (cmd prog . args)
  (lambda (state) (apply sh-ok? prog args)))

;; True unless #:needs names an absent binary (then logs a skip). Lets a check
;; that shells out to an optional tool no-op rather than fail when it isn't
;; installed — same posture as `helm-template`.
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

;; #:pre/#:post accept a single check or a list; normalise to a list.
(define (as-checks x) (if (procedure? x) (list x) x))
(define (run-checks cs state dry?) (for-each (lambda (c) (c state dry?)) cs))

;; ---------- registration ----------

;; Name and register a sequence of appliers in textual order. Each PROC
;; evaluates to a `(state dry? -> effects)' — a deploy applier or a check.
;; Expands to `applies-with' calls, so a no-op outside `hexol apply'.
(define-syntax appliers
  (syntax-rules ()
    ((_ (name proc) ...)
     (begin (applies-with name proc) ...))))

;; Register a set of CLI actions (custom `hexol' verbs), paralleling
;; `appliers'. Each entry (NAME SYNOPSIS PROC): PROC evaluates to a
;; `(state args -> effects)', SYNOPSIS the one-line `hexol --help' usage.
;; Expands to `defines-action' calls, so a no-op outside action discovery.
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
         (run* tf chdir "apply")            ; tofu's y/N prompt gates this
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

;; ---------- talos day-2 lifecycle (CLI actions, not pipeline steps) ----------
;;
;; Provisioning is terraform's job (day 1). Terraform can't safely express
;; changing a *running* cluster: a control-plane machine-config edit that
;; reboots a node must roll ONE node at a time, waiting for health before the
;; next, or etcd loses quorum — awkward in HCL, natural here. So day-2 lives as
;; hexol *actions* (talosctl verbs), parallel to `terraform-destroyer'.
;;
;; The config is NOT re-derived — hexol holds only the patch; the full machine
;; config (secrets, PKI) is rendered by the talos provider. The rolling action
;; reads each node's config from terraform state via `tofu output' (expose it
;; per-node); the inventory stays the source of truth, and `apply-config'
;; pushes exactly what a fresh boot would. (Pin `user_data' with a lifecycle
;; ignore so a config edit doesn't force-replace the instance — first boot
;; seeds it, this rolls it after.)

;; Capture a single terraform output: `BINARY -chdir=WORKDIR output -raw NAME'.
(define (tf-output-raw binary workdir name)
  (capture binary (string-append "-chdir=" workdir) "output" "-raw" name))

(define* (talos-config-applier #:key (workdir "deploy") (binary "talosctl")
                               (tofu "tofu") (talosconfig "deploy/talosconfig")
                               (mode "auto") (health-timeout "10m") (nodes '()))
  "Return an *action* (a (state args -> effects) CLI verb) that rolls the
rendered machine config onto each node in NODES one at a time, health-gating
between them.  NODES is a list of (LABEL ADDRESS-OUTPUT CONFIG-OUTPUT): LABEL
names the node; ADDRESS-OUTPUT and CONFIG-OUTPUT are the terraform output names
holding its endpoint (floating IP) and its `data.talos_machine_configuration'
machine_configuration.  Per node the config is fetched from terraform state,
written to a temp file, and applied with `talosctl apply-config --mode MODE';
then `talosctl health' must pass — queried from a DIFFERENT node, so the probe
is not aimed at a rebooting apid — before the next.  TALOSCONFIG (client certs)
is refreshed from state first.  With `--dry-run' in ARGS each node gets
`apply-config --dry-run' (prints the diff, changes nothing, no reboot, no gate).
Register with `defines-action'/`actions' to expose it as its own `hexol' verb."
  (lambda (state args)
    (let* ((tc-bin (find-binary binary))
           (tf-bin (find-binary tofu))
           (dry?   (and (member "--dry-run" args) #t))
           ;; one tofu round-trip per value; addresses up front (for the
           ;; observe-from-another-node health gate), configs lazily per node.
           (addrs  (map (lambda (n) (tf-output-raw tf-bin workdir (cadr n))) nodes)))
      ;; refresh client config so apply/health use current certs
      (write-file talosconfig (tf-output-raw tf-bin workdir "talosconfig"))
      (log ";; talos: wrote ~a~%" talosconfig)
      (let loop ((ns nodes) (i 0))
        (unless (null? ns)
          (let* ((n     (car ns))
                 (label (car n))
                 (ep    (list-ref addrs i))
                 ;; stable observer: first node that isn't this one, so a
                 ;; reboot of EP doesn't blind the probe. Falls back to EP for
                 ;; a single-node cluster.
                 (obs   (or (find (lambda (a) (not (equal? a ep))) addrs) ep))
                 (cfg   (tf-output-raw tf-bin workdir (caddr n)))
                 (file  (string-append "/tmp/hexol-talos-" label ".yaml")))
            (write-file file cfg)
            (cond
              (dry?
               (log ";; talos[dry]: ~a — apply-config --dry-run via ~a~%" label ep)
               (run* tc-bin "--talosconfig" talosconfig "-n" ep "-e" ep
                     "apply-config" "--dry-run" "--file" file))
              (else
               (log ";; talos: applying config to ~a (~a), mode ~a~%" label ep mode)
               (run* tc-bin "--talosconfig" talosconfig "-n" ep "-e" ep
                     "apply-config" "--mode" mode "--file" file)
               (log ";; talos: waiting for cluster health via ~a (timeout ~a)…~%" obs health-timeout)
               (run* tc-bin "--talosconfig" talosconfig "-e" obs "-n" obs
                     "health" "--wait-timeout" health-timeout)
               (log ";; talos: ~a healthy~%" label)))
            (loop (cdr ns) (+ i 1))))))))

;; ---------- kubectl applier ----------

;; Float Namespaces then CRDs to the front, so a kind's CRD lands before any
;; custom resource of it, and a namespace before resources scoped into it.
;; (`filter` is stable; order within each group is preserved.)
(define (order-resources rs)
  (let ((kind-is (lambda (k) (lambda (r) (equal? (assq-ref r 'kind) k)))))
    (append (filter (kind-is "Namespace") rs)
            (filter (kind-is "CustomResourceDefinition") rs)
            (filter (lambda (r)
                      (not (member (assq-ref r 'kind)
                                   '("Namespace" "CustomResourceDefinition"))))
                    rs))))

;; Pipe YAML to `kubectl ARGS` (which include `apply … -f -`); return the exit
;; code, letting the caller decide whether a non-zero pass is fatal.
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
