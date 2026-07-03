;;; hexol/k8s.scm — Kubernetes library.
;;;
;;; A `(hexol k8s)` submodule: schema-driven record-body constructors (on
;;; `define-construct`) each returning a `resource` op, plus composites and
;;; cross-cutting transforms.
;;;
;;; Resource sugar (each returns one op) — positional name, then `(key value)`
;;; entries; values are evaluated Scheme:
;;;   (deployment "api" (image "…") (port 8080) …)   -> Deployment
;;;   (daemonset  "node" (image "…") …)              -> DaemonSet
;;;   (service    "api" (port 80) …)                 -> Service
;;;   (ingress    "api" (port 80) …)                 -> Ingress
;;;   (configmap  "cfg" (data (K "v") …))            -> ConfigMap
;;;   (secret     "sec" (data (K "v") …))            -> Secret
;;;   (storage-class "fast" (provisioner "…") …)     -> StorageClass
;;;   (persistent-volume-claim "data" (size "5Gi"))  -> PersistentVolumeClaim
;;;   (gateway-class "cilium" (controller-name "…")) -> GatewayClass
;;;   (gateway "edge" (gateway-class-name "…") (listener …)) -> Gateway
;;;   (http-route "app" (parent-name "edge") (backend-service "…") …) -> HTTPRoute
;;;   (custom-resource (api "…") (kind "…") (name "…") (spec …)) -> any CRD
;;;   (service-monitor "api" …)                      -> ServiceMonitor
;;;   (hpa "api" (target "api") (max-replicas 10) (cpu 80)) -> HorizontalPodAutoscaler
;;;   (pdb "api" (min-available 1))                  -> PodDisruptionBudget
;;;
;;; Workload sub-specs (values for a deployment/daemonset field):
;;;   (probe 8080 (http "/healthz") (initial-delay 5)) ; httpGet; (tcp)/(exec …) too
;;;   (strategy "RollingUpdate" (max-surge "25%") (max-unavailable 0))
;;;   (port "metrics" 9797)      one of several container/service ports
;;;   (host-rule "a.com" (service "api") (port 80) [(path "/x")])  one ingress rule
;;; Deployment gains: liveness/readiness/startup probes, strategy, multiple
;;; `ports`, `annotations` (pod template), `termination-grace-period`.
;;;
;;; Label scheme: selectors + the forced identity label key on `current-label-key`
;;; (default `app`); `with-label-key` scopes an override (e.g.
;;; app.kubernetes.io/name), #f drops the forced label.
;;;
;;; Volume / env source refs (do NOT clash with the secret/configmap
;;; constructors):
;;;   (cm  "name")               configMap source
;;;   (sec "name")               secret source
;;;   (pvc "name")               PersistentVolumeClaim source
;;;   (host-path "/p")           hostPath source
;;;   (empty-dir "scratch")      emptyDir scratch volume (name is arbitrary)
;;;   (mount <source> "/path" [#:read-only #t])   volume mount: source + path
;;;     (env-from (cm "api-config"))            ; whole-source env injection
;;;     (volumes  (mount (sec "tls") "/etc/tls")); mounted volume
;;;
;;; Composites:  (app …) (public-app …)
;;; Transforms / policy:  (tls-all) (checksum-config) (compliance-all registry)
;;;
;;; Selector convention: workloads/services key on (app . <name>); layer
;;; org-wide labels via surface's `label-all`.

(define-module (hexol k8s)
  #:use-module (hexol kernel)
  #:use-module (hexol surface)
  #:use-module (hexol construct)
  #:use-module (hexol sh)
  #:use-module (hexol cache)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:re-export (resource transform-resources annotate-all label-all
               compose-ops
               which-cmd
               ;; author your own typed body-form constructors (see docs/extending.md)
               define-construct construct-map-entries construct-flag
               ;; render cache (for inventory shell-out ops)
               current-render-cache)
  #:export (;; namespace scope
            with-namespace current-k8s-namespace namespace
            ;; label scheme
            current-label-key with-label-key
            ;; compact resources spec
            res
            ;; resource sugar
            deployment daemonset service ingress configmap secret
            storage-class persistent-volume-claim
            gateway-class gateway listener http-route
            custom-resource service-monitor
            hpa pdb
            ;; workload sub-specs
            probe strategy host-rule port
            ;; volume / env source refs
            cm sec pvc mount host-path empty-dir
            ;; RBAC
            service-account role role-binding rule
            cluster-role cluster-role-binding cluster-rbac
            ;; external manifests (render-time splice)
            json-manifests cached-json-manifests remote-manifest
            ;; composites
            app public-app
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

;; ---------------------------------------------------------------------------
;; label scheme
;; ---------------------------------------------------------------------------
;;
;; Every workload/service keys its selector + default label on ONE key, `app`
;; by default. Charts that select on `app.kubernetes.io/name` scope it with
;; `with-label-key`; #f drops the forced label entirely (bring your own labels).

(define current-label-key (make-parameter 'app))

(define (selector-labels name)
  "The forced identity label/selector for NAME under the current label key
(empty when the key is #f)."
  (let ((k (current-label-key)))
    (if k `((,k . ,name)) '())))

;; Build-time scope, like `with-namespace`: bake KEY into the body's ops.
(define-syntax-rule (with-label-key key body ...)
  (scope-ops 'with-label-key (current-label-key key) "label-key "
    body ...))

(define* (%namespace name #:key (labels '()))
  (resource `((apiVersion . "v1") (kind . "Namespace")
              (metadata (name . ,name)
                        (labels (kubernetes.io/metadata.name . ,name) ,@labels)))))

(define-construct namespace
  #:head name
  #:fields ((labels #:map))
  #:build (%namespace name #:labels labels))

;; Build-time scope over `scope-ops`; prepends the Namespace resource so
;; scoping a body also creates the namespace.
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
    (labels ,@(selector-labels name) ,@extra-labels)))

(define (envFrom-entries refs)
  (map (lambda (ref)
         (let ((kind (car ref)) (n (cadr ref)))
           (cond ((eq? kind 'configMap) `((configMapRef (name . ,n))))
                 ((eq? kind 'secret)    `((secretRef    (name . ,n))))
                 (else (error "unknown env-from kind:" kind)))))
       refs))

;; A DNS-safe volume name: alnum kept, everything else → "-", ends trimmed.
;; Lets a hostPath ("/lib/modules" → "lib-modules") name its own volume.
(define (sanitize-name s)
  (string-trim-both
   (string-map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) c #\-)) s)
   #\-))

(define (volume-name kind ident)
  (cond ((eq? kind 'hostPath) (string-append "host-" (sanitize-name ident)))
        ((eq? kind 'emptyDir) (sanitize-name ident))   ; user picks a friendly name
        (else (string-append (symbol->string kind) "-" ident))))

(define (volume-entries refs)
  (map (lambda (ref)
         (let ((kind (car ref)) (n (cadr ref)))
           (cond ((eq? kind 'configMap)
                  `((name . ,(volume-name kind n)) (configMap (name . ,n))))
                 ((eq? kind 'secret)
                  `((name . ,(volume-name kind n)) (secret (secretName . ,n))))
                 ((eq? kind 'pvc)
                  `((name . ,(volume-name kind n)) (persistentVolumeClaim (claimName . ,n))))
                 ((eq? kind 'hostPath)
                  `((name . ,(volume-name kind n)) (hostPath (path . ,n))))
                 ((eq? kind 'emptyDir)
                  `((name . ,(volume-name kind n)) (emptyDir)))
                 (else (error "unknown volume kind:" kind)))))
       refs))

;; A mount tuple is (kind ident mountPath [read-only?]); the optional 4th
;; element marks the mount read-only.
(define (volumeMount-entries refs)
  (map (lambda (ref)
         (let ((kind (car ref)) (n (cadr ref)) (path (caddr ref))
               (ro (and (> (length ref) 3) (list-ref ref 3))))
           `((name . ,(volume-name kind n)) (mountPath . ,path)
             ,@(if ro '((readOnly . #t)) '()))))
       refs))

;; A port tuple (name number protocol target-port), shared by container `ports`
;; and multi-port `service`; matches the `cm`/`sec`/`mount` builder convention.
(define* (port name number #:key (protocol #f) (target-port #f))
  (list name number protocol target-port))

(define (containerPort-entries specs)
  (map (lambda (p)
         `((name . ,(list-ref p 0)) (containerPort . ,(list-ref p 1))
           ,@(if (list-ref p 2) `((protocol . ,(list-ref p 2))) '())))
       specs))

(define* (container-alist #:key name image (port 0) (ports '()) (args '()) (command '())
                          (env '()) (env-from '()) (volumes '()) (resources '())
                          (privileged #f) (capabilities '()) (host-port #f) (protocol #f)
                          (liveness '()) (readiness '()) (startup '()))
  (let* ((resources (normalize-resources resources))
         (sec-ctx   (append (if privileged '((privileged . #t)) '())
                            (if (pair? capabilities)
                                `((capabilities (add ,@capabilities))) '())))
         (port-entries
           (append
             (if (and (number? port) (> port 0))
                 `(((containerPort . ,port)
                    ,@(if host-port `((hostPort . ,host-port)) '())
                    ,@(if protocol  `((protocol . ,protocol)) '())))
                 '())
             (containerPort-entries ports))))
    `((name . ,name)
      (image . ,image)
      ,@(if (null? command) '() `((command ,@command)))
      ,@(if (null? args)    '() `((args ,@args)))
      ,@(if (null? port-entries) '() `((ports ,@port-entries)))
      ,@(if (null? env)      '() `((env ,@env)))
      ,@(if (null? env-from) '() `((envFrom ,@(envFrom-entries env-from))))
      ,@(if (null? volumes)  '() `((volumeMounts ,@(volumeMount-entries volumes))))
      ,@(if (null? liveness)  '() `((livenessProbe ,@liveness)))
      ,@(if (null? readiness) '() `((readinessProbe ,@readiness)))
      ,@(if (null? startup)   '() `((startupProbe ,@startup)))
      ,@(if (null? resources) '() `((resources ,@resources)))
      ,@(if (null? sec-ctx) '() `((securityContext ,@sec-ctx))))))

(define* (workload-alist #:key kind name image (port 0) (ports '()) (replicas #f)
                         (namespace (current-k8s-namespace)) (env '()) (env-from '()) (volumes '())
                         (resources '()) (privileged #f) (args '()) (command '())
                         (service-account #f) (host-network #f) (host-pid #f)
                         (labels '()) (annotations '()) (capabilities '()) (host-port #f) (protocol #f)
                         (liveness '()) (readiness '()) (startup '())
                         (strategy '()) (termination-grace-period #f))
  `((apiVersion . "apps/v1")
    (kind . ,kind)
    (metadata ,@(k8s-metadata name namespace labels))
    (spec ,@(if replicas `((replicas . ,replicas)) '())
          ,@(if (null? strategy) '() `((strategy ,@strategy)))
          (selector (matchLabels ,@(selector-labels name)))
          (template
            (metadata (labels ,@(selector-labels name) ,@labels)
                      ,@(if (null? annotations) '() `((annotations ,@annotations))))
            (spec ,@(if service-account `((serviceAccountName . ,service-account)) '())
                  ,@(if host-network `((hostNetwork . #t)) '())
                  ,@(if host-pid `((hostPID . #t)) '())
                  ,@(if termination-grace-period
                        `((terminationGracePeriodSeconds . ,termination-grace-period)) '())
                  (containers ,(container-alist #:name name #:image image #:port port #:ports ports
                                                #:args args #:command command
                                                #:env env #:env-from env-from #:volumes volumes
                                                #:resources resources #:privileged privileged
                                                #:capabilities capabilities
                                                #:host-port host-port #:protocol protocol
                                                #:liveness liveness #:readiness readiness
                                                #:startup startup))
                  ,@(if (null? volumes) '() `((volumes ,@(volume-entries volumes)))))))))

;; ---------------------------------------------------------------------------
;; volume / env source refs
;; ---------------------------------------------------------------------------
;;
;; Builders for the workload env-from/volumes surface. `cm`/`sec`/`pvc` name a
;; source; `mount` adds a path. Produce the tuples `workload-alist` consumes:
;; `(kind name)` and `(kind name path)`.

(define (cm name)  (list 'configMap name))
(define (sec name) (list 'secret name))
(define (pvc name) (list 'pvc name))
(define (host-path path) (list 'hostPath path))
(define (empty-dir name) (list 'emptyDir name))   ; scratch volume; NAME is arbitrary
(define* (mount source path #:key (read-only #f))
  (append source (list path read-only)))

;; ---------------------------------------------------------------------------
;; workload sub-specs — probe / strategy
;; ---------------------------------------------------------------------------
;;
;; Small record-body builders whose #:build returns an alist (like `rule`), fed
;; to a workload's `liveness`/`readiness`/`startup` and `strategy` fields.

;; (probe 8080 (http "/healthz") (initial-delay 5))  ; httpGet by default
;; (probe 5432 (tcp))                                ; tcpSocket
;; (probe 0 (exec "cat" "/tmp/ready"))               ; exec (port ignored)
(define-construct probe
  #:head port
  #:fields ((http #:default #f) (tcp #:flag) (exec #:list)
            (initial-delay #:default #f) (period #:default #f) (timeout #:default #f)
            (success-threshold #:default #f) (failure-threshold #:default #f))
  #:build (append
            (cond ((pair? exec) `((exec (command ,@exec))))
                  (tcp          `((tcpSocket (port . ,port))))
                  (else         `((httpGet (path . ,(or http "/")) (port . ,port)))))
            (filter pair?
              (list (and initial-delay (cons 'initialDelaySeconds initial-delay))
                    (and period (cons 'periodSeconds period))
                    (and timeout (cons 'timeoutSeconds timeout))
                    (and success-threshold (cons 'successThreshold success-threshold))
                    (and failure-threshold (cons 'failureThreshold failure-threshold))))))

;; (strategy "RollingUpdate" (max-surge "25%") (max-unavailable 0)) | (strategy "Recreate")
(define-construct strategy
  #:head type
  #:fields ((max-surge #:default #f) (max-unavailable #:default #f))
  #:build `((type . ,type)
            ,@(if (or max-surge max-unavailable)
                  `((rollingUpdate
                      ,@(filter pair?
                          (list (and max-surge (cons 'maxSurge max-surge))
                                (and max-unavailable (cons 'maxUnavailable max-unavailable))))))
                  '())))

;; ---------------------------------------------------------------------------
;; resource sugar
;; ---------------------------------------------------------------------------

(define* (%deployment #:key name image (port 8080) (ports '()) (replicas 1)
                      (namespace (current-k8s-namespace))
                      (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                      (args '()) (command '()) (service-account #f) (labels '()) (annotations '())
                      (liveness '()) (readiness '()) (startup '())
                      (strategy '()) (termination-grace-period #f))
  (resource (workload-alist #:kind "Deployment" #:name name #:image image #:port port #:ports ports
                            #:replicas replicas #:namespace namespace #:env env #:env-from env-from
                            #:volumes volumes #:resources resources #:privileged privileged
                            #:args args #:command command #:service-account service-account
                            #:labels labels #:annotations annotations
                            #:liveness liveness #:readiness readiness #:startup startup
                            #:strategy strategy #:termination-grace-period termination-grace-period)))

(define-construct deployment
  #:head name
  #:fields ((image #:required) (port #:default 8080) (ports #:list) (replicas #:default 1)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag)
            (args #:list) (command #:list)
            (service-account #:default #f) (labels #:map) (annotations #:map)
            (liveness #:default '()) (readiness #:default '()) (startup #:default '())
            (strategy #:default '()) (termination-grace-period #:default #f))
  #:build (%deployment #:name name #:image image #:port port #:ports ports #:replicas replicas
                       #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                       #:resources resources #:privileged privileged #:args args #:command command
                       #:service-account service-account #:labels labels #:annotations annotations
                       #:liveness liveness #:readiness readiness #:startup startup
                       #:strategy strategy #:termination-grace-period termination-grace-period))

(define-construct daemonset
  #:head name
  #:fields ((image #:required) (port #:default 0)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag)
            (args #:list) (command #:list) (service-account #:default #f)
            (host-network #:flag) (host-pid #:flag) (labels #:map)
            (capabilities #:list) (host-port #:default #f) (protocol #:default #f))
  #:build (resource (workload-alist #:kind "DaemonSet" #:name name #:image image #:port port
                                    #:replicas #f #:namespace namespace #:env env #:env-from env-from
                                    #:volumes volumes #:resources resources #:privileged privileged
                                    #:args args #:command command #:service-account service-account
                                    #:host-network host-network #:host-pid host-pid #:labels labels
                                    #:capabilities capabilities #:host-port host-port #:protocol protocol)))

(define (servicePort-entries specs)
  (map (lambda (p)
         (let ((name (list-ref p 0)) (num (list-ref p 1))
               (proto (list-ref p 2)) (tp (list-ref p 3)))
           `((name . ,name) (port . ,num) (targetPort . ,(or tp num))
             ,@(if proto `((protocol . ,proto)) '()))))
       specs))

;; Single port via #:port/#:target-port/#:port-name, or several via #:ports
;; (a list of `port` tuples): (service "api" (ports (port "http" 80) (port "grpc" 9090))).
(define-construct service
  #:head name
  #:fields ((port #:default #f) (target-port #:default port) (port-name #:default "http")
            (ports #:list)
            (namespace #:default (current-k8s-namespace))
            (type #:default #f) (selector-name #:default #f) (labels #:map))
  #:build (let* ((sel (or selector-name name))
                 (specs (cond ((pair? ports) ports)
                              (port (list (list port-name port #f target-port)))
                              (else (error "service: needs (port …) or (ports …)")))))
            (resource
              `((apiVersion . "v1")
                (kind . "Service")
                (metadata ,@(k8s-metadata name namespace labels))
                (spec (selector ,@(selector-labels sel))
                      ,@(if type `((type . ,type)) '())
                      (ports ,@(servicePort-entries specs)))))))

;; One host+path rule for `ingress` (repeat for more hosts or paths):
;;   (host-rule "a.com" (service "api") (port 80) (path "/api"))
(define-construct host-rule
  #:head host
  #:fields ((service #:required) (port #:required)
            (path #:default "/") (path-type #:default "Prefix"))
  #:build `((host . ,host)
            (http (paths ((path . ,path) (pathType . ,path-type)
                          (backend (service (name . ,service) (port (number . ,port)))))))))

(define* (%ingress #:key name port (host #f) (class #f) (hosts '())
                   (namespace (current-k8s-namespace)) (path "/") (labels '()))
  (let* ((h (or host (string-append name ".example.com")))
         (rules (if (pair? hosts) hosts
                    `(((host . ,h)
                       (http (paths ((path . ,path)
                                     (pathType . "Prefix")
                                     (backend (service (name . ,name)
                                                       (port (number . ,port))))))))))))
    (resource
      `((apiVersion . "networking.k8s.io/v1")
        (kind . "Ingress")
        (metadata ,@(k8s-metadata name namespace labels))
        (spec ,@(if class `((ingressClassName . ,class)) '())
              (rules ,@rules))))))

;; Simple single host/path via #:port/#:host/#:path, or several via repeated
;; `host-rule` (each an `ingress-host`); #:class sets ingressClassName.
(define-construct ingress
  #:head name
  #:fields ((port #:default #f) (host #:default #f) (class #:default #f)
            (host-rule #:repeated #:construct host-rule)
            (namespace #:default (current-k8s-namespace)) (path #:default "/") (labels #:map))
  #:build (%ingress #:name name #:port port #:host host #:class class #:hosts host-rule
                    #:namespace namespace #:path path #:labels labels))

(define-construct configmap
  #:head name
  #:fields ((data #:map) (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (resource
            `((apiVersion . "v1")
              (kind . "ConfigMap")
              (metadata ,@(k8s-metadata name namespace labels))
              (data ,@data))))

(define-construct secret
  #:head name
  #:fields ((data #:map) (string-data #:map) (namespace #:default (current-k8s-namespace))
            (type #:default "Opaque") (labels #:map))
  #:build (resource
            `((apiVersion . "v1")
              (kind . "Secret")
              (metadata ,@(k8s-metadata name namespace labels))
              (type . ,type)
              ,@(if (null? data)        '() `((data ,@data)))
              ,@(if (null? string-data) '() `((stringData ,@string-data))))))

;; ---------------------------------------------------------------------------
;; storage
;; ---------------------------------------------------------------------------

(define-construct storage-class
  #:head name
  #:fields ((provisioner #:required) (default #:flag) (volume-binding-mode #:default #f)
            (reclaim-policy #:default #f) (allow-volume-expansion #:flag)
            (parameters #:map) (labels #:map))
  #:build (resource
            `((apiVersion . "storage.k8s.io/v1")
              (kind . "StorageClass")
              (metadata ,@(k8s-metadata name #f labels)   ; cluster-scoped: no namespace
                        ,@(if default
                              '((annotations (storageclass.kubernetes.io/is-default-class . "true")))
                              '()))
              (provisioner . ,provisioner)
              ,@(if volume-binding-mode `((volumeBindingMode . ,volume-binding-mode)) '())
              ,@(if allow-volume-expansion '((allowVolumeExpansion . #t)) '())
              ,@(if reclaim-policy `((reclaimPolicy . ,reclaim-policy)) '())
              ,@(if (null? parameters) '() `((parameters ,@parameters))))))

(define-construct persistent-volume-claim
  #:head name
  #:fields ((size #:required) (namespace #:default (current-k8s-namespace))
            (access-mode #:default "ReadWriteOnce") (storage-class #:default #f) (labels #:map))
  #:build (resource
            `((apiVersion . "v1")
              (kind . "PersistentVolumeClaim")
              (metadata ,@(k8s-metadata name namespace labels))
              (spec (accessModes ,access-mode)
                    ,@(if storage-class `((storageClassName . ,storage-class)) '())
                    (resources (requests (storage . ,size)))))))

(define* (%custom-resource #:key api kind name (namespace (current-k8s-namespace)) (spec '()) (labels '()))
  (resource
    `((apiVersion . ,api)
      (kind . ,kind)
      (metadata ,@(k8s-metadata name namespace labels))
      (spec ,@spec))))

(define-construct custom-resource
  #:head name
  #:fields ((api #:required) (kind #:required)
            (namespace #:default (current-k8s-namespace))
            (spec #:default '()) (labels #:map))   ; spec: raw alist escape hatch
  #:build (%custom-resource #:api api #:kind kind #:name name
                            #:namespace namespace #:spec spec #:labels labels))

(define-construct service-monitor
  #:head name
  #:fields ((port #:default "http") (path #:default "/metrics") (interval #:default "30s")
            (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (%custom-resource
            #:api "monitoring.coreos.com/v1" #:kind "ServiceMonitor"
            #:name name #:namespace namespace #:labels labels
            #:spec `((selector (matchLabels ,@(selector-labels name)))
                     (endpoints ((port . ,port) (path . ,path) (interval . ,interval))))))

;; ---------------------------------------------------------------------------
;; autoscaling / disruption
;; ---------------------------------------------------------------------------

(define (metric-resource res pct)
  `((type . "Resource")
    (resource (name . ,res)
              (target (type . "Utilization") (averageUtilization . ,pct)))))

;; (hpa "api" (target "api") (max-replicas 10) (cpu 80) (memory 75))
(define-construct hpa
  #:head name
  #:fields ((target #:required) (target-kind #:default "Deployment")
            (min-replicas #:default 1) (max-replicas #:required)
            (cpu #:default #f) (memory #:default #f)
            (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (resource
            `((apiVersion . "autoscaling/v2")
              (kind . "HorizontalPodAutoscaler")
              (metadata ,@(k8s-metadata name namespace labels))
              (spec (scaleTargetRef (apiVersion . "apps/v1") (kind . ,target-kind) (name . ,target))
                    (minReplicas . ,min-replicas)
                    (maxReplicas . ,max-replicas)
                    (metrics ,@(filter pair?
                                 (list (and cpu    (metric-resource "cpu" cpu))
                                       (and memory (metric-resource "memory" memory)))))))))

;; (pdb "api" (min-available 1)) | (pdb "api" (max-unavailable "25%"))
(define-construct pdb
  #:head name
  #:fields ((min-available #:default #f) (max-unavailable #:default #f)
            (selector-name #:default #f)
            (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (let ((sel (or selector-name name)))
            (resource
              `((apiVersion . "policy/v1")
                (kind . "PodDisruptionBudget")
                (metadata ,@(k8s-metadata name namespace labels))
                (spec ,@(if min-available `((minAvailable . ,min-available)) '())
                      ,@(if max-unavailable `((maxUnavailable . ,max-unavailable)) '())
                      (selector (matchLabels ,@(selector-labels sel))))))))

;; ---------------------------------------------------------------------------
;; Gateway API
;; ---------------------------------------------------------------------------

(define-construct gateway-class
  #:head name
  #:fields ((controller-name #:required) (labels #:map))
  #:build (resource
            `((apiVersion . "gateway.networking.k8s.io/v1")
              (kind . "GatewayClass")
              (metadata ,@(k8s-metadata name #f labels))   ; cluster-scoped: no namespace
              (spec (controllerName . ,controller-name)))))

;; A Gateway listener (sub-construct). #:tls-certificate names one or more
;; Secrets → a Terminate-mode tls block; absent → a plain listener.
(define-construct listener
  #:head name
  #:fields ((protocol #:default "HTTP") (port #:required) (hostname #:default #f)
            (tls-certificate #:list) (allowed-routes-from #:default "All"))
  #:build (filter pair?
            (list (cons 'name name)
                  (cons 'protocol protocol)
                  (cons 'port port)
                  (and hostname (cons 'hostname hostname))
                  (cons 'allowedRoutes `((namespaces (from . ,allowed-routes-from))))
                  (and (pair? tls-certificate)
                       (cons 'tls
                         `((mode . "Terminate")
                           (certificateRefs
                             ,@(map (lambda (s) `((kind . "Secret") (name . ,s)))
                                    tls-certificate))))))))

(define-construct gateway
  #:head name
  #:fields ((gateway-class-name #:required) (namespace #:default (current-k8s-namespace))
            (listener #:repeated #:construct listener) (labels #:map))
  #:build (%custom-resource #:api "gateway.networking.k8s.io/v1" #:kind "Gateway"
            #:name name #:namespace namespace #:labels labels
            #:spec `((gatewayClassName . ,gateway-class-name) (listeners ,@listener))))

(define-construct http-route
  #:head name
  #:fields ((namespace #:default (current-k8s-namespace))
            (parent-name #:required) (parent-namespace #:default #f)
            (hostnames #:list) (backend-service #:required) (backend-port #:required)
            (labels #:map))
  #:build (%custom-resource #:api "gateway.networking.k8s.io/v1" #:kind "HTTPRoute"
            #:name name #:namespace namespace #:labels labels
            #:spec `((parentRefs ((name . ,parent-name)
                                  ,@(if parent-namespace `((namespace . ,parent-namespace)) '())))
                     (hostnames ,@hostnames)
                     (rules ((backendRefs ((name . ,backend-service) (port . ,backend-port))))))))

;; ---------------------------------------------------------------------------
;; RBAC
;; ---------------------------------------------------------------------------
;;
;; `rule` is a sub-construct producing a policy-rule alist:
;;   (rule (api-groups "") (resources "pods" "services") (verbs "get" "list"))
;;     => ((apiGroups "") (resources "pods" "services") (verbs "get" "list"))

(define-construct rule
  #:head ()
  #:fields ((api-groups #:list) (resources #:list) (non-resource-urls #:list)
            (resource-names #:list) (verbs #:list))
  #:build (filter pair?
            (list (and (pair? api-groups)        (cons 'apiGroups api-groups))
                  (and (pair? resources)         (cons 'resources resources))
                  (and (pair? non-resource-urls) (cons 'nonResourceURLs non-resource-urls))
                  (and (pair? resource-names)    (cons 'resourceNames resource-names))
                  (and (pair? verbs)             (cons 'verbs verbs)))))

(define* (%service-account #:key name (namespace (current-k8s-namespace)) (labels '()))
  (resource
    `((apiVersion . "v1")
      (kind . "ServiceAccount")
      (metadata ,@(k8s-metadata name namespace labels)))))

(define-construct service-account
  #:head name
  #:fields ((namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (%service-account #:name name #:namespace namespace #:labels labels))

(define-construct role
  #:head name
  #:fields ((rule #:repeated #:construct rule)
            (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (resource
            `((apiVersion . "rbac.authorization.k8s.io/v1")
              (kind . "Role")
              (metadata ,@(k8s-metadata name namespace labels))
              (rules ,@rule))))

(define-construct role-binding
  #:head name
  #:fields ((namespace #:default (current-k8s-namespace)) (role #:required)
            (service-account #:required) (sa-namespace #:default namespace) (labels #:map))
  #:build (resource
            `((apiVersion . "rbac.authorization.k8s.io/v1")
              (kind . "RoleBinding")
              (metadata ,@(k8s-metadata name namespace labels))
              (roleRef (apiGroup . "rbac.authorization.k8s.io") (kind . "Role") (name . ,role))
              (subjects ((kind . "ServiceAccount") (name . ,service-account) (namespace . ,sa-namespace))))))

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

(define-construct cluster-rbac
  #:head name
  #:fields ((rule #:repeated #:construct rule)
            (namespace #:default (current-k8s-namespace)) (labels #:map))
  #:build (compose-ops 'cluster-rbac (list 'cluster-rbac name)
            (list (%service-account #:name name #:namespace namespace #:labels labels)
                  (%cluster-role #:name name #:rules rule #:labels labels)
                  (%cluster-role-binding #:name name #:role name #:service-account name
                                         #:sa-namespace namespace #:labels labels))))

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

(define (run-json-cmd cmd label)
  "Run CMD (a shell pipe printing a JSON array of manifests) and return its
stdout as a string.  Errors if CMD exits non-zero, blaming LABEL."
  (let* ((port   (open-input-pipe cmd))
         (output (get-string-all port))
         (status (close-pipe port)))
    (unless (zero? (status:exit-val status))
      (error "k8s: render command failed for" label))
    output))

(define (parse-json-manifests output)
  "Parse OUTPUT (a JSON array of manifests) into resource alists, dropping
anything without a `kind`."
  (let* ((parsed (json-string->scm output))
         (docs   (if (vector? parsed) (vector->list parsed) '())))
    (filter (lambda (r) (and (pair? r) (assq 'kind r)))
            (map json->resource docs))))

(define (json-manifests cmd label)
  "Run CMD (printing a JSON array of manifests) and return them as resource
alists.  Errors if CMD exits non-zero, blaming LABEL."
  (parse-json-manifests (run-json-cmd cmd label)))

(define (cached-json-manifests key cmd label)
  "Like `json-manifests', but cache CMD's JSON output under KEY in the current
render cache (`current-render-cache').  KEY must capture every input that
determines the output (chart+version+values, or the URL).  With no cache bound
this is exactly `json-manifests' — the shell-out always runs."
  (parse-json-manifests
   (cached-json key (lambda () (run-json-cmd cmd label)))))

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
                  (manifests (cached-json-manifests
                              (string-append "remote\x00;" url) cmd label)))
             (fold (lambda (r s) (apply-op (resource r) s)) state manifests))))))
    (string-append "remote-manifest " label)))

;; ---------------------------------------------------------------------------
;; composites
;; ---------------------------------------------------------------------------

(define-construct app
  #:head name
  #:fields ((image #:required) (port #:default 8080) (replicas #:default 2)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag) (service-account #:default #f))
  #:build (compose-ops 'app `(app ,name)
            (list (expose
                    (%deployment #:name name #:image image #:port port #:replicas replicas
                                 #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                                 #:resources resources #:privileged privileged
                                 #:service-account service-account)))))

(define-construct public-app
  #:head name
  #:fields ((image #:required) (port #:default 8080) (replicas #:default 2)
            (namespace #:default (current-k8s-namespace))
            (env #:list) (env-from #:list) (volumes #:list)
            (resources #:default '()) (privileged #:flag) (service-account #:default #f)
            (host #:default #f))
  #:build (compose-ops 'public-app `(public-app ,name)
            (list (expose
                    (%deployment #:name name #:image image #:port port #:replicas replicas
                                 #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                                 #:resources resources #:privileged privileged
                                 #:service-account service-account))
                  (%ingress #:name name #:port port #:namespace namespace #:host host))))

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
      (metadata ,@(if ns `((namespace . ,ns)) '()) (name . ,name) (labels ,@selector))
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
