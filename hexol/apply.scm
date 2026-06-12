;;; hexol/apply.scm — appliers: push the resolved state to the world.
;;;
;;; `render` turns an inventory into artifacts and stops; this module is the
;;; other half — the procedures that take a *resolved state* and actually
;;; apply it. They are deliberately the only place hexol shells out to act on
;;; the world (`tofu`, `kubectl`); the `(hexol terraform)` / `(hexol k8s)`
;;; libraries stay pure language-to-data translators.
;;;
;;; Each exported constructor builds an *applier* — a `(state dry? -> effects)`
;;; procedure — and registers it under a name (the `#:name' key, with a sensible
;;; default) via the kernel's `applies-with', so the inventory just *calls* the
;;; constructor at top level; there is no separate wrapper. The CLI's `hexol
;;; apply` resolves the inventory once, runs the registered appliers in
;;; registration order (optionally filtered to `--only NAME'), and calls each
;;; with the shared state and the `--dry-run' flag. So the appliers run *from
;;; the state*, in order, and only under `apply' — never during render/tree/ops,
;;; where the collector is unbound and registration is a harmless no-op.
;;;
;;;   (terraform-applier #:workdir "deploy" #:binary "tofu"
;;;                      #:output->file '(("kubeconfig" . "deploy/kubeconfig")))
;;;   (kubectl-applier #:kubeconfig "deploy/kubeconfig")
;;;
;;; #:name defaults to "terraform" / "kubernetes"; pass it explicitly to
;;; register more than one applier of a kind, or #:order to override the default
;;; registration order. (`applies-with' is still the primitive underneath — use
;;; it directly to register a one-off inline `(state dry? -> effects)' lambda.)
;;;
;;; Registration order is what makes this a one-command bootstrap: terraform is
;;; registered first, so the infra is built and its kubeconfig dumped to a
;;; known path before the cluster applier reads (kubernetes_resources) and
;;; `kubectl apply`s it against that file.
;;; The hand-off is an explicit conventional path, so each applier stays an
;;; independent (state -> effects) with no hidden state threading.

(define-module (hexol apply)
  #:use-module (hexol kernel)
  #:use-module ((hexol terraform) #:select (emit-terraform-json))
  #:use-module ((hexol yaml) #:select (emit-yaml-stream))
  #:use-module (hexol sh)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:export (terraform-applier kubectl-applier))

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

;; ---------- terraform applier ----------

(define* (terraform-applier #:key (name "terraform") (order #f)
                            (workdir "deploy") (binary "tofu")
                            (config-file "infra.tf.json") (output->file '()))
  "Register an applier for the (terraform_config) subtree under NAME (default
\"terraform\"): write WORKDIR/CONFIG-FILE, `BINARY -chdir=WORKDIR init`, then
`plan` (when DRY?) or `apply`.  After a real apply, every (OUTPUT . FILE) pair
in OUTPUT->FILE is written from `BINARY -chdir=WORKDIR output -raw OUTPUT` — the
cred hand-off, e.g. (\"kubeconfig\" . \"deploy/kubeconfig\").  BINARY defaults
to `tofu`; pass #:binary \"terraform\" for stock Terraform.  #:order overrides
the default registration order; outside `hexol apply' this is a no-op."
  (applies-with name
    (lambda (state dry?)
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
             output->file)))))
    order))

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

(define* (kubectl-applier #:key (name "kubernetes") (order #f)
                          (binary "kubectl") (kubeconfig #f)
                          (server-side #t) (passes 2))
  "Register an applier for (kubernetes_resources) under NAME (default
\"kubernetes\"): render the manifest stream — Namespaces and CRDs floated to
the front — and `kubectl apply` it.  With DRY?, runs one `--dry-run=server`
pass.  Otherwise applies up to PASSES times (default 2): a custom resource
whose CRD is created earlier in the *same* run fails the first pass (kubectl
caches API types per invocation), so a second pass — not a wait — lands it.
CRDs created out of band (e.g. cert-manager's, installed later by Flux)
converge on a subsequent `hexol apply --only kubernetes`.  #:kubeconfig sets
--kubeconfig; #:server-side toggles --server-side (the default — big CRD
bundles exceed client-side apply's annotation-size limit); #:order overrides
the default registration order."
  (applies-with name
    (lambda (state dry?)
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
                       n)))))))))
    order))
