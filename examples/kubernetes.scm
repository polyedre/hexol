;;; examples/kubernetes.scm — first-party k8s apps, built on (hexol k8s).
;;;
;;; Two applications, each deployed into its own same-named namespace via
;;; `with-namespace`, each with a realistic ConfigMap (env) + Secret
;;; (mounted). The cross-cutting ops run over the whole set: tls-all adds
;;; TLS to the public app's Ingress, checksum-config annotates each
;;; Deployment with a hash of the config it mounts (and self-reports any
;;; dangling reference), and compliance-all audits everything.
;;;
;;; The surface is the unified record body: a positional name, then `(key
;;; value)` entries (values are evaluated Scheme; the schema fills defaults
;;; and rejects unknown keys). `(data …)` holds ConfigMap/Secret payloads;
;;; `cm`/`sec`/`pvc` name a volume/env source and `mount` pairs one with a
;;; path; a `(rule …)` is one RBAC policy rule.
;;;
;;; All the builders live in the shared `(hexol k8s)` library; this file
;;; is just a consumer.

(use-modules (hexol k8s))

(hx-ops

  ;; ---- tintin: public app in namespace "tintin" ----
  (with-namespace "tintin"
    ;; ServiceAccount + ClusterRole + ClusterRoleBinding, merged into one op.
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
