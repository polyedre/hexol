;;; test/import.scm — round-trip tests for `hexol import` ((hexol import)).
;;; Run: guile -L . test/import.scm   (or `make test`)
;;;
;;; An imported inventory must render to what it was imported from:
;;;   examples/kubernetes.scm -> yaml     -> import (plain and --sugar) -> resolve
;;;   examples/terraform.scm  -> tf.json  -> import                     -> resolve
;;; and the resolved accumulators compare equal with maps order-insensitive
;;; (`same-shape?`) — key order is not semantics in YAML or JSON.

(add-to-load-path (dirname (dirname (current-filename))))

(use-modules (hexol kernel)
             (hexol yaml)
             (hexol terraform)
             (hexol import)
             (ice-9 format)
             (ice-9 textual-ports))

(define failures 0)

(define-syntax check
  (syntax-rules ()
    ((_ desc expected actual)
     (let ((e expected) (a actual))
       (if (equal? e a)
           (format #t "  ok   ~a~%" desc)
           (begin
             (set! failures (+ failures 1))
             (format #t "  FAIL ~a~%       expected: ~s~%       got:      ~s~%"
                     desc e a)))))))

;; Write TEXT to a fresh temp file, return its path.
(define (temp-file text suffix)
  (let* ((port (mkstemp (string-append (or (getenv "TMPDIR") "/tmp") "/hexol-import-XXXXXX")))
         (tmp  (port-filename port))
         (path (string-append tmp suffix)))
    (display text port)
    (close-port port)
    (rename-file tmp path)
    path))

;; Import TEXT with IMPORT (a text -> inventory-text proc), load the result as
;; an inventory and return the resolved state.
(define (round-trip import text)
  (let* ((path  (temp-file (import text) ".scm"))
         (state (resolve (load-inventory-file path) '())))
    (delete-file path)
    state))

(define (resolve-example file)
  (resolve (load-inventory-file file) '()))

;; ---------- k8s ----------

(format #t "~%import: k8s manifests round-trip~%")

(define k8s-state (resolve-example "examples/kubernetes.scm"))
(define k8s-resources (state-get k8s-state '(kubernetes_resources)))
(define k8s-yaml
  (call-with-output-string (lambda (p) (emit-yaml-stream p k8s-resources))))

(define (k8s-back . opts)
  (state-get (round-trip (lambda (t) (apply import-yaml t opts)) k8s-yaml)
             '(kubernetes_resources)))

(check "yaml documents parsed = resources rendered"
       (length k8s-resources) (length (read-yaml-documents k8s-yaml)))
(check "plain import resolves to the same resources"
       #t (same-shape? k8s-resources (k8s-back)))
(check "--sugar import resolves to the same resources"
       #t (same-shape? k8s-resources (k8s-back #:sugar? #t)))
(check "--sugar lifts exact fits to typed constructs"
       #t (and (string-contains (import-yaml k8s-yaml #:sugar? #t) "(configmap") #t))
(check "document order preserved"
       (map (lambda (r) (assq-ref r 'kind)) k8s-resources)
       (map (lambda (r) (assq-ref r 'kind)) (k8s-back)))

;; A workload the constructs built verbatim lifts back to them — every
;; deployment field the lift handles, and a non-default Service.
(define lift-inventory
  (temp-file "(use-modules (hexol k8s))
(hx-ops
  (with-namespace \"api\"
    (deployment \"api\" (image \"ghcr.io/acme/api:1\") (port 9090) (replicas 3)
      (service-account \"api\") (args \"--verbose\") (privileged)
      (env '((name . \"MODE\") (value . \"prod\")))
      (env-from (cm \"api-config\") (sec \"api-secret\"))
      (volumes (mount (sec \"api-tls\") \"/etc/tls\" #:read-only #t) (mount (pvc \"data\") \"/data\"))
      (resources \"100m-500m/128Mi\") (labels (tier \"web\")))
    (service \"api\" (port 80) (target-port 9090) (port-name \"web\") (type \"NodePort\"))
    (secret \"api-tls\" (type \"kubernetes.io/tls\") (string-data (tls.crt \"x\")))))"
             ".scm"))
(define lift-resources (state-get (resolve-example lift-inventory) '(kubernetes_resources)))
(delete-file lift-inventory)
(define lift-yaml (call-with-output-string (lambda (p) (emit-yaml-stream p lift-resources))))
(define lifted-text (import-yaml lift-yaml #:sugar? #t))
;; (pretty-print may break the head and name onto separate lines.)
(check "--sugar lifts a construct-built Deployment"
       #t (and (string-contains lifted-text "(deployment") #t))
(check "--sugar lifts a non-default Service and a tls Secret"
       #t (and (string-contains lifted-text "(service")
               (string-contains lifted-text "(secret") #t))
(check "--sugar keeps no `resource` fallback when everything fits"
       #f (string-contains lifted-text "(resource\n"))
(check "lifted inventory resolves to the same resources"
       #t (same-shape? lift-resources
                       (state-get (round-trip (lambda (t) (import-yaml t #:sugar? #t)) lift-yaml)
                                  '(kubernetes_resources))))

;; Scalar typing: quoted strings stay strings, plain scalars get typed.
(define typed
  (car (read-yaml-documents
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\ndata:\n  PORT: \"8080\"\n  ON: 'true'\nreplicas: 3\nflag: true\nnothing: null\n")))
(check "quoted number stays a string"  "8080" (state-get typed '(data PORT)))
(check "quoted bool stays a string"    "true" (state-get typed '(data ON)))
(check "plain integer is a number"     3      (state-get typed '(replicas)))
(check "plain bool is a boolean"       #t     (state-get typed '(flag)))
(check "null-valued key is dropped"    #f     (assq 'nothing typed))

;; --clean strips the server-populated fields of a `kubectl get` dump.
(define dumped
  '((apiVersion . "v1") (kind . "ConfigMap")
    (metadata (name . "c") (uid . "abc") (resourceVersion . "12") (creationTimestamp . "t")
              (managedFields ((manager . "kubectl")))
              (annotations (kubectl.kubernetes.io/last-applied-configuration . "{}")))
    (data (K . "v"))
    (status (phase . "x"))))
(check "clean strips runtime metadata and status"
       '((apiVersion . "v1") (kind . "ConfigMap") (metadata (name . "c")) (data (K . "v")))
       (clean-k8s-object dumped))

;; ---------- terraform ----------

(format #t "~%import: terraform JSON round-trip~%")

;; examples/terraform.scm reads ~/.ssh/*.pub at load; give it one if the
;; environment has none (CI).
(let ((home (or (getenv "HOME") ".")))
  (unless (or (file-exists? (string-append home "/.ssh/id_ed25519.pub"))
              (file-exists? (string-append home "/.ssh/id_rsa.pub")))
    (let ((fake (string-append (or (getenv "TMPDIR") "/tmp") "/hexol-import-home")))
      (system* "mkdir" "-p" (string-append fake "/.ssh"))
      (call-with-output-file (string-append fake "/.ssh/id_ed25519.pub")
        (lambda (p) (display "ssh-ed25519 AAAA test\n" p)))
      (setenv "HOME" fake))))

(define tf-config (state-get (resolve-example "examples/terraform.scm") '(terraform_config)))
(define tf-back
  (state-get (round-trip (lambda (t) (import-terraform-json t)) (terraform->json tf-config))
             '(terraform_config)))

(check "terraform import resolves to the same config"
       #t (same-shape? tf-config tf-back))
(check "terraform blocks keep their kind"
       (map car tf-config) (map car tf-back))

(format #t "~%~a~%"
        (if (zero? failures)
            "all checks passed"
            (format #f "~a failure(s)" failures)))
(exit (if (zero? failures) 0 1))
