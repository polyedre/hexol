;;; hexol/k8s.scm — the Kubernetes library.
;;;
;;; A `(hexol k8s)` submodule: sugar constructors that each return a
;;; `resource` op (so they drop straight into an `(inventory ...)`), plus
;;; the composites and cross-cutting transforms that were previously
;;; inlined in examples/kubernetes.scm.
;;;
;;; Resource sugar (each returns one op):
;;;   (deployment #:name #:image ...)   -> Deployment
;;;   (daemonset  #:name #:image ...)   -> DaemonSet
;;;   (service    #:name #:port ...)    -> Service
;;;   (ingress    #:name #:port ...)    -> Ingress
;;;   (configmap  #:name #:data ...)    -> ConfigMap
;;;   (secret     #:name #:data ...)    -> Secret
;;;   (custom-resource #:api #:kind ...) -> any CRD (Prometheus, etc.)
;;;   (service-monitor #:name ...)      -> monitoring.coreos.com ServiceMonitor
;;;
;;; Composites (return a compose-ops bundle of several resources):
;;;   (app ...) (public-app ...) (worker ...)
;;;
;;; Transforms / policy (return ops over the resource list):
;;;   (tls-all) (checksum-config) (compliance-all registry)
;;;
;;; Selector convention: every workload/service keys on (app . <name>);
;;; layer org-wide labels on top with surface's `label-all`.

(define-module (hexol k8s)
  #:use-module (hexol kernel)
  #:use-module (hexol surface)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:re-export (resource transform-resources annotate-all label-all
               compose-ops)
  #:export (;; namespace scope
            with-namespace current-k8s-namespace namespace
            ;; compact resources spec
            res
            ;; resource sugar
            deployment daemonset service ingress configmap secret
            custom-resource service-monitor
            ;; RBAC
            service-account role role-binding
            cluster-role cluster-role-binding cluster-rbac
            ;; external manifests (render-time splice into kubernetes_resources)
            which-cmd json-manifests remote-manifest
            ;; composites
            app public-app worker
            ;; derive a Service from a workload
            expose service-from-workload
            ;; cross-cutting transforms / policy
            tls-all checksum-config
            compliance-check compliance-all
            check-resources-set check-cpu-limit-ge-request
            check-memory-limit-equals-request check-image-registry
            check-no-privileged))

;; ---------------------------------------------------------------------------
;; namespace scope
;; ---------------------------------------------------------------------------
;;
;; Every constructor defaults its #:namespace to (current-k8s-namespace).
;; `with-namespace` binds that parameter while the body's ops are
;; *constructed* — the namespace bakes into each resource alist at build
;; time — then bundles them into one op (so it nests, composes inside a
;; `when`, and inner scopes win lexically). An explicit #:namespace on a
;; constructor still overrides.
;;
;;   (with-namespace "monitoring"
;;     (deployment #:name "grafana" #:image "grafana:11")   ; -> ns monitoring
;;     (when (on? '(x)) (service #:name "grafana" #:port 80)))

(define current-k8s-namespace (make-parameter "default"))

;; A Namespace resource named NAME (with the conventional
;; kubernetes.io/metadata.name label, plus any extra #:labels).
(define* (namespace name #:key (labels '()))
  "Return a resource op for a Namespace named NAME."
  (resource `((apiVersion . "v1") (kind . "Namespace")
              (metadata (name . ,name)
                        (labels (kubernetes.io/metadata.name . ,name) ,@labels)))))

;; Build-time scope over the kernel's `scope-ops`: bind the namespace while
;; the body's resources are constructed, then bundle them into one op. The
;; Namespace itself is *prepended* to the bundle, so scoping a body into a
;; namespace also creates it — and it lands in the rendered stream before the
;; resources scoped into it (`kubectl apply -f -` sees the namespace first).
;; Callers therefore needn't declare the namespace separately; scope each
;; namespace in exactly one `with-namespace` to avoid a duplicate Namespace.
(define-syntax-rule (with-namespace ns body ...)
  (scope-ops 'with-namespace (current-k8s-namespace ns) "namespace "
    (namespace ns) body ...))

;; ---------------------------------------------------------------------------
;; compact resources spec
;; ---------------------------------------------------------------------------
;;
;; `(res "CPU/MEM")` -> a k8s resources alist. Each side is "req" or
;; "req-lim"; `*` (or empty) omits that bound. A MEM side with no "-" sets
;; limit = request (memory limit should equal request); a CPU side with no
;; "-" leaves the limit unset (best practice — and our compliance rule
;; allows an unset cpu limit). Examples:
;;
;;   (res "100m-*/128Mi")       => requests cpu 100m, mem 128Mi; limit mem 128Mi
;;   (res "100m-500m/128Mi-256Mi") => requests cpu 100m mem 128Mi; limits cpu 500m mem 256Mi
;;   (res "*/256Mi")            => requests mem 256Mi; limit mem 256Mi (no cpu)
;;
;; Anywhere a constructor takes #:resources, a string is parsed through
;; `res`; an alist is used as-is.

(define (%bound part single-copies?)
  ;; -> (request-or-#f . limit-or-#f)
  (let* ((toks (string-split part #\-))
         (norm (lambda (t) (if (or (string=? t "*") (string=? t "")) #f t)))
         (req  (norm (car toks)))
         (lim  (cond ((> (length toks) 1) (norm (cadr toks)))
                     (single-copies? req)
                     (else #f))))
    (cons req lim)))

(define (res spec)
  "Parse a compact resources SPEC string \"CPU/MEM\" into a k8s resources
alist.  Each side is \"req\" or \"req-lim\"; `*' or empty omits a bound.  A
MEM side without \"-\" sets limit = request; a CPU side without \"-\" leaves
the limit unset.  E.g. \"100m-500m/128Mi-256Mi\"."
  (let* ((sides (string-split spec #\/))
         (cpu (%bound (list-ref sides 0) #f))
         (mem (%bound (if (> (length sides) 1) (list-ref sides 1) "*") #t))
         (mk  (lambda (sel)
                (filter pair?
                        (list (and (sel cpu) (cons 'cpu    (sel cpu)))
                              (and (sel mem) (cons 'memory (sel mem)))))))
         (requests (mk car))
         (limits   (mk cdr)))
    (concatenate
      (list (if (null? requests) '() (list (cons 'requests requests)))
            (if (null? limits)   '() (list (cons 'limits   limits)))))))

(define (normalize-resources r)
  (if (string? r) (res r) r))

;; ---------------------------------------------------------------------------
;; shared building blocks
;; ---------------------------------------------------------------------------

;; `namespace` #f omits the field — for cluster-scoped resources
;; (ClusterRole, ClusterRoleBinding).
(define* (k8s-metadata name namespace #:optional (extra-labels '()))
  `(,@(if namespace `((namespace . ,namespace)) '())
    (name . ,name)
    (labels (app . ,name) ,@extra-labels)))

;; env-from is a list of refs like '((configMap "api-config") (secret "api-secret"))
(define (envFrom-entries refs)
  (map (lambda (ref)
         (let ((kind (car ref)) (n (cadr ref)))
           (cond ((eq? kind 'configMap) `((configMapRef (name . ,n))))
                 ((eq? kind 'secret)    `((secretRef    (name . ,n))))
                 (else (error "unknown env-from kind:" kind)))))
       refs))

;; volumes is a list like
;;   '((configMap "api-config" "/etc/api") (secret "api-secret" "/etc/sec")
;;     (pvc "data" "/var/lib/data"))
(define (volume-name kind res-name)
  (string-append (symbol->string kind) "-" res-name))

(define (volume-entries refs)
  (map (lambda (ref)
         (let ((kind (car ref)) (n (cadr ref)))
           (cond ((eq? kind 'configMap)
                  `((name . ,(volume-name kind n)) (configMap (name . ,n))))
                 ((eq? kind 'secret)
                  `((name . ,(volume-name kind n)) (secret (secretName . ,n))))
                 ((eq? kind 'pvc)
                  `((name . ,(volume-name kind n)) (persistentVolumeClaim (claimName . ,n))))
                 (else (error "unknown volume kind:" kind)))))
       refs))

(define (volumeMount-entries refs)
  (map (lambda (ref)
         (let ((kind (car ref)) (n (cadr ref)) (path (caddr ref)))
           `((name . ,(volume-name kind n)) (mountPath . ,path))))
       refs))

;; One container's alist. Optional sections are omitted when empty, so the
;; rendered YAML stays clean (no `envFrom: {}` etc.).
;; `env` is a list of raw container env entries spliced as-is, e.g.
;;   '(((name . "DOMAIN") (value . "https://…"))
;;     ((name . "POD_NS") (valueFrom (fieldRef (fieldPath . "metadata.namespace")))))
;; — for individual variables (and valueFrom refs); whole-source injection is
;; `env-from`.
(define* (container-alist #:key name image (port 0) (args '()) (command '())
                          (env '()) (env-from '()) (volumes '()) (resources '())
                          (privileged #f))
  (let ((resources (normalize-resources resources)))   ; "100m-*/128Mi" or alist
    `((name . ,name)
      (image . ,image)
      ,@(if (null? command) '() `((command ,@command)))
      ,@(if (null? args)    '() `((args ,@args)))
      ,@(if (and (number? port) (> port 0)) `((ports ((containerPort . ,port)))) '())
      ,@(if (null? env)      '() `((env ,@env)))
      ,@(if (null? env-from) '() `((envFrom ,@(envFrom-entries env-from))))
      ,@(if (null? volumes)  '() `((volumeMounts ,@(volumeMount-entries volumes))))
      ,@(if (null? resources) '() `((resources ,@resources)))
      ,@(if privileged `((securityContext (privileged . #t))) '()))))

;; A Deployment / DaemonSet body. `replicas` #f omits the field (DaemonSets
;; have no replicas).
(define* (workload-alist #:key kind name image (port 0) (replicas #f)
                         (namespace (current-k8s-namespace)) (env '()) (env-from '()) (volumes '())
                         (resources '()) (privileged #f) (args '()) (command '())
                         (service-account #f) (host-network #f) (host-pid #f)
                         (labels '()))
  `((apiVersion . "apps/v1")
    (kind . ,kind)
    (metadata ,@(k8s-metadata name namespace labels))
    (spec ,@(if replicas `((replicas . ,replicas)) '())
          (selector (matchLabels (app . ,name)))
          (template
            (metadata (labels (app . ,name) ,@labels))
            (spec ,@(if service-account `((serviceAccountName . ,service-account)) '())
                  ,@(if host-network `((hostNetwork . #t)) '())
                  ,@(if host-pid `((hostPID . #t)) '())
                  (containers ,(container-alist #:name name #:image image #:port port
                                                #:args args #:command command
                                                #:env env #:env-from env-from #:volumes volumes
                                                #:resources resources #:privileged privileged))
                  ,@(if (null? volumes) '() `((volumes ,@(volume-entries volumes)))))))))

;; ---------------------------------------------------------------------------
;; resource sugar
;; ---------------------------------------------------------------------------

(define* (deployment #:key name image (port 8080) (replicas 1) (namespace (current-k8s-namespace))
                     (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                     (args '()) (command '()) (service-account #f) (labels '()))
  "Return a resource op for a Deployment named NAME running IMAGE.  Accepts
the common pod knobs (#:port #:replicas #:namespace #:env #:env-from #:volumes
#:resources #:privileged #:args #:command #:service-account #:labels).  #:env
is a list of raw container env entries; #:volumes also accepts (pvc CLAIM PATH)
to mount a PersistentVolumeClaim."
  (resource (workload-alist #:kind "Deployment" #:name name #:image image #:port port
                            #:replicas replicas #:namespace namespace #:env env #:env-from env-from
                            #:volumes volumes #:resources resources #:privileged privileged
                            #:args args #:command command #:service-account service-account
                            #:labels labels)))

(define* (daemonset #:key name image (port 0) (namespace (current-k8s-namespace))
                    (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                    (args '()) (command '()) (service-account #f)
                    (host-network #f) (host-pid #f) (labels '()))
  "Return a resource op for a DaemonSet named NAME running IMAGE.  Like
`deployment' but with no replicas and with extra node-level knobs
(#:host-network #:host-pid)."
  (resource (workload-alist #:kind "DaemonSet" #:name name #:image image #:port port
                            #:replicas #f #:namespace namespace #:env env #:env-from env-from
                            #:volumes volumes #:resources resources #:privileged privileged
                            #:args args #:command command #:service-account service-account
                            #:host-network host-network #:host-pid host-pid #:labels labels)))

(define* (service #:key name port (target-port port) (port-name "http")
                  (namespace (current-k8s-namespace)) (type #f) (selector-name #f) (labels '()))
  "Return a resource op for a Service named NAME exposing PORT.  Selects
(app . NAME) by default (override with #:selector-name); #:target-port,
#:port-name, #:type, and #:labels tune the rest."
  (let ((sel (or selector-name name)))
    (resource
      `((apiVersion . "v1")
        (kind . "Service")
        (metadata ,@(k8s-metadata name namespace labels))
        (spec (selector (app . ,sel))
              ,@(if type `((type . ,type)) '())
              (ports ((name . ,port-name) (port . ,port) (targetPort . ,target-port))))))))

(define* (ingress #:key name port (host #f) (namespace (current-k8s-namespace)) (path "/") (labels '()))
  "Return a resource op for an Ingress named NAME routing HOST (defaulting
to \"NAME.example.com\") and PATH to the NAME Service on PORT."
  (let ((h (or host (string-append name ".example.com"))))
    (resource
      `((apiVersion . "networking.k8s.io/v1")
        (kind . "Ingress")
        (metadata ,@(k8s-metadata name namespace labels))
        (spec (rules ((host . ,h)
                      (http (paths ((path . ,path)
                                    (pathType . "Prefix")
                                    (backend (service (name . ,name)
                                                      (port (number . ,port))))))))))))))

(define* (configmap #:key name data (namespace (current-k8s-namespace)) (labels '()))
  "Return a resource op for a ConfigMap named NAME holding the alist DATA."
  (resource
    `((apiVersion . "v1")
      (kind . "ConfigMap")
      (metadata ,@(k8s-metadata name namespace labels))
      (data ,@data))))

(define* (secret #:key name data (namespace (current-k8s-namespace)) (type "Opaque") (labels '()))
  "Return a resource op for a Secret named NAME of TYPE (default \"Opaque\")
holding the alist DATA."
  (resource
    `((apiVersion . "v1")
      (kind . "Secret")
      (metadata ,@(k8s-metadata name namespace labels))
      (type . ,type)
      (data ,@data))))

;; Generic custom resource (CRD instance). `spec` is the spec alist.
(define* (custom-resource #:key api kind name (namespace (current-k8s-namespace)) (spec '()) (labels '()))
  "Return a resource op for an arbitrary CRD instance of API/KIND named
NAME with the given SPEC alist."
  (resource
    `((apiVersion . ,api)
      (kind . ,kind)
      (metadata ,@(k8s-metadata name namespace labels))
      (spec ,@spec))))

;; A prometheus-operator ServiceMonitor selecting (app . <name>).
(define* (service-monitor #:key name (port "http") (path "/metrics")
                          (interval "30s") (namespace (current-k8s-namespace)) (labels '()))
  "Return a resource op for a prometheus-operator ServiceMonitor named NAME
that scrapes PORT at PATH every INTERVAL, selecting (app . NAME)."
  (custom-resource
    #:api "monitoring.coreos.com/v1" #:kind "ServiceMonitor"
    #:name name #:namespace namespace #:labels labels
    #:spec `((selector (matchLabels (app . ,name)))
             (endpoints ((port . ,port) (path . ,path) (interval . ,interval))))))

;; ---------------------------------------------------------------------------
;; RBAC
;; ---------------------------------------------------------------------------
;;
;; A `policy-rule` is a plain alist, e.g.
;;   `((apiGroups "") (resources "pods" "services") (verbs "get" "list" "watch"))
;; `cluster-role`'s #:rules is a list of those.

(define* (service-account #:key name (namespace (current-k8s-namespace)) (labels '()))
  "Return a resource op for a ServiceAccount named NAME."
  (resource
    `((apiVersion . "v1")
      (kind . "ServiceAccount")
      (metadata ,@(k8s-metadata name namespace labels)))))

(define* (role #:key name (namespace (current-k8s-namespace)) (rules '()) (labels '()))
  "Return a resource op for a namespaced Role named NAME with the given policy
RULES (a list of rule alists).  The namespaced counterpart of `cluster-role'."
  (resource
    `((apiVersion . "rbac.authorization.k8s.io/v1")
      (kind . "Role")
      (metadata ,@(k8s-metadata name namespace labels))
      (rules ,@rules))))

(define* (role-binding #:key name (namespace (current-k8s-namespace)) role
                       service-account (sa-namespace namespace) (labels '()))
  "Return a resource op for a namespaced RoleBinding named NAME binding ROLE (a
Role in NAMESPACE) to SERVICE-ACCOUNT in SA-NAMESPACE.  The namespaced
counterpart of `cluster-role-binding'."
  (resource
    `((apiVersion . "rbac.authorization.k8s.io/v1")
      (kind . "RoleBinding")
      (metadata ,@(k8s-metadata name namespace labels))
      (roleRef (apiGroup . "rbac.authorization.k8s.io") (kind . "Role") (name . ,role))
      (subjects ((kind . "ServiceAccount") (name . ,service-account) (namespace . ,sa-namespace))))))

(define* (cluster-role #:key name (rules '()) (labels '()))
  "Return a resource op for a cluster-scoped ClusterRole named NAME with the
given policy RULES (a list of rule alists)."
  (resource
    `((apiVersion . "rbac.authorization.k8s.io/v1")
      (kind . "ClusterRole")
      (metadata ,@(k8s-metadata name #f labels))      ; cluster-scoped: no namespace
      (rules ,@rules))))

(define* (cluster-role-binding #:key name role service-account
                               (sa-namespace (current-k8s-namespace)) (labels '()))
  "Return a resource op for a ClusterRoleBinding named NAME binding ROLE (a
ClusterRole) to SERVICE-ACCOUNT in SA-NAMESPACE."
  (resource
    `((apiVersion . "rbac.authorization.k8s.io/v1")
      (kind . "ClusterRoleBinding")
      (metadata ,@(k8s-metadata name #f labels))
      (roleRef (apiGroup . "rbac.authorization.k8s.io") (kind . "ClusterRole") (name . ,role))
      (subjects ((kind . "ServiceAccount") (name . ,service-account) (namespace . ,sa-namespace))))))

;; Convenience: a ServiceAccount + ClusterRole + ClusterRoleBinding sharing
;; `name`, bundled into one op (so it slots into a `(when ...)` body).
(define* (cluster-rbac #:key name (rules '()) (namespace (current-k8s-namespace)) (labels '()))
  "Return one op bundling a ServiceAccount, ClusterRole (with RULES), and
ClusterRoleBinding all sharing NAME — slots into a (when …) body."
  (compose-ops 'cluster-rbac (list 'cluster-rbac name)
    (list (service-account #:name name #:namespace namespace #:labels labels)
          (cluster-role #:name name #:rules rules #:labels labels)
          (cluster-role-binding #:name name #:role name #:service-account name
                                #:sa-namespace namespace #:labels labels))))

;; ---------------------------------------------------------------------------
;; external manifests — splice resources produced at render time
;; ---------------------------------------------------------------------------
;;
;; These read an external input *while folding* (a real `resolve`, never
;; `tree`/`ops`) and append every Kubernetes manifest it yields to
;; (kubernetes_resources). `which-cmd` + `json-manifests` are the shared
;; plumbing; `remote-manifest` is the ready-made op for raw upstream YAML.
;; A consumer builds the others (a `helm template …` op, a `sops -d …` op) on
;; the same two helpers.

;; Absolute path of COMMAND on PATH, or #f. We resolve it ourselves (rather
;; than rely on the shell) so a `cmd | yq …` pipe can call binaries by absolute
;; path — robust even when PATH carries an unexpanded leading `~/` entry, which
;; a bare command name in a child shell would miss.
(define (which-cmd command)
  "Return the absolute path of COMMAND on PATH, or #f if not found/executable."
  (let* ((home   (or (getenv "HOME") ""))
         (expand (lambda (dir)
                   (if (string-prefix? "~/" dir) (string-append home (substring dir 1)) dir))))
    (find (lambda (f) (and (file-exists? f) (access? f X_OK)))
          (map (lambda (dir) (string-append (expand dir) "/" command))
               (string-split (or (getenv "PATH") "") #\:)))))

;; guile-json renders JSON objects as string-keyed alists, arrays as vectors,
;; and JSON null as the symbol `null`; resource alists use symbol keys and
;; lists — convert recursively. Tools emit `null` for empty maps / lists (e.g.
;; an unset `annotations:`), which would otherwise serialize back out as the
;; literal string "null"; drop those keys so the field is simply absent.
(define (json->resource x)
  (cond ((vector? x) (map json->resource (vector->list x)))
        ((and (pair? x) (pair? (car x)))                 ; object -> alist
         (filter-map (lambda (kv)
                       (and (not (eq? (cdr kv) 'null))
                            (cons (string->symbol (car kv)) (json->resource (cdr kv)))))
                     x))
        (else x)))                                        ; scalar / empty

;; Run CMD (which must print a JSON array of resource docs — typically
;; `… | yq ea -o=json '[.]'`) and return the manifests as a list of resource
;; alists (dropping the empty/comment docs yq emits as null). LABEL names it in
;; errors.
(define (json-manifests cmd label)
  "Run CMD (printing a JSON array of manifests) and return them as resource
alists.  Errors if CMD exits non-zero, blaming LABEL."
  (let* ((port   (open-input-pipe cmd))
         (output (get-string-all port))
         (status (close-pipe port)))
    (unless (zero? (status:exit-val status))
      (error "k8s: render command failed for" label))
    (let* ((parsed (json-string->scm output))
           (docs   (if (vector? parsed) (vector->list parsed) '())))
      (filter (lambda (r) (and (pair? r) (assq 'kind r)))
              (map json->resource docs)))))

;; Fetch a remote YAML manifest at URL and splice its documents into
;; (kubernetes_resources) — a fold-time op for raw upstream YAML (CRD bundles,
;; install manifests). LABEL names it in `tree` / errors. Skipped with a
;; warning if curl/yq aren't on PATH, so an inventory still renders without them.
(define (remote-manifest label url)
  "Return a fold-time op that fetches the YAML at URL with curl, converts it to
JSON with yq, and appends every manifest it yields to (kubernetes_resources)."
  (make-op 'remote-manifest `(remote-manifest ,label)
    (lambda (state)
      (let ((curl (which-cmd "curl")) (yq (which-cmd "yq")))
        (cond
          ((not (and curl yq))
           (format (current-error-port)
                   ";; k8s: curl/yq not on PATH — skipping ~a~%" label)
           state)
          (else
           (let* ((cmd (fmt "~a -sL ~a | ~a ea -o=json '[.]'" curl url yq))
                  (manifests (json-manifests cmd label)))
             (fold (lambda (r s) (apply-op (resource r) s)) state manifests))))))
    (string-append "remote-manifest " label)))

;; ---------------------------------------------------------------------------
;; composites
;; ---------------------------------------------------------------------------
;;
;; `compose-ops` (re-exported from the kernel) bundles several resource ops
;; into one op whose effect folds them; child ops are exposed via op-children
;; so introspection descends through it.

(define* (app #:key name image (port 8080) (replicas 2) (namespace (current-k8s-namespace))
              (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
              (service-account #f))
  "Return a bundle op for a typical internal app: a Deployment plus a
matching Service, both named NAME running IMAGE on PORT."
  (compose-ops 'app `(app ,name)
    (list (deployment #:name name #:image image #:port port #:replicas replicas
                      #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                      #:resources resources #:privileged privileged
                      #:service-account service-account)
          (service #:name name #:port port #:namespace namespace))))

(define* (public-app #:key name image (port 8080) (replicas 2) (namespace (current-k8s-namespace))
                     (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                     (service-account #f))
  "Return a bundle op for an internet-facing app: a Deployment, a Service,
and an Ingress, all named NAME running IMAGE on PORT."
  (compose-ops 'public-app `(public-app ,name)
    (list (deployment #:name name #:image image #:port port #:replicas replicas
                      #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                      #:resources resources #:privileged privileged
                      #:service-account service-account)
          (service #:name name #:port port #:namespace namespace)
          (ingress #:name name #:port port #:namespace namespace))))

(define* (worker #:key name image (replicas 1) (namespace (current-k8s-namespace))
                 (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                 (service-account #f))
  "Return a bundle op for a background worker: a Deployment named NAME
running IMAGE with no exposed port and no Service."
  (compose-ops 'worker `(worker ,name)
    (list (deployment #:name name #:image image #:port 0 #:replicas replicas
                      #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                      #:resources resources #:privileged privileged
                      #:service-account service-account))))

;; ---------------------------------------------------------------------------
;; expose — derive a Service from a workload.
;; ---------------------------------------------------------------------------
;;
;; `(expose (deployment ...))` folds the workload op, then reads the
;; resource it produced and appends a matching Service: same name +
;; namespace, selector (app . <name>), one Service port per distinct
;; container port found across all containers. A single port is named
;; "http"; with several it's "port-<n>". No ports found -> no Service.

;; `append` is shadowed by the surface op-macro in this module; gather with
;; concatenate.
(define (collect-container-ports tree)
  (cond
    ((and (pair? tree) (eq? (car tree) 'containerPort) (not (pair? (cdr tree))))
     (list (cdr tree)))
    ((pair? tree)
     (concatenate (list (collect-container-ports (car tree))
                        (collect-container-ports (cdr tree)))))
    (else '())))

(define (service-from-workload wl)
  "Build a Service resource alist from the workload alist WL: same name and
namespace, selector (app . <name>), one Service port per distinct container
port (named \"http\" if one, \"port-<n>\" if several)."
  (let* ((meta  (or (assq-ref wl 'metadata) '()))
         (name  (assq-ref meta 'name))
         (ns    (assq-ref meta 'namespace))
         (ports (delete-duplicates (collect-container-ports wl)))
         (multi (> (length ports) 1))
         (port-entries
           (map (lambda (p)
                  `((name . ,(if multi (string-append "port-" (number->string p)) "http"))
                    (port . ,p) (targetPort . ,p)))
                ports)))
    `((apiVersion . "v1")
      (kind . "Service")
      (metadata ,@(if ns `((namespace . ,ns)) '()) (name . ,name) (labels (app . ,name)))
      (spec (selector (app . ,name))
            (ports ,@port-entries)))))

(define (expose workload-op)
  "Return an op that folds WORKLOAD-OP, then appends a Service derived from
the workload it produced (via `service-from-workload').  No container ports
found means no Service is added."
  (make-op 'expose '(expose)
    (lambda (state)
      (let* ((before (length (or (state-get state '(kubernetes_resources)) '())))
             (s1     (apply-op workload-op state))
             (added  (list-tail (or (state-get s1 '(kubernetes_resources)) '()) before))
             (wl     (find workload? added)))
        (if (and wl (pair? (collect-container-ports wl)))
            (apply-op (resource (service-from-workload wl)) s1)
            s1)))
    "expose"
    (list workload-op)))

;; ---------------------------------------------------------------------------
;; tls-all — add a TLS block to every Ingress.
;; ---------------------------------------------------------------------------
(define (tls-all)
  "Return an op that adds a TLS block to every Ingress, with a per-Ingress
secret named \"<name>-tls\" covering that Ingress's hosts."
  (transform-resources
    (lambda (r)
      (if (equal? (assq-ref r 'kind) "Ingress")
          (let* ((name  (assq-ref (or (assq-ref r 'metadata) '()) 'name))
                 (rules (or (assq-ref (or (assq-ref r 'spec) '()) 'rules) '()))
                 (hosts (map (lambda (rule) (assq-ref rule 'host)) rules)))
            (deep-merge r `((spec (tls ((hosts ,@hosts)
                                        (secretName . ,(string-append name "-tls"))))))))
          r))))

;; ---------------------------------------------------------------------------
;; checksum-config — annotate each Deployment with a hash of the
;; ConfigMaps/Secrets it references (envFrom + volumes).
;; ---------------------------------------------------------------------------

(define (envfrom-refs container)
  (map (lambda (ef)
         (cond ((assq-ref ef 'configMapRef)
                (cons 'configMap (assq-ref (assq-ref ef 'configMapRef) 'name)))
               ((assq-ref ef 'secretRef)
                (cons 'secret    (assq-ref (assq-ref ef 'secretRef)    'name)))
               (else #f)))
       (or (assq-ref container 'envFrom) '())))

(define (volume-ref vol)
  (cond ((assq-ref vol 'configMap)
         (cons 'configMap (assq-ref (assq-ref vol 'configMap) 'name)))
        ((assq-ref vol 'secret)
         (cons 'secret    (assq-ref (assq-ref vol 'secret) 'secretName)))
        (else #f)))

(define (deployment-config-refs r)
  (let* ((spec      (or (assq-ref r 'spec) '()))
         (template  (or (assq-ref spec 'template) '()))
         (pod-spec  (or (assq-ref template 'spec) '()))
         (containers (or (assq-ref pod-spec 'containers) '()))
         (volumes   (or (assq-ref pod-spec 'volumes) '())))
    (filter pair?
            (concatenate (list (concatenate (map envfrom-refs containers))
                               (map volume-ref volumes))))))

(define (index-by-kind-name resources)
  (map (lambda (r)
         (cons (cons (assq-ref r 'kind)
                     (assq-ref (or (assq-ref r 'metadata) '()) 'name))
               r))
       resources))

(define (ref->index-key ref)
  (cons (cond ((eq? (car ref) 'configMap) "ConfigMap")
              ((eq? (car ref) 'secret)    "Secret")
              (else (error "bad ref" ref)))
        (cdr ref)))

(define (data->string data)
  (string-join (map (lambda (kv) (format #f "~a=~a" (car kv) (cdr kv)))
                    (sort data (lambda (a b)
                                 (string<? (symbol->string (car a))
                                           (symbol->string (car b))))))
               "\n"))

(define (hash-hex s)
  (number->string (string-hash s) 16))

;; checksum-config is self-contained: as it resolves each Deployment's
;; ConfigMap/Secret references to hash their data, any reference that
;; doesn't resolve to a defined resource is recorded as a compliance
;; finding (check "checksum-config") — instead of being silently hashed
;; as empty data. It both annotates the pod template and reports.
(define (checksum-config)
  "Return an op that annotates each Deployment's pod template with a hash of
the ConfigMaps/Secrets it references (envFrom + volumes), so pods restart
when that data changes.  References to undefined resources are recorded as
\"checksum-config\" compliance findings rather than silently hashed empty."
  (make-op 'checksum-config '(checksum-config)
    (lambda (state)
      (let* ((rs    (or (state-get state '(kubernetes_resources)) '()))
             (index (index-by-kind-name rs)))
        (define (compute-checksum refs)
          (hash-hex
            (string-join
              (map (lambda (ref)
                     (let* ((r (assoc-ref index (ref->index-key ref)))
                            (data (or (and r (assq-ref r 'data)) '())))
                       (string-append (car (ref->index-key ref)) ":"
                                      (cdr (ref->index-key ref)) ":"
                                      (data->string data))))
                   (sort refs (lambda (a b)
                                (string<? (string-append (symbol->string (car a)) (cdr a))
                                          (string-append (symbol->string (car b)) (cdr b))))))
              "\n")))
        (define (dangling-findings r)
          (if (equal? (assq-ref r 'kind) "Deployment")
              (filter-map
                (lambda (ref)
                  (and (not (assoc-ref index (ref->index-key ref)))
                       (concatenate
                         (list `((check . "checksum-config"))
                               (resource-id r)
                               `((message . ,(string-append
                                  "references " (car (ref->index-key ref))
                                  " " (cdr (ref->index-key ref))
                                  " which is not defined")))))))
                (delete-duplicates (deployment-config-refs r)))
              '()))
        (let ((state* (append-findings state (concatenate (map dangling-findings rs)))))
          (state-set state* '(kubernetes_resources)
            (map (lambda (r)
                   (if (equal? (assq-ref r 'kind) "Deployment")
                       (let ((refs (deployment-config-refs r)))
                         (if (null? refs)
                             r
                             (deep-merge r
                               `((spec (template (metadata (annotations
                                  (config/checksum . ,(compute-checksum refs))))))))))
                       r))
                 rs)))))))

;; ---------------------------------------------------------------------------
;; compliance checks — walk the resource list, append findings.
;; ---------------------------------------------------------------------------

(define workload-kinds '("Deployment" "StatefulSet" "DaemonSet"))
(define (workload? r) (member (assq-ref r 'kind) workload-kinds))

(define (workload-containers r)
  (let* ((spec     (or (assq-ref r 'spec) '()))
         (template (or (assq-ref spec 'template) '()))
         (pod-spec (or (assq-ref template 'spec) '())))
    (or (assq-ref pod-spec 'containers) '())))

(define (workload-pod-spec r)
  (or (assq-ref (or (assq-ref r 'spec) '()) 'template) '()))

(define (resource-id r)
  (list (cons 'kind (assq-ref r 'kind))
        (cons 'name (assq-ref (or (assq-ref r 'metadata) '()) 'name))))

(define (parse-cpu q)
  (let ((s (if (string? q) q (number->string q))))
    (cond ((string-suffix? "m" s)
           (string->number (substring s 0 (- (string-length s) 1))))
          (else (let ((n (string->number s))) (and n (* 1000 n)))))))

(define memory-suffixes
  '(("Ki" . 1024) ("Mi" . 1048576) ("Gi" . 1073741824) ("Ti" . 1099511627776)
    ("K"  . 1000) ("M"  . 1000000) ("G"  . 1000000000) ("T"  . 1000000000000)))

(define (parse-memory q)
  (let ((s (if (string? q) q (number->string q))))
    (let loop ((suffixes memory-suffixes))
      (cond ((null? suffixes) (string->number s))
            ((string-suffix? (caar suffixes) s)
             (let* ((suf (caar suffixes)) (mul (cdar suffixes))
                    (n (string->number (substring s 0 (- (string-length s)
                                                         (string-length suf))))))
               (and n (* n mul))))
            (else (loop (cdr suffixes)))))))

(define (append-findings state new)
  (if (null? new)
      state
      (state-set state '(compliance_findings)
                 (concatenate (list (or (state-get state '(compliance_findings)) '())
                                    new)))))

(define (compliance-check name predicate)
  "Return an op that runs PREDICATE over every resource and appends a
finding (tagged with check NAME and the resource id) for each message
PREDICATE returns.  PREDICATE takes a resource alist and returns a list of
message strings."
  (make-op 'compliance-check `(compliance-check ,name)
    (lambda (state)
      (let ((rs (or (state-get state '(kubernetes_resources)) '())))
        (append-findings state
          (concatenate
            (map (lambda (r)
                   (map (lambda (msg)
                          (concatenate (list `((check . ,name)) (resource-id r)
                                             `((message . ,msg)))))
                        (predicate r)))
                 rs)))))
    (string-append "compliance-check " name)))

(define (check-resources-set)
  "Return a compliance op flagging any workload container missing a cpu or
memory resource request."
  (compliance-check "resources-set"
    (lambda (r)
      (if (not (workload? r)) '()
          (concatenate
            (map (lambda (c)
                   (let* ((res (or (assq-ref c 'resources) '()))
                          (req (or (assq-ref res 'requests) '()))
                          (cn  (assq-ref c 'name))
                          (missing '()))
                     (let* ((missing (if (assq-ref req 'cpu)    missing
                                         (cons "cpu request" missing)))
                            (missing (if (assq-ref req 'memory) missing
                                         (cons "memory request" missing))))
                       (if (null? missing) '()
                           (list (string-append "container " cn ": missing "
                                                (string-join missing ", ")))))))
                 (workload-containers r)))))))

(define (check-cpu-limit-ge-request)
  "Return a compliance op flagging any workload container whose cpu limit is
set without a request, or whose cpu limit is below its request."
  (compliance-check "cpu-limit-ge-request"
    (lambda (r)
      (if (not (workload? r)) '()
          (filter string?
            (map (lambda (c)
                   (let* ((res (or (assq-ref c 'resources) '()))
                          (req (or (assq-ref res 'requests) '()))
                          (lim (or (assq-ref res 'limits)   '()))
                          (rq  (assq-ref req 'cpu))
                          (lm  (assq-ref lim 'cpu))
                          (cn  (assq-ref c 'name)))
                     (cond ((not lm) #f)
                           ((not rq) (string-append "container " cn
                                       ": cpu limit set but no cpu request"))
                           ((< (parse-cpu lm) (parse-cpu rq))
                            (string-append "container " cn
                              ": cpu limit " lm " < cpu request " rq))
                           (else #f))))
                 (workload-containers r)))))))

(define (check-memory-limit-equals-request)
  "Return a compliance op flagging any workload container whose memory limit
is unset or not equal to its memory request."
  (compliance-check "memory-limit-equals-request"
    (lambda (r)
      (if (not (workload? r)) '()
          (filter string?
            (map (lambda (c)
                   (let* ((res (or (assq-ref c 'resources) '()))
                          (req (or (assq-ref res 'requests) '()))
                          (lim (or (assq-ref res 'limits)   '()))
                          (rq  (assq-ref req 'memory))
                          (lm  (assq-ref lim 'memory))
                          (cn  (assq-ref c 'name)))
                     (cond ((and rq lm (= (parse-memory rq) (parse-memory lm))) #f)
                           ((not rq) #f)
                           ((not lm) (string-append "container " cn
                                       ": memory limit not set (must equal request "
                                       rq ")"))
                           (else (string-append "container " cn
                                   ": memory limit " lm " != memory request " rq)))))
                 (workload-containers r)))))))

(define (check-image-registry registry)
  "Return a compliance op flagging any workload container whose image is not
pulled from REGISTRY."
  (compliance-check (string-append "image-registry:" registry)
    (lambda (r)
      (if (not (workload? r)) '()
          (filter string?
            (map (lambda (c)
                   (let ((img (or (assq-ref c 'image) ""))
                         (cn  (assq-ref c 'name)))
                     (if (string-prefix? (string-append registry "/") img)
                         #f
                         (string-append "container " cn ": image " img
                                        " not from " registry))))
                 (workload-containers r)))))))

(define (check-no-privileged)
  "Return a compliance op flagging any workload whose pod-level or
container-level securityContext sets privileged to true."
  (compliance-check "no-privileged"
    (lambda (r)
      (if (not (workload? r)) '()
          (let* ((pod-spec (or (assq-ref (workload-pod-spec r) 'spec) '()))
                 (pod-sc   (or (assq-ref pod-spec 'securityContext) '()))
                 (pod-priv (assq-ref pod-sc 'privileged)))
            (filter string?
              (concatenate
                (list
                  (if pod-priv
                      (list "pod-level securityContext.privileged is true")
                      '())
                  (map (lambda (c)
                         (let* ((sc (or (assq-ref c 'securityContext) '()))
                                (p  (assq-ref sc 'privileged))
                                (cn (assq-ref c 'name)))
                           (if p (string-append "container " cn
                                                ": privileged is true")
                                 #f)))
                       (workload-containers r))))))))))

(define (compliance-all registry)
  "Return one op bundling every compliance check (resource requests, cpu and
memory limits, image registry REGISTRY, and no-privileged)."
  (compose-ops 'compliance-all '(compliance-all)
    (list (check-resources-set)
          (check-cpu-limit-ge-request)
          (check-memory-limit-equals-request)
          (check-image-registry registry)
          (check-no-privileged))))
