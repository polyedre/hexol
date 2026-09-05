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
;;;   (stateful-set "db" (image "…") (storage "10Gi")) -> StatefulSet
;;;   (job "migrate" (image "…") (command "…"))      -> Job
;;;   (cron-job "rotate" (schedule "0 3 * * *") …)   -> CronJob
;;;   (horizontal-pod-autoscaler "api" (max-replicas 10) …) -> HPA
;;;   (pod-disruption-budget "api" (min-available 1)) -> PodDisruptionBudget
;;;   (network-policy "deny" (default-deny))         -> NetworkPolicy
;;;   (resource-quota "q" (hard (pods "50")))        -> ResourceQuota
;;;   (limit-range "lr" (limits …))                  -> LimitRange
;;;   (gateway-class "cilium" (controller-name "…")) -> GatewayClass
;;;   (gateway "edge" (gateway-class-name "…") (listener …)) -> Gateway
;;;   (http-route "app" (parent-name "edge") (backend-service "…") …) -> HTTPRoute
;;;   (custom-resource (api "…") (kind "…") (name "…") (spec …)) -> any CRD
;;;   (service-monitor "api" …)                      -> ServiceMonitor
;;;
;;; Volume / env source refs (do NOT clash with the secret/configmap
;;; constructors):
;;;   (cm  "name")               configMap source
;;;   (sec "name")               secret source
;;;   (pvc "name")               PersistentVolumeClaim source
;;;   (claim "data")             StatefulSet volumeClaimTemplate source
;;;   (host-path "/p")           hostPath source
;;;   (mount <source> "/path" [#:read-only #t])   volume mount: source + path
;;;     (env-from (cm "api-config"))            ; whole-source env injection
;;;     (volumes  (mount (sec "tls") "/etc/tls")); mounted volume
;;;
;;; Every workload construct (deployment/daemonset/stateful-set/job/cron-job)
;;; shares one pod template, hence the same placement and hardening fields:
;;;   (security-context …) (container-security-context …) (node-selector …)
;;;   (tolerations …) (affinity …) (annotations …) (pod-annotations …)
;;;   (service-account "…") (priority-class "…")
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
            ;; compact resources spec
            res
            ;; resource sugar
            deployment daemonset service ingress configmap secret
            storage-class persistent-volume-claim
            stateful-set job cron-job
            horizontal-pod-autoscaler pod-disruption-budget
            network-policy resource-quota limit-range
            gateway-class gateway listener http-route
            custom-resource service-monitor
            ;; volume / env source refs
            cm sec pvc claim mount host-path
            ;; RBAC
            service-account role role-binding
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
            check-no-privileged)
  ;; `rule` shadows a core binding; declare the override so importing this
  ;; module into an inventory doesn't warn about it.
  #:replace (rule))

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
  #:doc "a Namespace resource (see also with-namespace)"
  #:fields ((labels #:map #:doc "extra metadata.labels"))
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
    (labels (app . ,name) ,@extra-labels)))

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
        ;; a StatefulSet volumeClaimTemplate is named directly: the template's
        ;; metadata.name IS the volume name, so no prefix.
        ((eq? kind 'claim) ident)
        (else (string-append (symbol->string kind) "-" ident))))

(define (volume-entries refs)
  ;; `claim` refs are backed by a volumeClaimTemplate, not a pod volume.
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
                 (else (error "unknown volume kind:" kind)))))
       (filter (lambda (ref) (not (eq? (car ref) 'claim))) refs)))

;; A mount tuple is (kind ident mountPath [read-only?]); the optional 4th
;; element marks the mount read-only.
(define (volumeMount-entries refs)
  (map (lambda (ref)
         (let ((kind (car ref)) (n (cadr ref)) (path (caddr ref))
               (ro (and (> (length ref) 3) (list-ref ref 3))))
           `((name . ,(volume-name kind n)) (mountPath . ,path)
             ,@(if ro '((readOnly . #t)) '()))))
       refs))

(define* (container-alist #:key name image (port 0) (args '()) (command '())
                          (env '()) (env-from '()) (volumes '()) (resources '())
                          (privileged #f) (capabilities '()) (host-port #f) (protocol #f)
                          (security-context '()))
  (let ((resources (normalize-resources resources))
        ;; explicit container securityContext first, then the `privileged'
        ;; flag and `capabilities' sugar (which stay authoritative)
        (sec-ctx   (append security-context
                           (if privileged '((privileged . #t)) '())
                           (if (pair? capabilities)
                               `((capabilities (add ,@capabilities))) '()))))
    `((name . ,name)
      (image . ,image)
      ,@(if (null? command) '() `((command ,@command)))
      ,@(if (null? args)    '() `((args ,@args)))
      ,@(if (and (number? port) (> port 0))
            `((ports ((containerPort . ,port)
                      ,@(if host-port `((hostPort . ,host-port)) '())
                      ,@(if protocol  `((protocol . ,protocol)) '()))))
            '())
      ,@(if (null? env)      '() `((env ,@env)))
      ,@(if (null? env-from) '() `((envFrom ,@(envFrom-entries env-from))))
      ,@(if (null? volumes)  '() `((volumeMounts ,@(volumeMount-entries volumes))))
      ,@(if (null? resources) '() `((resources ,@resources)))
      ,@(if (null? sec-ctx) '() `((securityContext ,@sec-ctx))))))

(define* (pod-template-alist #:key name image (port 0) (env '()) (env-from '()) (volumes '())
                             (resources '()) (privileged #f) (args '()) (command '())
                             (service-account #f) (host-network #f) (host-pid #f)
                             (labels '()) (capabilities '()) (host-port #f) (protocol #f)
                             (restart-policy #f) (security-context '())
                             (container-security-context '()) (node-selector '())
                             (tolerations '()) (affinity '()) (pod-annotations '())
                             (priority-class #f))
  "The pod template shared by every workload kind (Deployment, DaemonSet,
StatefulSet, Job, CronJob): `(metadata …) (spec …)` with one container."
  `((metadata (labels (app . ,name) ,@labels)
              ,@(if (null? pod-annotations) '() `((annotations ,@pod-annotations))))
    (spec ,@(if service-account `((serviceAccountName . ,service-account)) '())
          ,@(if host-network '((hostNetwork . #t)) '())
          ,@(if host-pid '((hostPID . #t)) '())
          ,@(if restart-policy `((restartPolicy . ,restart-policy)) '())
          ,@(if priority-class `((priorityClassName . ,priority-class)) '())
          ,@(if (null? node-selector) '() `((nodeSelector ,@node-selector)))
          ,@(if (null? tolerations) '() `((tolerations ,@tolerations)))
          ,@(if (null? affinity) '() `((affinity ,@affinity)))
          ,@(if (null? security-context) '() `((securityContext ,@security-context)))
          (containers ,(container-alist #:name name #:image image #:port port
                                        #:args args #:command command
                                        #:env env #:env-from env-from #:volumes volumes
                                        #:resources resources #:privileged privileged
                                        #:capabilities capabilities
                                        #:host-port host-port #:protocol protocol
                                        #:security-context container-security-context))
          ,@(let ((vs (volume-entries volumes)))
              (if (null? vs) '() `((volumes ,@vs)))))))

(define* (workload-alist #:key kind name image (port 0) (replicas #f)
                         (namespace (current-k8s-namespace)) (env '()) (env-from '()) (volumes '())
                         (resources '()) (privileged #f) (args '()) (command '())
                         (service-account #f) (host-network #f) (host-pid #f)
                         (labels '()) (capabilities '()) (host-port #f) (protocol #f)
                         (spec-extra '())
                         (security-context '()) (container-security-context '())
                         (node-selector '()) (tolerations '()) (affinity '())
                         (annotations '()) (pod-annotations '()) (priority-class #f)
)
  `((apiVersion . "apps/v1")
    (kind . ,kind)
    (metadata ,@(k8s-metadata name namespace labels)
              ,@(if (null? annotations) '() `((annotations ,@annotations))))
    (spec ,@(if replicas `((replicas . ,replicas)) '())
          (selector (matchLabels (app . ,name)))
          ,@spec-extra
          (template ,@(pod-template-alist
                        #:name name #:image image #:port port #:env env #:env-from env-from
                        #:volumes volumes #:resources resources #:privileged privileged
                        #:args args #:command command #:service-account service-account
                        #:host-network host-network #:host-pid host-pid #:labels labels
                        #:capabilities capabilities #:host-port host-port
                        #:protocol protocol
                        #:security-context security-context
                        #:container-security-context container-security-context
                        #:node-selector node-selector #:tolerations tolerations
                        #:affinity affinity #:pod-annotations pod-annotations
                        #:priority-class priority-class
                        )))))


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
(define (claim name) (list 'claim name))  ; a StatefulSet volumeClaimTemplate
(define (host-path path) (list 'hostPath path))
(define* (mount source path #:key (read-only #f))
  (append source (list path read-only)))

;; ---------------------------------------------------------------------------
;; resource sugar
;; ---------------------------------------------------------------------------

(define* (%deployment #:key name image (port 8080) (replicas 1) (namespace (current-k8s-namespace))
                      (env '()) (env-from '()) (volumes '()) (resources '()) (privileged #f)
                      (args '()) (command '()) (service-account #f) (labels '())
                      (security-context '()) (container-security-context '())
                      (node-selector '()) (tolerations '()) (affinity '())
                      (annotations '()) (pod-annotations '()) (priority-class #f))
  (resource (workload-alist #:kind "Deployment" #:name name #:image image #:port port
                            #:replicas replicas #:namespace namespace #:env env #:env-from env-from
                            #:volumes volumes #:resources resources #:privileged privileged
                            #:args args #:command command #:service-account service-account
                            #:labels labels
                            #:security-context security-context
                            #:container-security-context container-security-context
                            #:node-selector node-selector #:tolerations tolerations
                            #:affinity affinity #:annotations annotations
                            #:pod-annotations pod-annotations #:priority-class priority-class)))

(define-construct deployment
  #:head name
  #:doc "a Deployment with one container"
  #:fields ((image #:required #:doc "container image ref")
            (port #:default 8080 #:doc "containerPort")
            (replicas #:default 1 #:doc "pod replicas")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (env #:list #:doc "env vars, (NAME \"value\") pairs")
            (env-from #:list #:doc "envFrom sources (configmap/secret names)")
            (volumes #:list #:doc "volume specs (mounted in the container)")
            (resources #:default '() #:doc "requests/limits alist; `res' parses \"cpu/mem\"")
            (privileged #:flag #:doc "privileged securityContext")
            (args #:list #:doc "container args")
            (command #:list #:doc "container command (entrypoint override)")
            (service-account #:default #f #:doc "serviceAccountName")
            (labels #:map #:doc "extra metadata.labels")
            (security-context #:map #:doc "pod-level securityContext")
            (container-security-context #:map #:doc "container-level securityContext")
            (node-selector #:map #:doc "pod nodeSelector")
            (tolerations #:list #:doc "raw toleration alists")
            (affinity #:map #:doc "pod affinity (raw)")
            (annotations #:map #:doc "extra metadata.annotations")
            (pod-annotations #:map #:doc "extra pod-template annotations")
            (priority-class #:default #f #:doc "priorityClassName"))
  #:build (%deployment #:name name #:image image #:port port #:replicas replicas
                       #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                       #:resources resources #:privileged privileged #:args args #:command command
                       #:service-account service-account #:labels labels
                       #:security-context security-context
                       #:container-security-context container-security-context
                       #:node-selector node-selector #:tolerations tolerations
                       #:affinity affinity #:annotations annotations
                       #:pod-annotations pod-annotations #:priority-class priority-class))

(define-construct daemonset
  #:head name
  #:doc "a DaemonSet with one container (one pod per node)"
  #:fields ((image #:required #:doc "container image ref")
            (port #:default 0 #:doc "containerPort (0: none)")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (env #:list #:doc "env vars, (NAME \"value\") pairs")
            (env-from #:list #:doc "envFrom sources (configmap/secret names)")
            (volumes #:list #:doc "volume specs (mounted in the container)")
            (resources #:default '() #:doc "requests/limits alist; `res' parses \"cpu/mem\"")
            (privileged #:flag #:doc "privileged securityContext")
            (args #:list #:doc "container args")
            (command #:list #:doc "container command (entrypoint override)")
            (service-account #:default #f #:doc "serviceAccountName")
            (host-network #:flag #:doc "hostNetwork: true")
            (host-pid #:flag #:doc "hostPID: true")
            (labels #:map #:doc "extra metadata.labels")
            (capabilities #:list #:doc "securityContext.capabilities.add")
            (host-port #:default #f #:doc "hostPort for the container port")
            (protocol #:default #f #:doc "port protocol (TCP/UDP)")
            (security-context #:map #:doc "pod-level securityContext")
            (container-security-context #:map #:doc "container-level securityContext")
            (node-selector #:map #:doc "pod nodeSelector")
            (tolerations #:list #:doc "raw toleration alists")
            (affinity #:map #:doc "pod affinity (raw)")
            (annotations #:map #:doc "extra metadata.annotations")
            (pod-annotations #:map #:doc "extra pod-template annotations")
            (priority-class #:default #f #:doc "priorityClassName"))
  #:build (resource (workload-alist #:kind "DaemonSet" #:name name #:image image #:port port
                                    #:replicas #f #:namespace namespace #:env env #:env-from env-from
                                    #:volumes volumes #:resources resources #:privileged privileged
                                    #:args args #:command command #:service-account service-account
                                    #:host-network host-network #:host-pid host-pid #:labels labels
                                    #:capabilities capabilities #:host-port host-port #:protocol protocol
                                    #:security-context security-context
                                    #:container-security-context container-security-context
                                    #:node-selector node-selector #:tolerations tolerations
                                    #:affinity affinity #:annotations annotations
                                    #:pod-annotations pod-annotations #:priority-class priority-class)))

(define-construct service
  #:head name
  #:doc "a Service selecting app=NAME (see also expose)"
  #:fields ((port #:required #:doc "service port")
            (target-port #:default port #:doc "pod port (defaults to port)")
            (port-name #:default "http" #:doc "port name")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (type #:default #f #:doc "ClusterIP/NodePort/LoadBalancer")
            (selector-name #:default #f #:doc "app label to select (defaults to NAME)")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (let ((sel (or selector-name name)))
            (resource
              `((apiVersion . "v1")
                (kind . "Service")
                (metadata ,@(k8s-metadata name namespace labels))
                (spec (selector (app . ,sel))
                      ,@(if type `((type . ,type)) '())
                      (ports ((name . ,port-name) (port . ,port) (targetPort . ,target-port))))))))

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
  #:doc "an Ingress routing HOST/PATH to service NAME:PORT"
  #:fields ((port #:required #:doc "backend service port")
            (host #:default #f #:doc "hostname (default NAME.example.com)")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (path #:default "/" #:doc "path prefix")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (%ingress #:name name #:port port #:host host #:namespace namespace
                    #:path path #:labels labels))

(define-construct configmap
  #:head name
  #:doc "a ConfigMap"
  #:fields ((data #:map #:doc "data entries, (key \"value\"); string keys ok (\"nginx.conf\")")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)") (labels #:map #:doc "extra metadata.labels"))
  #:build (resource
            `((apiVersion . "v1")
              (kind . "ConfigMap")
              (metadata ,@(k8s-metadata name namespace labels))
              (data ,@data))))

(define-construct secret
  #:head name
  #:doc "a Secret"
  #:fields ((data #:map #:doc "base64 data entries")
            (string-data #:map #:doc "plaintext stringData entries")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (type #:default "Opaque" #:doc "secret type")
            (labels #:map #:doc "extra metadata.labels"))
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
  #:doc "a StorageClass (cluster-scoped)"
  #:fields ((provisioner #:required #:doc "provisioner name")
            (default #:flag #:doc "mark as the default class")
            (volume-binding-mode #:default #f #:doc "Immediate/WaitForFirstConsumer")
            (reclaim-policy #:default #f #:doc "Delete/Retain")
            (allow-volume-expansion #:flag #:doc "allowVolumeExpansion: true")
            (parameters #:map #:doc "provisioner parameters")
            (labels #:map #:doc "extra metadata.labels"))
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
  #:doc "a PersistentVolumeClaim"
  #:fields ((size #:required #:doc "requested storage (\"10Gi\")")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (access-mode #:default "ReadWriteOnce" #:doc "access mode")
            (storage-class #:default #f #:doc "storageClassName")
            (labels #:map #:doc "extra metadata.labels"))
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
  #:doc "any resource by apiVersion/kind, spec as a raw alist"
  #:fields ((api #:required #:doc "apiVersion")
            (kind #:required #:doc "kind")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (spec #:default '() #:doc "spec alist (raw escape hatch, use `body')")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (%custom-resource #:api api #:kind kind #:name name
                            #:namespace namespace #:spec spec #:labels labels))

(define-construct service-monitor
  #:head name
  #:doc "a Prometheus ServiceMonitor scraping app=NAME"
  #:fields ((port #:default "http" #:doc "service port name to scrape")
            (path #:default "/metrics" #:doc "metrics path")
            (interval #:default "30s" #:doc "scrape interval")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)") (labels #:map #:doc "extra metadata.labels"))
  #:build (%custom-resource
            #:api "monitoring.coreos.com/v1" #:kind "ServiceMonitor"
            #:name name #:namespace namespace #:labels labels
            #:spec `((selector (matchLabels (app . ,name)))
                     (endpoints ((port . ,port) (path . ,path) (interval . ,interval))))))

;; ---------------------------------------------------------------------------
;; batch / stateful workloads
;; ---------------------------------------------------------------------------

(define-construct stateful-set
  #:head name
  #:doc "a StatefulSet with one container and an optional volumeClaimTemplate"
  #:fields ((image #:required #:doc "container image ref")
            (port #:default 0 #:doc "containerPort (0: none)")
            (replicas #:default 1 #:doc "pod replicas")
            (service-name #:default name #:doc "spec.serviceName (governing headless Service)")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (env #:list #:doc "env vars, (NAME \"value\") pairs")
            (env-from #:list #:doc "envFrom sources (configmap/secret names)")
            (volumes #:list #:doc "volume specs (mounted in the container)")
            (resources #:default '() #:doc "requests/limits alist; `res' parses \"cpu/mem\"")
            (privileged #:flag #:doc "privileged securityContext")
            (args #:list #:doc "container args")
            (command #:list #:doc "container command (entrypoint override)")
            (service-account #:default #f #:doc "serviceAccountName")
            (storage #:default #f #:doc "size of the generated volumeClaimTemplate (\"10Gi\")")
            (claim-name #:default "data" #:doc "name of the generated claim (and its volume)")
            (mount-path #:default "/data" #:doc "where the generated claim mounts")
            (storage-class #:default #f #:doc "storageClassName of the generated claim")
            (access-mode #:default "ReadWriteOnce" #:doc "access mode of the generated claim")
            (volume-claim-templates #:list #:doc "extra raw volumeClaimTemplate alists")
            (labels #:map #:doc "extra metadata.labels")
            (security-context #:map #:doc "pod-level securityContext")
            (container-security-context #:map #:doc "container-level securityContext")
            (node-selector #:map #:doc "pod nodeSelector")
            (tolerations #:list #:doc "raw toleration alists")
            (affinity #:map #:doc "pod affinity (raw)")
            (annotations #:map #:doc "extra metadata.annotations")
            (pod-annotations #:map #:doc "extra pod-template annotations")
            (priority-class #:default #f #:doc "priorityClassName"))
  #:build (let* ((mounts (if storage
                             (append volumes (list (mount (claim claim-name) mount-path)))
                             volumes))
                 (generated (if storage
                                (list `((metadata (name . ,claim-name))
                                        (spec (accessModes ,access-mode)
                                              ,@(if storage-class
                                                    `((storageClassName . ,storage-class)) '())
                                              (resources (requests (storage . ,storage))))))
                                '()))
                 (claims (append generated volume-claim-templates)))
            (resource
              (workload-alist #:kind "StatefulSet" #:name name #:image image #:port port
                              #:replicas replicas #:namespace namespace #:env env
                              #:env-from env-from #:volumes mounts #:resources resources
                              #:privileged privileged #:args args #:command command
                              #:service-account service-account #:labels labels
                              #:security-context security-context
                              #:container-security-context container-security-context
                              #:node-selector node-selector #:tolerations tolerations
                              #:affinity affinity #:annotations annotations
                              #:pod-annotations pod-annotations #:priority-class priority-class
                              #:spec-extra
                              `((serviceName . ,service-name)
                                ,@(if (null? claims) '() `((volumeClaimTemplates ,@claims))))))))

;; The pod spec shared by Job and CronJob (a Job spec body, minus apiVersion).
(define* (job-spec-alist #:key name image (env '()) (env-from '()) (volumes '())
                         (resources '()) (privileged #f) (args '()) (command '())
                         (service-account #f) (labels '()) (restart-policy "OnFailure")
                         (security-context '()) (container-security-context '())
                         (node-selector '()) (tolerations '()) (affinity '())
                         (pod-annotations '()) (priority-class #f)

                         (backoff-limit 6) (completions #f) (parallelism #f)
                         (active-deadline-seconds #f) (ttl-seconds-after-finished #f))
  `((backoffLimit . ,backoff-limit)
    ,@(if completions `((completions . ,completions)) '())
    ,@(if parallelism `((parallelism . ,parallelism)) '())
    ,@(if active-deadline-seconds `((activeDeadlineSeconds . ,active-deadline-seconds)) '())
    ,@(if ttl-seconds-after-finished
          `((ttlSecondsAfterFinished . ,ttl-seconds-after-finished)) '())
    (template ,@(pod-template-alist #:name name #:image image #:env env #:env-from env-from
                                    #:volumes volumes #:resources resources
                                    #:privileged privileged #:args args #:command command
                                    #:service-account service-account #:labels labels
                                    #:restart-policy restart-policy
                                    #:security-context security-context
                                    #:container-security-context container-security-context
                                    #:node-selector node-selector #:tolerations tolerations
                                    #:affinity affinity #:pod-annotations pod-annotations
                                    #:priority-class priority-class
                                    ))))

(define-construct job
  #:head name
  #:doc "a Job running one container to completion"
  #:fields ((image #:required #:doc "container image ref")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (command #:list #:doc "container command (entrypoint override)")
            (args #:list #:doc "container args")
            (env #:list #:doc "env vars, (NAME \"value\") pairs")
            (env-from #:list #:doc "envFrom sources (configmap/secret names)")
            (volumes #:list #:doc "volume specs (mounted in the container)")
            (resources #:default '() #:doc "requests/limits alist; `res' parses \"cpu/mem\"")
            (service-account #:default #f #:doc "serviceAccountName")
            (restart-policy #:default "OnFailure" #:doc "OnFailure/Never")
            (backoff-limit #:default 6 #:doc "retries before the Job fails")
            (completions #:default #f #:doc "spec.completions")
            (parallelism #:default #f #:doc "spec.parallelism")
            (active-deadline-seconds #:default #f #:doc "spec.activeDeadlineSeconds")
            (ttl-seconds-after-finished #:default #f #:doc "delete the Job this long after it ends")
            (labels #:map #:doc "extra metadata.labels")
            (security-context #:map #:doc "pod-level securityContext")
            (container-security-context #:map #:doc "container-level securityContext")
            (node-selector #:map #:doc "pod nodeSelector")
            (tolerations #:list #:doc "raw toleration alists")
            (affinity #:map #:doc "pod affinity (raw)")
            (annotations #:map #:doc "extra metadata.annotations")
            (pod-annotations #:map #:doc "extra pod-template annotations")
            (priority-class #:default #f #:doc "priorityClassName"))
  #:build (resource
            `((apiVersion . "batch/v1")
              (kind . "Job")
              (metadata ,@(k8s-metadata name namespace labels)
                        ,@(if (null? annotations) '() `((annotations ,@annotations))))
              (spec ,@(job-spec-alist #:name name #:image image #:env env #:env-from env-from
                                      #:volumes volumes #:resources resources
                                      #:args args #:command command
                                      #:service-account service-account #:labels labels
                                      #:restart-policy restart-policy
                                      #:backoff-limit backoff-limit
                                      #:completions completions #:parallelism parallelism
                                      #:active-deadline-seconds active-deadline-seconds
                                      #:ttl-seconds-after-finished ttl-seconds-after-finished
                                      #:security-context security-context
                                      #:container-security-context container-security-context
                                      #:node-selector node-selector #:tolerations tolerations
                                      #:affinity affinity
                                      #:pod-annotations pod-annotations #:priority-class priority-class)))))

(define-construct cron-job
  #:head name
  #:doc "a CronJob running one container on SCHEDULE"
  #:fields ((schedule #:required #:doc "cron expression (\"0 3 * * *\")")
            (image #:required #:doc "container image ref")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (command #:list #:doc "container command (entrypoint override)")
            (args #:list #:doc "container args")
            (env #:list #:doc "env vars, (NAME \"value\") pairs")
            (env-from #:list #:doc "envFrom sources (configmap/secret names)")
            (volumes #:list #:doc "volume specs (mounted in the container)")
            (resources #:default '() #:doc "requests/limits alist; `res' parses \"cpu/mem\"")
            (service-account #:default #f #:doc "serviceAccountName")
            (concurrency-policy #:default "Forbid" #:doc "Allow/Forbid/Replace")
            (suspend #:flag #:doc "spec.suspend: true")
            (starting-deadline-seconds #:default #f #:doc "spec.startingDeadlineSeconds")
            (successful-jobs-history #:default 3 #:doc "successfulJobsHistoryLimit")
            (failed-jobs-history #:default 1 #:doc "failedJobsHistoryLimit")
            (restart-policy #:default "OnFailure" #:doc "OnFailure/Never")
            (backoff-limit #:default 6 #:doc "retries before one run fails")
            (time-zone #:default #f #:doc "spec.timeZone")
            (labels #:map #:doc "extra metadata.labels")
            (security-context #:map #:doc "pod-level securityContext")
            (container-security-context #:map #:doc "container-level securityContext")
            (node-selector #:map #:doc "pod nodeSelector")
            (tolerations #:list #:doc "raw toleration alists")
            (affinity #:map #:doc "pod affinity (raw)")
            (annotations #:map #:doc "extra metadata.annotations")
            (pod-annotations #:map #:doc "extra pod-template annotations")
            (priority-class #:default #f #:doc "priorityClassName"))
  #:build (resource
            `((apiVersion . "batch/v1")
              (kind . "CronJob")
              (metadata ,@(k8s-metadata name namespace labels)
                        ,@(if (null? annotations) '() `((annotations ,@annotations))))
              (spec (schedule . ,schedule)
                    ,@(if time-zone `((timeZone . ,time-zone)) '())
                    (concurrencyPolicy . ,concurrency-policy)
                    ,@(if suspend '((suspend . #t)) '())
                    ,@(if starting-deadline-seconds
                          `((startingDeadlineSeconds . ,starting-deadline-seconds)) '())
                    (successfulJobsHistoryLimit . ,successful-jobs-history)
                    (failedJobsHistoryLimit . ,failed-jobs-history)
                    (jobTemplate
                      (spec ,@(job-spec-alist #:name name #:image image #:env env
                                              #:env-from env-from #:volumes volumes
                                              #:resources resources #:args args
                                              #:command command
                                              #:service-account service-account
                                              #:labels labels
                                              #:restart-policy restart-policy
                                              #:backoff-limit backoff-limit
                                              #:security-context security-context
                                              #:container-security-context container-security-context
                                              #:node-selector node-selector #:tolerations tolerations
                                              #:affinity affinity
                                              #:pod-annotations pod-annotations #:priority-class priority-class)))))))

;; ---------------------------------------------------------------------------
;; scaling / availability / policy
;; ---------------------------------------------------------------------------

(define-construct horizontal-pod-autoscaler
  #:head name
  #:doc "an HPA scaling a workload on cpu/memory utilization"
  #:fields ((max-replicas #:required #:doc "spec.maxReplicas")
            (min-replicas #:default 1 #:doc "spec.minReplicas")
            (target-kind #:default "Deployment" #:doc "scaleTargetRef.kind")
            (target-name #:default name #:doc "scaleTargetRef.name (defaults to NAME)")
            (target-api-version #:default "apps/v1" #:doc "scaleTargetRef.apiVersion")
            (cpu-utilization #:default #f #:doc "target average CPU percent")
            (memory-utilization #:default #f #:doc "target average memory percent")
            (behavior #:map #:doc "spec.behavior (raw)")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (let ((metric (lambda (kind pct)
                          `((type . "Resource")
                            (resource (name . ,kind)
                                      (target (type . "Utilization")
                                              (averageUtilization . ,pct)))))))
            (resource
              `((apiVersion . "autoscaling/v2")
                (kind . "HorizontalPodAutoscaler")
                (metadata ,@(k8s-metadata name namespace labels))
                (spec (scaleTargetRef (apiVersion . ,target-api-version)
                                      (kind . ,target-kind) (name . ,target-name))
                      (minReplicas . ,min-replicas)
                      (maxReplicas . ,max-replicas)
                      ,@(let ((ms (filter pair?
                                          (list (and cpu-utilization (metric "cpu" cpu-utilization))
                                                (and memory-utilization
                                                     (metric "memory" memory-utilization))))))
                          (if (null? ms) '() `((metrics ,@ms))))
                      ,@(if (null? behavior) '() `((behavior ,@behavior))))))))

(define-construct pod-disruption-budget
  #:head name
  #:doc "a PodDisruptionBudget over app=NAME (min-available defaults to 1)"
  #:fields ((min-available #:default #f #:doc "spec.minAvailable (count or \"50%\")")
            (max-unavailable #:default #f #:doc "spec.maxUnavailable (count or \"50%\")")
            (selector #:map #:doc "selector.matchLabels (defaults to (app . NAME))")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (begin
            (when (and min-available max-unavailable)
              (error "pod-disruption-budget: set min-available OR max-unavailable, not both:" name))
            (resource
              `((apiVersion . "policy/v1")
                (kind . "PodDisruptionBudget")
                (metadata ,@(k8s-metadata name namespace labels))
                (spec ,@(if max-unavailable
                            `((maxUnavailable . ,max-unavailable))
                            `((minAvailable . ,(or min-available 1))))
                      (selector (matchLabels ,@(if (null? selector)
                                                   `((app . ,name))
                                                   selector))))))))

(define-construct network-policy
  #:head name
  #:doc "a NetworkPolicy; (default-deny) denies all ingress+egress"
  #:fields ((pod-selector #:map #:doc "spec.podSelector.matchLabels (empty: all pods)")
            (policy-types #:list #:doc "Ingress and/or Egress (default: whichever rules are given)")
            (ingress #:list #:doc "raw ingress rule alists")
            (egress #:list #:doc "raw egress rule alists")
            (default-deny #:flag #:doc "deny all ingress and egress (no rules)")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (let ((types (cond ((pair? policy-types) policy-types)
                             (default-deny '("Ingress" "Egress"))
                             (else (filter string?
                                           (list (and (pair? ingress) "Ingress")
                                                 (and (pair? egress) "Egress")))))))
            (resource
              `((apiVersion . "networking.k8s.io/v1")
                (kind . "NetworkPolicy")
                (metadata ,@(k8s-metadata name namespace labels))
                (spec (podSelector ,@(if (null? pod-selector) '()
                                         `((matchLabels ,@pod-selector))))
                      ,@(if (null? types) '() `((policyTypes ,@types)))
                      ,@(if (or default-deny (null? ingress)) '() `((ingress ,@ingress)))
                      ,@(if (or default-deny (null? egress))  '() `((egress ,@egress))))))))

(define-construct resource-quota
  #:head name
  #:doc "a ResourceQuota"
  #:fields ((hard #:map #:doc "hard limits, e.g. (requests.cpu \"8\") (pods \"50\")")
            (scopes #:list #:doc "spec.scopes")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (resource
            `((apiVersion . "v1")
              (kind . "ResourceQuota")
              (metadata ,@(k8s-metadata name namespace labels))
              (spec (hard ,@hard)
                    ,@(if (null? scopes) '() `((scopes ,@scopes)))))))

(define-construct limit-range
  #:head name
  #:doc "a LimitRange from raw limit alists"
  #:fields ((limits #:list #:doc "raw limit alists, e.g. ((type . \"Container\") (default (cpu . \"500m\")))")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (resource
            `((apiVersion . "v1")
              (kind . "LimitRange")
              (metadata ,@(k8s-metadata name namespace labels))
              (spec (limits ,@limits)))))

;; ---------------------------------------------------------------------------
;; Gateway API
;; ---------------------------------------------------------------------------

(define-construct gateway-class
  #:head name
  #:doc "a Gateway API GatewayClass (cluster-scoped)"
  #:fields ((controller-name #:required #:doc "controllerName") (labels #:map #:doc "extra metadata.labels"))
  #:build (resource
            `((apiVersion . "gateway.networking.k8s.io/v1")
              (kind . "GatewayClass")
              (metadata ,@(k8s-metadata name #f labels))   ; cluster-scoped: no namespace
              (spec (controllerName . ,controller-name)))))

;; A Gateway listener (sub-construct). #:tls-certificate names one or more
;; Secrets → a Terminate-mode tls block; absent → a plain listener.
(define-construct listener
  #:head name
  #:doc "a Gateway listener (sub-construct of gateway)"
  #:fields ((protocol #:default "HTTP" #:doc "HTTP/HTTPS/TCP")
            (port #:required #:doc "listener port")
            (hostname #:default #f #:doc "hostname to match")
            (tls-certificate #:list #:doc "Secret names; sets Terminate-mode tls")
            (allowed-routes-from #:default "All" #:doc "allowedRoutes.namespaces.from"))
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
  #:doc "a Gateway API Gateway with listeners"
  #:fields ((gateway-class-name #:required #:doc "gatewayClassName")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (listener #:repeated #:construct listener #:doc "one (listener NAME …) per entry")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (%custom-resource #:api "gateway.networking.k8s.io/v1" #:kind "Gateway"
            #:name name #:namespace namespace #:labels labels
            #:spec `((gatewayClassName . ,gateway-class-name) (listeners ,@listener))))

(define-construct http-route
  #:head name
  #:doc "a Gateway API HTTPRoute to one backend service"
  #:fields ((namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (parent-name #:required #:doc "parent Gateway name")
            (parent-namespace #:default #f #:doc "parent Gateway namespace")
            (hostnames #:list #:doc "hostnames to match")
            (backend-service #:required #:doc "backend Service name")
            (backend-port #:required #:doc "backend Service port")
            (labels #:map #:doc "extra metadata.labels"))
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
  #:doc "an RBAC policy rule (sub-construct of role/cluster-role/cluster-rbac)"
  #:fields ((api-groups #:list #:doc "apiGroups (\"\" for core)")
            (resources #:list #:doc "resources")
            (non-resource-urls #:list #:doc "nonResourceURLs")
            (resource-names #:list #:doc "resourceNames")
            (verbs #:list #:doc "verbs (get list watch …)"))
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
  #:doc "a ServiceAccount"
  #:fields ((namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)") (labels #:map #:doc "extra metadata.labels"))
  #:build (%service-account #:name name #:namespace namespace #:labels labels))

(define-construct role
  #:head name
  #:doc "a Role from (rule …) entries"
  #:fields ((rule #:repeated #:construct rule #:doc "one (rule …) per policy rule")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)") (labels #:map #:doc "extra metadata.labels"))
  #:build (resource
            `((apiVersion . "rbac.authorization.k8s.io/v1")
              (kind . "Role")
              (metadata ,@(k8s-metadata name namespace labels))
              (rules ,@rule))))

(define-construct role-binding
  #:head name
  #:doc "a RoleBinding of a Role to a ServiceAccount"
  #:fields ((namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (role #:required #:doc "Role name")
            (service-account #:required #:doc "ServiceAccount name")
            (sa-namespace #:default namespace #:doc "ServiceAccount namespace (defaults to namespace)")
            (labels #:map #:doc "extra metadata.labels"))
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
  #:doc "a ClusterRole from (rule …) entries"
  #:fields ((rule #:repeated #:construct rule #:doc "one (rule …) per policy rule") (labels #:map #:doc "extra metadata.labels"))
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
  #:doc "a ClusterRoleBinding of a ClusterRole to a ServiceAccount"
  #:fields ((role #:required #:doc "ClusterRole name")
            (service-account #:required #:doc "ServiceAccount name")
            (sa-namespace #:default (current-k8s-namespace) #:doc "ServiceAccount namespace")
            (labels #:map #:doc "extra metadata.labels"))
  #:build (%cluster-role-binding #:name name #:role role #:service-account service-account
                                 #:sa-namespace sa-namespace #:labels labels))

(define-construct cluster-rbac
  #:head name
  #:doc "ServiceAccount + ClusterRole + ClusterRoleBinding, all named NAME"
  #:fields ((rule #:repeated #:construct rule #:doc "one (rule …) per policy rule")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)") (labels #:map #:doc "extra metadata.labels"))
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
  #:doc "Deployment + Service (expose) for one container"
  #:fields ((image #:required #:doc "container image ref")
            (port #:default 8080 #:doc "containerPort (and Service port)")
            (replicas #:default 2 #:doc "pod replicas")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (env #:list #:doc "env vars, (NAME \"value\") pairs")
            (env-from #:list #:doc "envFrom sources (configmap/secret names)")
            (volumes #:list #:doc "volume specs (mounted in the container)")
            (resources #:default '() #:doc "requests/limits alist; `res' parses \"cpu/mem\"")
            (privileged #:flag #:doc "privileged securityContext")
            (service-account #:default #f #:doc "serviceAccountName"))
  #:build (compose-ops 'app `(app ,name)
            (list (expose
                    (%deployment #:name name #:image image #:port port #:replicas replicas
                                 #:namespace namespace #:env env #:env-from env-from #:volumes volumes
                                 #:resources resources #:privileged privileged
                                 #:service-account service-account)))))

(define-construct public-app
  #:head name
  #:doc "app plus an Ingress on HOST"
  #:fields ((image #:required #:doc "container image ref")
            (port #:default 8080 #:doc "containerPort (and Service port)")
            (replicas #:default 2 #:doc "pod replicas")
            (namespace #:default (current-k8s-namespace) #:doc "target namespace (with-namespace scope)")
            (env #:list #:doc "env vars, (NAME \"value\") pairs")
            (env-from #:list #:doc "envFrom sources (configmap/secret names)")
            (volumes #:list #:doc "volume specs (mounted in the container)")
            (resources #:default '() #:doc "requests/limits alist; `res' parses \"cpu/mem\"")
            (privileged #:flag #:doc "privileged securityContext")
            (service-account #:default #f #:doc "serviceAccountName")
            (host #:default #f #:doc "ingress hostname (default NAME.example.com)"))
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
