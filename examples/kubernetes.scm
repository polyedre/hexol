;;; examples/kubernetes.scm — first-party k8s apps, built on (hexol k8s).
;;;
;;; Two applications, each deployed into its own same-named namespace via
;;; `with-namespace`, each with a realistic ConfigMap (env) + Secret
;;; (mounted). The cross-cutting ops run over the whole set: tls-all adds
;;; TLS to the public app's Ingress, checksum-config annotates each
;;; Deployment with a hash of the config it mounts (and self-reports any
;;; dangling reference), and compliance-all audits everything.
;;;
;;; The `#:resources` strings are "cpuReq-cpuLim/memReq[-memLim]" (k8s
;;; requests/limits); `*` means unbounded and the memory limit is optional.
;;;
;;; All the builders live in the shared `(hexol k8s)` library; this file
;;; is just a consumer.

(use-modules (hexol k8s))

(hx-ops

  ;; ---- tintin: public app in namespace "tintin" ----
  (with-namespace "tintin"
    ;; ServiceAccount + ClusterRole + ClusterRoleBinding, merged into one op.
    (cluster-rbac #:name "tintin"
      #:rules '(((apiGroups "") (resources "configmaps" "secrets") (verbs "get" "list" "watch"))
                ((apiGroups "") (resources "pods" "services") (verbs "get" "list"))
                ((apiGroups "apps") (resources "deployments") (verbs "get" "list" "watch"))))
    (public-app #:name "tintin" #:image "secure.io/tintin:1.0" #:port 8080
                #:service-account "tintin"
                #:env-from '((configMap "tintin-config"))
                #:volumes  '((secret "tintin-secret" "/etc/tintin/secret"))
                #:resources "100m-500m/128Mi")
    (configmap #:name "tintin-config"
               #:data '((LOG_LEVEL . "info") (FEATURE_MOON . "true") (REGION . "alpha5")))
    (secret    #:name "tintin-secret"
               #:data '((API_TOKEN . "dGludGluLXRva2Vu"))))

  ;; ---- loulou: internal app in namespace "loulou" ----
  (with-namespace "loulou"
    (app #:name "loulou" #:image "secure.io/loulou:2.1" #:port 9000 #:replicas 2
         #:env-from '((configMap "loulou-config"))
         #:volumes  '((secret "loulou-secret" "/etc/loulou/secret"))
         #:resources "200m-*/256Mi")
    (configmap #:name "loulou-config"
               #:data '((LOG_LEVEL . "debug") (CACHE_SIZE . "256")))
    (secret    #:name "loulou-secret"
               #:data '((DB_PASSWORD . "bG91bG91LXNlY3JldA=="))))

  ;; ---- cross-cutting ----
  (tls-all)
  (checksum-config)
  (compliance-all "secure.io"))
