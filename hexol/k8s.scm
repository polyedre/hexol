;;; hexol/k8s.scm — the Kubernetes library.
;;;
;;; A `(hexol k8s)` submodule: schema-driven record-body constructors (built
;;; on `define-construct`) that each return a `resource` op (so they drop
;;; straight into an `(inventory ...)`), plus the composites and cross-cutting
;;; transforms.
;;;
;;; Resource sugar (each returns one op) — positional name, then `(key value)`
;;; entries; values are evaluated Scheme, the schema fills defaults / validates
;;; / reports unknown keys with a suggestion:
;;;   (deployment "api" (image "…") (port 8080) …)   -> Deployment
;;;   (daemonset  "node" (image "…") …)              -> DaemonSet
;;;   (service    "api" (port 80) …)                 -> Service
;;;   (ingress    "api" (port 80) …)                 -> Ingress
;;;   (configmap  "cfg" (data (K "v") …))            -> ConfigMap
;;;   (secret     "sec" (data (K "v") …))            -> Secret
;;;   (custom-resource (api "…") (kind "…") (name "…") (spec …)) -> any CRD
;;;   (service-monitor "api" …)                      -> ServiceMonitor
;;;
;;; Volume / env source refs (small helpers, evaluate-default-safe — they do
;;; NOT clash with the `secret`/`configmap` resource constructors):
;;;   (cm  "name")               configMap source
;;;   (sec "name")               secret source
;;;   (pvc "name")               PersistentVolumeClaim source
;;;   (mount <source> "/path")   a volume mount: pair a source with a path
;;;     (env-from (cm "api-config"))            ; whole-source env injection
;;;     (volumes  (mount (sec "tls") "/etc/tls")); mounted volume
;;;
;;; Composites (a compose-ops bundle):  (app …) (public-app …) (worker …)
;;; Transforms / policy:  (tls-all) (checksum-config) (compliance-all registry)
;;;
;;; Selector convention: every workload/service keys on (app . <name>); layer
;;; org-wide labels on top with surface's `label-all`.

(define-module (hexol k8s)
  #:use-module (hexol kernel)
  #:use-module (hexol surface)
  #:use-module (hexol construct)
  #:use-module (hexol sh)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:re-export (resource transform-resources annotate-all label-all
               compose-ops
               which-cmd)
  #:export (;; namespace scope
            with-namespace current-k8s-namespace namespace
            ;; compact resources spec
            res
            ;; resource sugar
            deployment daemonset service ingress configmap secret
            custom-resource service-monitor
            ;; volume / env source refs
            cm sec pvc mount
            ;; RBAC
            service-account role role-binding rule
            cluster-role cluster-role-binding cluster-rbac
            ;; external manifests (render-time splice into kubernetes_resources)
            json-manifests remote-manifest
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

(define current-k8s-namespace (make-parameter "default"))

(define* (%namespace name #:key (labels '()))
  (resource `((apiVersion . "v1") (kind . "Namespace")
              (metadata (name . ,name)
                        (labels (kubernetes.io/metadata.name . ,name) ,@labels)))))

(define-construct namespace
  #:head name
  #:fields ((labels #:map))
  #:build (%namespace name #:labels labels))

;; Build-time scope over the kernel's `scope-ops`. Prepends the Namespace
;; resource to the bundle so scoping a body into a namespace also creates it.
(define-syntax-rule (with-namespace ns body ...)
  (scope-ops 'with-namespace (current-k8s-namespace ns) "namespace "
    (%namespace ns) body ...))

;; ---------------------------------------------------------------------------
;; compact resources spec
;; ---------------------------------------------------------------------------

(define (%bound part single-copies?)
  (let* ((toks (string-split part #\-))
         (norm (lambda (t) (if (or (string=? t "*") (string=? t "")) #f t)))
         (req  (norm (car toks)))
         (lim  (cond ((> (length toks) 1) (norm (cadr toks)))
                     (single-copies? req)
                     (else #f))))
    (cons req lim)))

(define (res spec)
  "Parse a compact resources SPEC string \"CPU/MEM\" into a k8s resources
alist.  Each side is \"req\" or \"req-lim\"; `*' or empty omits a bound."
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

(define* (k8s-metadata name namespace #:optional (extra-labels '()))
  `(,@(if namespace `((namespace . ,namespace)) '())
    (name . ,name)
    (labels (app . ,name) ,@extra-labels)))

(define (envFrom-entries refs)
  (map (lambda (ref)
         (let ((kind (car ref)) (n (cadr ref)))
           (cond ((eq? kind 'configMap) `((configMapRef (name . ,n))))
                 ((eq? kind 'secret)    `((secretRef    (name . ,n))))
                 (else (error "unknown env-from kind:" kind)))))
       refs))

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

(define* (container-alist #:key name image (port 0) (args '()) (command '())
                          (env '()) (env-from '()) (volumes '()) (resources '())
                          (privileged #f))
  (let ((resources (normalize-resources resources)))
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
;; volume / env source refs
;; ---------------------------------------------------------------------------
;;
;; Evaluate-default-safe builders for the workload `env-from` / `volumes`
;; surface. `cm`/`sec`/`pvc` name a source; `mount` pairs a source with a
;; mount path. They produce the internal tuples `workload-alist` consumes —
;; `(configMap name)` / `(secret name)` / `(pvc name)` and, with a path,
;; `(kind name path)`.

(define (cm name)  (list 'configMap name))
(define (sec name) (list 'secret name))
(define (pvc name) (list 'pvc name))
(define (mount source path) (append source (list path)))

;; ---------------------------------------------------------------------------
;; resource sugar
;; ---------------------------------------------------------------------------

(define* (%deployment #:key name image (port 8080) (replicas 1) (namespace (current-k8s-namespace))
                      (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                      (args '()) (command '()) (service-account #f) (labels '()))
  (resource (workload-alist #:kind "Deployment" #:name name #:image image #:port port
                            #:replicas replicas #:namespace namespace #:env env #:env-from env-from
                            #:volumes volumes #:resources resources #:privileged privileged
                            #:args args #:command command #:service-account service-account
                            #:labels labels)))

(define-construct deployment
  #:head name
  #:fields ((image #:required) (port #:default 8080) (replicas #:default 1)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag)
            (args #:list) (command #:list)
            (service-account #:default #f) (labels #:map))
  #:build (%deployment #:name name #:image image #:port port #:replicas replicas
                       #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                       #:resources resources #:privileged privileged #:args args #:command command
                       #:service-account service-account #:labels labels))

(define* (%daemonset #:key name image (port 0) (namespace (current-k8s-namespace))
                     (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                     (args '()) (command '()) (service-account #f)
                     (host-network #f) (host-pid #f) (labels '()))
  (resource (workload-alist #:kind "DaemonSet" #:name name #:image image #:port port
                            #:replicas #f #:namespace namespace #:env env #:env-from env-from
                            #:volumes volumes #:resources resources #:privileged privileged
                            #:args args #:command command #:service-account service-account
                            #:host-network host-network #:host-pid host-pid #:labels labels)))

(define-construct daemonset
  #:head name
  #:fields ((image #:required) (port #:default 0)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag)
            (args #:list) (command #:list) (service-account #:default #f)
            (host-network #:flag) (host-pid #:flag) (labels #:map))
  #:build (%daemonset #:name name #:image image #:port port #:namespace namespace
                      #:env env #:env-from env-from #:volumes volumes #:resources resources
                      #:privileged privileged #:args args #:command command
                      #:service-account service-account #:host-network host-network
                      #:host-pid host-pid #:labels labels))

(define* (%service #:key name port (target-port port) (port-name "http")
                   (namespace (current-k8s-namespace)) (type #f) (selector-name #f) (labels '()))
  (let ((sel (or selector-name name)))
    (resource
      `((apiVersion . "v1")
        (kind . "Service")
        (metadata ,@(k8s-metadata name namespace labels))
        (spec (selector (app . ,sel))
              ,@(if type `((type . ,type)) '())
              (ports ((name . ,port-name) (port . ,port) (targetPort . ,target-port))))))))

(define-construct service
  #:head name
  #:fields ((port #:required) (target-port #:default port) (port-name #:default "http")
            (namespace #:default (current-k8s-namespace))
            (type #:default #f) (selector-name #:default #f) (labels #:map))
  #:build (%service #:name name #:port port #:target-port target-port #:port-name port-name
                    #:namespace namespace #:type type #:selector-name selector-name #:labels labels))

(define* (%ingress #:key name port (host #f) (namespace (current-k8s-namespace)) (path "/") (labels '()))
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

(define-construct ingress
  #:head name
  #:fields ((port #:required) (host #:default #f)
            (namespace #:default (current-k8s-namespace)) (path #:default "/") (labels #:map))
  #:build (%ingress #:name name #:port port #:host host #:namespace namespace
                    #:path path #:labels labels))

(define* (%configmap #:key name data (namespace (current-k8s-namespace)) (labels '()))
  (resource
    `((apiVersion . "v1")
      (kind . "ConfigMap")
      (metadata ,@(k8s-metadata name namespace labels))
      (data ,@data))))

(define-construct configmap
  #:head name
  #:fields ((data #:map) (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (%configmap #:name name #:data data #:namespace namespace #:labels labels))

(define* (%secret #:key name data (namespace (current-k8s-namespace)) (type "Opaque") (labels '()))
  (resource
    `((apiVersion . "v1")
      (kind . "Secret")
      (metadata ,@(k8s-metadata name namespace labels))
      (type . ,type)
      (data ,@data))))

(define-construct secret
  #:head name
  #:fields ((data #:map) (namespace #:default (current-k8s-namespace))
            (type #:default "Opaque") (labels #:map))
  #:build (%secret #:name name #:data data #:namespace namespace #:type type #:labels labels))

(define* (%custom-resource #:key api kind name (namespace (current-k8s-namespace)) (spec '()) (labels '()))
  (resource
    `((apiVersion . ,api)
      (kind . ,kind)
      (metadata ,@(k8s-metadata name namespace labels))
      (spec ,@spec))))

(define-construct custom-resource
  #:head name
  #:fields ((api #:required) (kind #:required)
            (namespace #:default (current-k8s-namespace)) (spec #:map) (labels #:map))
  #:build (%custom-resource #:api api #:kind kind #:name name
                            #:namespace namespace #:spec spec #:labels labels))

(define* (%service-monitor #:key name (port "http") (path "/metrics")
                           (interval "30s") (namespace (current-k8s-namespace)) (labels '()))
  (%custom-resource
    #:api "monitoring.coreos.com/v1" #:kind "ServiceMonitor"
    #:name name #:namespace namespace #:labels labels
    #:spec `((selector (matchLabels (app . ,name)))
             (endpoints ((port . ,port) (path . ,path) (interval . ,interval))))))

(define-construct service-monitor
  #:head name
  #:fields ((port #:default "http") (path #:default "/metrics") (interval #:default "30s")
            (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (%service-monitor #:name name #:port port #:path path #:interval interval
                            #:namespace namespace #:labels labels))

;; ---------------------------------------------------------------------------
;; RBAC
;; ---------------------------------------------------------------------------
;;
;; A `rule` is a record-body sub-construct producing a policy-rule alist:
;;   (rule (api-groups "") (resources "pods" "services") (verbs "get" "list"))
;;     => ((apiGroups "") (resources "pods" "services") (verbs "get" "list"))

(define-construct rule
  #:head ()
  #:fields ((api-groups #:list) (resources #:list) (verbs #:list))
  #:build `((apiGroups ,@api-groups) (resources ,@resources) (verbs ,@verbs)))

(define* (%service-account #:key name (namespace (current-k8s-namespace)) (labels '()))
  (resource
    `((apiVersion . "v1")
      (kind . "ServiceAccount")
      (metadata ,@(k8s-metadata name namespace labels)))))

(define-construct service-account
  #:head name
  #:fields ((namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (%service-account #:name name #:namespace namespace #:labels labels))

(define* (%role #:key name (namespace (current-k8s-namespace)) (rules '()) (labels '()))
  (resource
    `((apiVersion . "rbac.authorization.k8s.io/v1")
      (kind . "Role")
      (metadata ,@(k8s-metadata name namespace labels))
      (rules ,@rules))))

(define-construct role
  #:head name
  #:fields ((rule #:repeated #:construct rule)
            (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (%role #:name name #:namespace namespace #:rules rule #:labels labels))

(define* (%role-binding #:key name (namespace (current-k8s-namespace)) role
                        service-account (sa-namespace namespace) (labels '()))
  (resource
    `((apiVersion . "rbac.authorization.k8s.io/v1")
      (kind . "RoleBinding")
      (metadata ,@(k8s-metadata name namespace labels))
      (roleRef (apiGroup . "rbac.authorization.k8s.io") (kind . "Role") (name . ,role))
      (subjects ((kind . "ServiceAccount") (name . ,service-account) (namespace . ,sa-namespace))))))

(define-construct role-binding
  #:head name
  #:fields ((namespace #:default (current-k8s-namespace)) (role #:required)
            (service-account #:required) (sa-namespace #:default namespace) (labels #:map))
  #:build (%role-binding #:name name #:namespace namespace #:role role
                         #:service-account service-account #:sa-namespace sa-namespace #:labels labels))

(define* (%cluster-role #:key name (rules '()) (labels '()))
  (resource
    `((apiVersion . "rbac.authorization.k8s.io/v1")
      (kind . "ClusterRole")
      (metadata ,@(k8s-metadata name #f labels))
      (rules ,@rules))))

(define-construct cluster-role
  #:head name
  #:fields ((rule #:repeated #:construct rule) (labels #:map))
  #:build (%cluster-role #:name name #:rules rule #:labels labels))

(define* (%cluster-role-binding #:key name role service-account
                                (sa-namespace (current-k8s-namespace)) (labels '()))
  (resource
    `((apiVersion . "rbac.authorization.k8s.io/v1")
      (kind . "ClusterRoleBinding")
      (metadata ,@(k8s-metadata name #f labels))
      (roleRef (apiGroup . "rbac.authorization.k8s.io") (kind . "ClusterRole") (name . ,role))
      (subjects ((kind . "ServiceAccount") (name . ,service-account) (namespace . ,sa-namespace))))))

(define-construct cluster-role-binding
  #:head name
  #:fields ((role #:required) (service-account #:required)
            (sa-namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (%cluster-role-binding #:name name #:role role #:service-account service-account
                                 #:sa-namespace sa-namespace #:labels labels))

(define* (%cluster-rbac #:key name (rules '()) (namespace (current-k8s-namespace)) (labels '()))
  (compose-ops 'cluster-rbac (list 'cluster-rbac name)
    (list (%service-account #:name name #:namespace namespace #:labels labels)
          (%cluster-role #:name name #:rules rules #:labels labels)
          (%cluster-role-binding #:name name #:role name #:service-account name
                                 #:sa-namespace namespace #:labels labels))))

(define-construct cluster-rbac
  #:head name
  #:fields ((rule #:repeated #:construct rule)
            (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (%cluster-rbac #:name name #:rules rule #:namespace namespace #:labels labels))

;; ---------------------------------------------------------------------------
;; external manifests — splice resources produced at render time
;; ---------------------------------------------------------------------------

(define (json->resource x)
  (cond ((vector? x) (map json->resource (vector->list x)))
        ((and (pair? x) (pair? (car x)))
         (filter-map (lambda (kv)
                       (and (not (eq? (cdr kv) 'null))
                            (cons (string->symbol (car kv)) (json->resource (cdr kv)))))
                     x))
        (else x)))

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

(define* (%app #:key name image (port 8080) (replicas 2) (namespace (current-k8s-namespace))
               (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
               (service-account #f))
  (compose-ops 'app `(app ,name)
    (list (expose
            (%deployment #:name name #:image image #:port port #:replicas replicas
                         #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                         #:resources resources #:privileged privileged
                         #:service-account service-account)))))

(define-construct app
  #:head name
  #:fields ((image #:required) (port #:default 8080) (replicas #:default 2)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag) (service-account #:default #f))
  #:build (%app #:name name #:image image #:port port #:replicas replicas #:namespace namespace
                #:env env #:env-from env-from #:volumes volumes #:resources resources
                #:privileged privileged #:service-account service-account))

(define* (%public-app #:key name image (port 8080) (replicas 2) (namespace (current-k8s-namespace))
                      (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                      (service-account #f) (host #f))
  (compose-ops 'public-app `(public-app ,name)
    (list (expose
            (%deployment #:name name #:image image #:port port #:replicas replicas
                         #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                         #:resources resources #:privileged privileged
                         #:service-account service-account))
          (%ingress #:name name #:port port #:namespace namespace #:host host))))

(define-construct public-app
  #:head name
  #:fields ((image #:required) (port #:default 8080) (replicas #:default 2)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag) (service-account #:default #f)
            (host #:default #f))
  #:build (%public-app #:name name #:image image #:port port #:replicas replicas
                       #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                       #:resources resources #:privileged privileged
                       #:service-account service-account #:host host))

(define* (%worker #:key name image (replicas 1) (namespace (current-k8s-namespace))
                  (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                  (service-account #f))
  (compose-ops 'worker `(worker ,name)
    (list (%deployment #:name name #:image image #:port 0 #:replicas replicas
                       #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                       #:resources resources #:privileged privileged
                       #:service-account service-account))))

(define-construct worker
  #:head name
  #:fields ((image #:required) (replicas #:default 1)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag) (service-account #:default #f))
  #:build (%worker #:name name #:image image #:replicas replicas #:namespace namespace
                   #:env env #:env-from env-from #:volumes volumes #:resources resources
                   #:privileged privileged #:service-account service-account))

;; ---------------------------------------------------------------------------
;; expose — derive a Service from a workload.
;; ---------------------------------------------------------------------------

(define (collect-container-ports tree)
  (cond
    ((and (pair? tree) (eq? (car tree) 'containerPort) (not (pair? (cdr tree))))
     (list (cdr tree)))
    ((pair? tree)
     (concatenate (list (collect-container-ports (car tree))
                        (collect-container-ports (cdr tree)))))
    (else '())))

(define (service-from-workload wl)
  "Build a Service resource alist from the workload alist WL."
  (let* ((meta  (or (assq-ref wl 'metadata) '()))
         (name  (assq-ref meta 'name))
         (ns    (assq-ref meta 'namespace))
         (selector (or (assq-ref (or (assq-ref (or (assq-ref wl 'spec) '())
                                                'selector)
                                     '())
                                 'matchLabels)
                       `((app . ,name))))
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
      (spec (selector ,@selector)
            (ports ,@port-entries)))))

(define (expose workload-op)
  "Return an op that folds WORKLOAD-OP, then appends a Service derived from
the workload it produced (via `service-from-workload')."
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
  "Return an op that adds a TLS block to every Ingress."
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
;; checksum-config
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

(define (checksum-config)
  "Return an op that annotates each Deployment's pod template with a hash of
the ConfigMaps/Secrets it references (envFrom + volumes)."
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
;; compliance checks
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
  "Return an op that runs PREDICATE over every resource and appends a finding
for each message PREDICATE returns."
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
  "Return one op bundling every compliance check."
  (compose-ops 'compliance-all '(compliance-all)
    (list (check-resources-set)
          (check-cpu-limit-ge-request)
          (check-memory-limit-equals-request)
          (check-image-registry registry)
          (check-no-privileged))))
