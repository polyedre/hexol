;;; examples/helm-kube-prometheus-stack.scm
;;;
;;; The Helm chart `kube-prometheus-stack`, converted to our system and
;;; built on the shared `(hexol k8s)` library — the same library that
;;; backs examples/kubernetes.scm.
;;;
;;; A Helm chart can be consumed as an *opaque release* — a chart URL +
;;; version + a `values` blob the engine passes through untouched. Here it
;;; is instead the same chart expressed as native ops: every object the chart
;;; renders is a `(deployment ...)` / `(service ...)` / `(custom-resource
;;; ...)` sugar call from the k8s library; values.yaml is a plain `values`
;;; alist; each `{{- if .Values.x.enabled }}` is a `(hx-when ...)` whose body
;;; is just the component's resources, inline; the common labels are a
;;; `label-all` transform.
;;;
;;; Because it bottoms out in the same op record as everything else, the
;;; one CLI works on it unchanged:
;;;
;;;   ./bin/hexol tree    examples/helm-kube-prometheus-stack.scm
;;;   ./bin/hexol explain kubernetes_resources.3.spec.replicas \
;;;                       examples/helm-kube-prometheus-stack.scm
;;;   ./bin/hexol render -o yaml examples/helm-kube-prometheus-stack.scm  ; -> multi-doc YAML
;;;
;;; `#:resources` / `(res …)` strings are "cpuReq-cpuLim/memReq[-memLim]"
;;; (k8s requests/limits); `*` means unbounded and the memory limit is optional.

(use-modules (hexol k8s))

;; ---------------------------------------------------------------------------
;; values.yaml  (defaults — the same keys the upstream chart exposes)
;; ---------------------------------------------------------------------------
(define values
  '((namespace          . "monitoring")
    (release            . "kube-prometheus-stack")

    (commonLabels       (team . "platform")
                        (env  . "prod"))

    (prometheusOperator (enabled  . #t)
                        (image    . "quay.io/prometheus-operator/prometheus-operator:v0.76.0")
                        (replicas . 1))

    (prometheus         (enabled    . #t)
                        (image      . "quay.io/prometheus/prometheus:v2.54.1")
                        (replicas   . 2)
                        (retention  . "30d")
                        (scrapeInterval . "30s")
                        (storage    (size  . "200Gi")
                                    (class . "fast")))

    (alertmanager       (enabled  . #t)
                        (image    . "quay.io/prometheus/alertmanager:v0.27.0")
                        (replicas . 3))

    (grafana            (enabled       . #t)
                        (image         . "docker.io/grafana/grafana:11.2.0")
                        (adminPassword . "admin")
                        (ingress       (enabled . #t)
                                       (host    . "grafana.example.com")))

    (kubeStateMetrics   (enabled . #t)
                        (image   . "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0"))

    (nodeExporter       (enabled . #t)
                        (image   . "quay.io/prometheus/node-exporter:v1.8.2")
                        (port    . 9100))

    (defaultRules       (enabled . #t))))

;; ---------------------------------------------------------------------------
;; value access + naming helpers
;; ---------------------------------------------------------------------------
(define (vget path) (state-get values path))
(define (on? path) (lambda (s) (vget path)))         ; (hx-when (on? '(grafana enabled)) ...)

(define ns      (vget '(namespace)))
(define release (vget '(release)))
(define (fullname suffix) (string-append release "-" suffix))

;; _helpers.tpl common labels + operator-supplied commonLabels; applied to
;; every resource by `label-all` at the end. (Guile's `append` would work
;; fine now that the surface ops are hx-prefixed; srfi-1 `concatenate` reads
;; just as well for joining label lists.)
(define (common-labels)
  (concatenate
    (list
      `((app.kubernetes.io/part-of    . "kube-prometheus-stack")
        (app.kubernetes.io/managed-by . "hexol")
        (app.kubernetes.io/instance   . ,release))
      (or (vget '(commonLabels)) '()))))

;; ---------------------------------------------------------------------------
;; The chart. Each `(hx-when (on? ...) ...)` is a component: its resources are
;; listed inline, gated exactly like the upstream `{{- if .Values.x }}`.
;; ---------------------------------------------------------------------------
(hx-ops
 ;; one namespace scope for the whole release — every resource below lands
 ;; in `ns` without repeating #:namespace (an explicit #:namespace still wins).
 (with-namespace ns

  ;; prometheus-operator: RBAC + Deployment (Service derived) + self-ServiceMonitor.
  (hx-when (on? '(prometheusOperator enabled))
    (cluster-rbac #:name (fullname "operator")
      #:rules '(((apiGroups "monitoring.coreos.com")
                 (resources "prometheuses" "alertmanagers" "servicemonitors"
                            "podmonitors" "prometheusrules" "probes")
                 (verbs "*"))
                ((apiGroups "apps") (resources "statefulsets") (verbs "*"))
                ((apiGroups "") (resources "configmaps" "secrets" "services" "endpoints" "pods")
                 (verbs "*"))))
    (expose
      (deployment #:name (fullname "operator") #:image (vget '(prometheusOperator image))
                  #:replicas (vget '(prometheusOperator replicas))
                  #:port 8080 #:service-account (fullname "operator")
                  #:args '("--kubelet-service=kube-system/kubelet")
                  #:resources "100m-*/128Mi-256Mi"))
    (service-monitor #:name (fullname "operator")))

  ;; Prometheus CR (reconciled by the operator) + RBAC + Service + self-ServiceMonitor.
  (hx-when (on? '(prometheus enabled))
    (cluster-rbac #:name (fullname "prometheus")
      #:rules '(((apiGroups "") (resources "nodes" "nodes/metrics" "services" "endpoints" "pods")
                 (verbs "get" "list" "watch"))
                ((apiGroups "") (resources "configmaps") (verbs "get"))
                ((nonResourceURLs "/metrics") (verbs "get"))))
    (custom-resource
      #:api "monitoring.coreos.com/v1" #:kind "Prometheus"
      #:name (fullname "prometheus")
      #:spec `((replicas . ,(vget '(prometheus replicas)))
               (image . ,(vget '(prometheus image)))
               (retention . ,(vget '(prometheus retention)))
               (scrapeInterval . ,(vget '(prometheus scrapeInterval)))
               (serviceAccountName . ,(fullname "prometheus"))
               ;; empty selectors == "discover every ServiceMonitor / Rule"
               (serviceMonitorSelector)
               (ruleSelector)
               (resources ,@(res "500m-*/2Gi"))
               (storage
                 (volumeClaimTemplate
                   (spec (storageClassName . ,(vget '(prometheus storage class)))
                         (accessModes "ReadWriteOnce")
                         (resources (requests (storage . ,(vget '(prometheus storage size))))))))
               (alerting
                 (alertmanagers ((namespace . ,ns)
                                 (name . ,(fullname "alertmanager"))
                                 (port . "http"))))))
    (service #:name (fullname "prometheus") #:port 9090 #:target-port 9090)
    (service-monitor #:name (fullname "prometheus")))

  ;; Alertmanager CR + ServiceAccount (no cluster RBAC needed) + Service.
  (hx-when (on? '(alertmanager enabled))
    (service-account #:name (fullname "alertmanager"))
    (custom-resource
      #:api "monitoring.coreos.com/v1" #:kind "Alertmanager"
      #:name (fullname "alertmanager")
      #:spec `((replicas . ,(vget '(alertmanager replicas)))
               (image . ,(vget '(alertmanager image)))
               (serviceAccountName . ,(fullname "alertmanager"))
               (resources ,@(res "100m-*/256Mi"))))
    (service #:name (fullname "alertmanager") #:port 9093 #:target-port 9093))

  ;; Grafana: datasource ConfigMap + Deployment + Service + optional Ingress.
  (hx-when (on? '(grafana enabled))
    (configmap #:name (fullname "grafana-datasource")
      #:data `((datasource.yaml . ,(string-append
                                     "apiVersion: 1\n"
                                     "datasources:\n"
                                     "  - name: Prometheus\n"
                                     "    type: prometheus\n"
                                     "    access: proxy\n"
                                     "    isDefault: true\n"
                                     "    url: http://" (fullname "prometheus") "." ns ".svc:9090\n"))))
    (deployment #:name (fullname "grafana") #:image (vget '(grafana image)) #:replicas 1
                #:port 3000
                #:volumes `((configMap ,(fullname "grafana-datasource")
                                       "/etc/grafana/provisioning/datasources"))
                #:resources "100m-*/128Mi-256Mi")
    (service #:name (fullname "grafana") #:port 80 #:target-port 3000)
    (hx-when (on? '(grafana ingress enabled))
      (ingress #:name (fullname "grafana") #:port 80
               #:host (vget '(grafana ingress host)))))

  ;; kube-state-metrics: RBAC + Deployment (Service derived) + ServiceMonitor.
  (hx-when (on? '(kubeStateMetrics enabled))
    (cluster-rbac #:name (fullname "kube-state-metrics")
      #:rules '(((apiGroups "")
                 (resources "configmaps" "secrets" "nodes" "pods" "services" "serviceaccounts"
                            "resourcequotas" "replicationcontrollers" "limitranges"
                            "persistentvolumeclaims" "persistentvolumes" "namespaces" "endpoints")
                 (verbs "list" "watch"))
                ((apiGroups "apps")
                 (resources "statefulsets" "daemonsets" "deployments" "replicasets")
                 (verbs "list" "watch"))
                ((apiGroups "batch") (resources "cronjobs" "jobs") (verbs "list" "watch"))))
    (expose
      (deployment #:name (fullname "kube-state-metrics") #:image (vget '(kubeStateMetrics image))
                  #:replicas 1 #:port 8080
                  #:service-account (fullname "kube-state-metrics")
                  #:resources "50m-*/64Mi-128Mi"))
    (service-monitor #:name (fullname "kube-state-metrics")))

  ;; node-exporter: DaemonSet (host network/pid) + Service + ServiceMonitor.
  (hx-when (on? '(nodeExporter enabled))
    (daemonset #:name (fullname "node-exporter") #:image (vget '(nodeExporter image))
               #:port (vget '(nodeExporter port)) #:host-network #t #:host-pid #t
               #:args (list (string-append "--web.listen-address=:"
                                           (number->string (vget '(nodeExporter port)))))
               #:resources "50m-*/32Mi-64Mi")
    (service #:name (fullname "node-exporter") #:port (vget '(nodeExporter port))
             #:port-name "metrics")
    (service-monitor #:name (fullname "node-exporter") #:port "metrics"))

  ;; A default PrometheusRule (the chart ships hundreds; one representative).
  (hx-when (on? '(defaultRules enabled))
    (custom-resource
      #:api "monitoring.coreos.com/v1" #:kind "PrometheusRule"
      #:name (fullname "default-rules")
      #:spec `((groups ((name . "node.rules")
                        (rules ((alert . "TargetDown")
                                (expr  . "100 * (count by(job) (up == 0) / count by(job) (up)) > 10")
                                (for   . "10m")
                                (labels (severity . "warning"))
                                (annotations (summary . "Targets are down")))))))))

  ;; _helpers.tpl common labels, applied to every resource at once.
  (label-all (common-labels))))
