;;; examples/kubernetes.scm — first-party k8s apps, built on (hexol k8s).
;;;
;;; Two apps, each in its own same-named namespace (`with-namespace`), with
;;; a ConfigMap (env) + Secret (mounted). Cross-cutting ops run over the
;;; whole set: tls-all adds TLS to the public Ingress, checksum-config
;;; hashes each Deployment's mounted config (reports dangling refs),
;;; compliance-all audits everything.
;;;
;;; Surface: unified record body — positional name, then `(key value)`
;;; entries (values are evaluated Scheme; schema fills defaults, rejects
;;; unknown keys). `(data …)` is the ConfigMap/Secret payload; `cm`/`sec`/
;;; `pvc` name a source, `mount` pairs one with a path; `(rule …)` is one
;;; RBAC rule. All builders live in `(hexol k8s)`; this file consumes them.

(use-modules (hexol k8s)
             (hexol apply))   ; appliers for `hexol apply`

;; ---- apply: push these manifests to a cluster ----
;;
;; `hexol apply` renders (kubernetes_resources) and `kubectl apply`s it against
;; your current kubeconfig (~/.kube/config); `--dry-run` delegates to kubectl's
;; own `--dry-run=server`. The `wait-for` #:pre gates on the API answering first.
(appliers
  ("kubernetes"
   (kubectl-applier
     #:pre (wait-for "kube-API reachable"
                     (cmd "kubectl" "get" "--raw=/readyz")
                     #:timeout 30))))

(hx-ops

  ;; ---- tintin: public app in namespace "tintin" ----
  (with-namespace "tintin"
    ;; ServiceAccount + ClusterRole + ClusterRoleBinding in one op.
    (cluster-rbac "tintin"
      (rule (api-groups "")     (resources "configmaps" "secrets") (verbs "get" "list" "watch"))
      (rule (api-groups "")     (resources "pods" "services")      (verbs "get" "list"))
      (rule (api-groups "apps") (resources "deployments")          (verbs "get" "list" "watch")))
    (public-app "tintin"
      (image "secure.io/tintin:1.0")
      (port 8080)
      (service-account "tintin")
      (env-from (cm "tintin-config"))
      (volumes  (mount (sec "tintin-secret") "/etc/tintin/secret"))
      (resources "100m-500m/128Mi"))
    (configmap "tintin-config"
      (data (LOG_LEVEL "info") (FEATURE_MOON "true") (REGION "alpha5")))
    (secret "tintin-secret"
      (data (API_TOKEN "dGludGluLXRva2Vu"))))

  ;; ---- loulou: internal app in namespace "loulou" ----
  (with-namespace "loulou"
    (app "loulou"
      (image "secure.io/loulou:2.1")
      (port 9000)
      (replicas 2)
      (env-from (cm "loulou-config"))
      (volumes  (mount (sec "loulou-secret") "/etc/loulou/secret"))
      (resources "200m-*/256Mi"))
    (configmap "loulou-config"
      (data (LOG_LEVEL "debug") (CACHE_SIZE "256")))
    (secret "loulou-secret"
      (data (DB_PASSWORD "bG91bG91LXNlY3JldA=="))))

  ;; ---- cross-cutting ----
  (tls-all)
  (checksum-config)
  (compliance-all "secure.io"))
