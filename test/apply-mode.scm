;;; test/apply-mode.scm — applier mode dispatch (apply | plan | diff) and the
;;; structural differ, against PATH shims in test/fixtures/bin (no cluster, no
;;; tofu).  Run: guile -L . test/apply-mode.scm   (or `make test`)
;;;
;;; The shims log their argv to $FAKE_LOG and exit per FAKE_*_EXIT, so a test
;;; asserts which subcommand a mode reached for and what its exit code meant.

(add-to-load-path (dirname (dirname (current-filename))))

(use-modules (hexol apply)
             (hexol diff)
             (ice-9 textual-ports)
             (ice-9 format)
             (srfi srfi-1))

(define failures 0)

(define-syntax expect
  (syntax-rules ()
    ((_ desc expected actual)
     (let ((e expected) (a actual))
       (if (equal? e a)
           (format #t "  ok   ~a~%" desc)
           (begin
             (set! failures (+ failures 1))
             (format #t "  FAIL ~a~%       expected: ~s~%       got:      ~s~%"
                     desc e a)))))))

;; ---- harness: shims first on PATH, a fresh log per run ----

(define here (dirname (current-filename)))
(setenv "PATH" (string-append here "/fixtures/bin:" (getenv "PATH")))

(define tmp (or (getenv "TMPDIR") "/tmp"))
(define log-file (string-append tmp "/hexol-test-apply-" (number->string (getpid)) ".log"))
(define workdir  (string-append tmp "/hexol-test-tf-" (number->string (getpid))))
(setenv "FAKE_LOG" log-file)

(define (reset-log!) (when (file-exists? log-file) (delete-file log-file)))
(define (log-lines)
  (if (file-exists? log-file)
      (string-split (string-trim-right (call-with-input-file log-file get-string-all)) #\newline)
      '()))
(define (logged? substr) (and (any (lambda (l) (string-contains l substr)) (log-lines)) #t))

;; Run THUNK with stderr silenced (the appliers' progress lines) and stdout
;; captured; return (values result stdout-text).
(define (quiet thunk)
  (let* ((out "")
         (res (with-output-to-string
                (lambda ()
                  (set! out (with-error-to-port (open-output-string) thunk))))))
    (values out res)))

(define (run-quiet thunk)
  (call-with-values (lambda () (quiet thunk)) (lambda (res text) res)))

(define (error-message thunk)
  (catch #t
    (lambda () (run-quiet thunk) #f)
    (lambda (key . args) (if (eq? key 'quit) (throw key) (cadr args)))))

(define k8s-state
  '((kubernetes_resources
     ((apiVersion . "apps/v1") (kind . "Deployment")
      (metadata (name . "tintin") (namespace . "tintin"))
      (spec (replicas . 2)
            (template (spec (containers ((name . "web") (image . "nginx:1.27"))))))))))

(define tf-state '((terraform_config (resource (null_resource (x))))))

(format #t "~%apply: mode-of~%")
(expect "symbol passes through" 'diff  (mode-of 'diff))
(expect "#t is plan (legacy dry?)" 'plan  (mode-of #t))
(expect "#f is apply"             'apply (mode-of #f))

(format #t "~%apply: kubectl applier by mode~%")
(reset-log!)
(run-quiet (lambda () ((kubectl-applier) k8s-state 'plan)))
(expect "plan -> --dry-run=server" #t (logged? "--dry-run=server"))
(reset-log!)
(run-quiet (lambda () ((kubectl-applier) k8s-state #t)))
(expect "legacy #t -> plan" #t (logged? "--dry-run=server"))
(reset-log!)
(run-quiet (lambda () ((kubectl-applier #:kubeconfig "kc") k8s-state 'apply)))
(expect "apply -> kubectl apply --server-side" #t (logged? "--kubeconfig=kc apply --server-side"))
(expect "apply never diffs" #f (logged? "kubectl diff"))

(setenv "FAKE_DIFF_EXIT" "1")
(reset-log!)
(expect "diff exit 1 -> drift" 'drift (run-quiet (lambda () ((kubectl-applier) k8s-state 'diff))))
(expect "diff -> kubectl diff -f -" #t (logged? "kubectl diff --server-side --force-conflicts -f -"))
(setenv "FAKE_DIFF_EXIT" "0")
(expect "diff exit 0 -> clean" #f (run-quiet (lambda () ((kubectl-applier) k8s-state 'diff))))
(setenv "FAKE_DIFF_EXIT" "3")
(expect "diff exit >1 -> error" #t
       (string? (error-message (lambda () ((kubectl-applier) k8s-state 'diff)))))
(unsetenv "FAKE_DIFF_EXIT")

(format #t "~%apply: ansible applier~%")
(define ans-state
  '((ansible_plays (web1 (hosts . "web1") (tasks ((name . "x")))))))
(define ans-inv
  '((hosts (web1 (vars (ip . "10.0.0.1"))))
    (groups (all (hosts web1) (vars (tz . "UTC"))) (web (hosts web1)))))
(define ans-dir (string-append tmp "/hexol-test-ans-" (number->string (getpid))))
(reset-log!)
(run-quiet (lambda () ((ansible-applier #:workdir ans-dir #:inventory ans-inv) ans-state 'apply)))
(expect "apply -> ansible-playbook -i inventory playbook" #t
        (logged? (string-append "-i " ans-dir "/inventory.json " ans-dir "/playbook.json")))
(expect "inventory written in ansible shape" #t
        (number? (string-contains (call-with-input-file (string-append ans-dir "/inventory.json") get-string-all)
                         "\"children\":{\"web\":{\"hosts\":{\"web1\":{}}")))
(reset-log!)
(parameterize ((applier-args '("--list-tasks" "--limit" "web1")))
  (run-quiet (lambda () ((ansible-applier #:workdir ans-dir #:inventory "inv.yml") ans-state 'plan))))
(expect "plan + passthrough flags" #t (logged? "-i inv.yml"))
(expect "plan -> --check --diff, then applier-args" #t (logged? "--check --diff --list-tasks --limit web1"))
(expect "diff refused" #t
        (string? (error-message (lambda () ((ansible-applier #:inventory "i") ans-state 'diff)))))

(format #t "~%apply: kubectl explained diff (structural, via kubectl get)~%")
(define live-json (string-append tmp "/hexol-test-live-" (number->string (getpid)) ".json"))
(call-with-output-file live-json
  (lambda (p)
    (display "{\"apiVersion\":\"apps/v1\",\"kind\":\"Deployment\",
              \"metadata\":{\"name\":\"tintin\",\"namespace\":\"tintin\",\"uid\":\"abc\"},
              \"spec\":{\"replicas\":3,\"template\":{\"spec\":{\"containers\":
                [{\"name\":\"web\",\"image\":\"nginx:1.26\",\"imagePullPolicy\":\"Always\"}]}}},
              \"status\":{\"readyReplicas\":3}}" p)))
(setenv "FAKE_GET_JSON" live-json)
(define explained '())
(reset-log!)
(call-with-values
  (lambda ()
    (quiet (lambda ()
             (parameterize ((current-diff-explainer
                             (lambda (path) (set! explained (cons path explained)))))
               ((kubectl-applier) k8s-state 'diff)))))
  (lambda (result text)
    (expect "explained diff -> drift" 'drift result)
    (expect "fetches live object with kubectl get" #t
           (logged? "kubectl get -o json --ignore-not-found -n tintin Deployment tintin"))
    (expect "never runs kubectl diff" #f (logged? "kubectl diff"))
    (expect "hunk: replicas live -> desired" #t
           (and (string-contains text "~ Deployment/tintin (ns tintin) spec.replicas: 3 -> 2") #t))
    (expect "hunk: container image drills into the list" #t
           (and (string-contains text "spec.template.spec.containers.0.image: \"nginx:1.26\" -> \"nginx:1.27\"") #t))
    (expect "explainer called per changed path, indexed into kubernetes_resources"
           '((kubernetes_resources 0 spec replicas)
             (kubernetes_resources 0 spec template spec containers 0 image))
           (reverse explained))))
(unsetenv "FAKE_GET_JSON")
(set! explained '())
(call-with-values
  (lambda ()
    (quiet (lambda ()
             (parameterize ((current-diff-explainer (lambda (path) (set! explained (cons path explained)))))
               ((kubectl-applier) k8s-state 'diff)))))
  (lambda (result text)
    (expect "missing live object -> drift, whole resource" 'drift result)
    (expect "  reported as not in cluster" #t
           (and (string-contains text "+ Deployment/tintin (ns tintin) (not in cluster)") #t))
    (expect "  explained at the resource path" '((kubernetes_resources 0)) explained)))
(delete-file live-json)

(format #t "~%apply: terraform applier by mode~%")
(setenv "FAKE_PLAN_EXIT" "2")
(reset-log!)
(expect "plan exit 2 -> drift" 'drift
       (run-quiet (lambda () ((terraform-applier #:workdir workdir) tf-state 'diff))))
(expect "plan -> tofu plan -detailed-exitcode" #t (logged? "tofu -chdir=" ))
(expect "  with -detailed-exitcode" #t (logged? "plan -detailed-exitcode"))
(expect "  never applies" #f (logged? " apply"))
(setenv "FAKE_PLAN_EXIT" "0")
(expect "plan exit 0 -> clean (mode plan)" #f
       (run-quiet (lambda () ((terraform-applier #:workdir workdir) tf-state 'plan))))
(setenv "FAKE_PLAN_EXIT" "1")
(expect "plan exit 1 -> error" #t
       (string? (error-message (lambda () ((terraform-applier #:workdir workdir) tf-state 'plan)))))
(unsetenv "FAKE_PLAN_EXIT")
(reset-log!)
(run-quiet (lambda () ((terraform-applier #:workdir workdir) tf-state 'apply)))
(expect "apply -> tofu apply" #t (logged? " apply"))
(expect "  no plan under apply" #f (logged? " plan"))

(format #t "~%apply: checks under plan/diff~%")
(define pred-calls 0)
(define counting (lambda (state) (set! pred-calls (+ pred-calls 1)) #t))
(run-quiet (lambda () ((check "x" counting) '() 'diff)))
(run-quiet (lambda () ((check "x" counting) '() 'plan)))
(run-quiet (lambda () ((wait-for "x" counting) '() 'diff)))
(expect "check/wait-for skip their predicate under plan/diff" 0 pred-calls)
(run-quiet (lambda () ((check "x" counting) '() 'apply)))
(expect "check runs it under apply" 1 pred-calls)
(expect "report runs under diff" "ran"
       (let ((seen #f))
         (run-quiet (lambda () ((report "r" (lambda (s) (set! seen "ran"))) '() 'diff)))
         seen))

(format #t "~%apply: kubeconform-check~%")
(reset-log!)
(expect "exit 0 -> ok" #f
       (error-message (lambda () ((kubeconform-check) k8s-state 'plan))))
(expect "  pipes to kubeconform -strict -summary" #t (logged? "kubeconform -strict -summary"))
(setenv "FAKE_KUBECONFORM_EXIT" "1")
(expect "exit 1 -> error" #t
       (string? (error-message (lambda () ((kubeconform-check) k8s-state 'diff)))))
(expect "exit 1, #:fatal? #f -> warns only" #f
       (error-message (lambda () ((kubeconform-check #:fatal? #f) k8s-state 'apply))))
(unsetenv "FAKE_KUBECONFORM_EXIT")

(format #t "~%diff: structural-diff~%")
(expect "equal -> no hunks" '() (structural-diff '((a . 1)) '((a . 1) (b . 2))))
(expect "changed leaf" '(((a b) 1 2)) (structural-diff '((a (b . 2))) '((a (b . 1)))))
(expect "absent live -> #f live value" '(((a) #f 2)) (structural-diff '((a . 2)) '((z . 1))))
(expect "scalars compare by print form" '() (structural-diff '((port . 80)) '((port . "80"))))
(expect "equal-length lists compare element-wise"
       '(((xs 1 n) 2 3)) (structural-diff '((xs ((n . 1)) ((n . 3)))) '((xs ((n . 1)) ((n . 2))))))
(expect "different-length lists are one leaf"
       '(((xs) (1) (1 2))) (structural-diff '((xs 1 2)) '((xs 1))))
(expect "json->state: symbol keys, lists, null kept"
       '((a 1 ((b . null))))
       (json->state "{\"a\":[1,{\"b\":null}]}"))

(reset-log!)
(format #t "~%~a~%"
        (if (zero? failures)
            "all checks passed"
            (format #f "~a failure(s)" failures)))
(exit (if (zero? failures) 0 1))
