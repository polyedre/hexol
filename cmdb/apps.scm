;;; cmdb/apps.scm — Helm releases per region (loaded by cmdb/region-body).
;;;
;;; Per-app shape:
;;;   (apps (<name> (chart (url <str>) (version <str>) (values <tree>))))
;;;
;;; Conditional stacks (gpu, sovereign-audit, backup) gated inline.

(hx-ops

  ;; ---------- Base: ingress, cert-manager, external-dns (all regions) ----------
  (hx-merge
    (apps
      (ingress-nginx
        (chart
          (url     "https://kubernetes.github.io/ingress-nginx")
          (version "4.11.2")
          (values
            (controller
              (replicaCount         ($ (if (eq? (attr 'tier) 'prod) 3 1)))
              (ingressClassResource (default #t))
              (service              (type LoadBalancer))
              (config               (use-proxy-protocol "true")
                                    (enable-real-ip      "true"))
              (metrics              (enabled #t))))))

      (cert-manager
        (chart
          (url     "https://charts.jetstack.io")
          (version "v1.15.3")
          (values
            (installCRDs  #t)
            (replicaCount ($ (if (eq? (attr 'tier) 'prod) 2 1)))
            (extraArgs   ("--dns01-recursive-nameservers-only"))
            (prometheus  (enabled #t)))))

      (external-dns
        (chart
          (url     "https://kubernetes-sigs.github.io/external-dns")
          (version "1.15.0")
          (values
            (provider      openstack)
            (txtOwnerId    ($ (symbol->string (attr 'region))))
            (domainFilters ($ (list (string-append (symbol->string (attr 'region)) "."
                                                    (symbol->string (attr 'dc)) ".example.com"))))
            (policy        sync))))))
  (hx-append packages ingress-nginx)
  (hx-append packages cert-manager)
  (hx-append packages external-dns)

  ;; ---------- Monitoring (all regions) ----------
  (hx-merge
    (apps
      (kube-prometheus-stack
        (chart
          (url     "https://prometheus-community.github.io/helm-charts")
          (version "62.6.0")
          (values
            (grafana
              (enabled       #t)
              (adminPassword ($ (string-append "admin-" (symbol->string (attr 'region)))))
              (ingress       (enabled #t)
                             (hosts ($ (list (string-append "grafana."
                                                             (symbol->string (attr 'region))
                                                             ".example.com"))))))
            (prometheus
              (prometheusSpec
                (retention   ($ (if (eq? (attr 'tier) 'prod) "30d" "7d")))
                (replicas    ($ (if (eq? (attr 'tier) 'prod) 2 1)))
                (storageSpec (volumeClaimTemplate
                               (spec (storageClassName "fast")
                                     (resources (requests (storage "200Gi"))))))))
            (alertmanager
              (alertmanagerSpec
                (replicas ($ (if (eq? (attr 'tier) 'prod) 3 1))))))))

      (loki
        (chart
          (url     "https://grafana.github.io/helm-charts")
          (version "6.16.0")
          (values
            (deploymentMode ($ (if (eq? (attr 'tier) 'prod) 'SimpleScalable 'SingleBinary)))
            (loki
              (auth_enabled #t)
              (storage
                (type s3)
                (s3 (endpoint    ($ (string-append "s3." (symbol->string (attr 'region)) ".example.com")))
                    (bucketNames (chunks ($ (string-append "loki-chunks-" (symbol->string (attr 'region))))))))))))

      (promtail
        (chart
          (url     "https://grafana.github.io/helm-charts")
          (version "6.16.0")
          (values
            (config
              (clients ($ (list "http://loki.observability.svc:3100/loki/api/v1/push")))))))))
  (hx-append packages kube-prometheus-stack)
  (hx-append packages loki)
  (hx-append packages promtail)

  ;; ---------- OpenStack add-ons (all regions) ----------
  (hx-merge
    (apps
      (openstack-exporter
        (chart
          (url     "https://openstack-exporter.github.io/helm-charts")
          (version "0.6.0")
          (values
            (cloudName ($ (symbol->string (attr 'region))))
            (cloudsYaml
              (clouds (default (auth (auth_url    ($ (string-append "https://auth."
                                                                     (symbol->string (attr 'region))
                                                                     ".example.com/v3")))
                                     (region_name ($ (symbol->string (attr 'region))))))))
            (serviceMonitor (enabled #t)))))

      (keystone-federation
        (chart
          (url     "https://charts.openstack.local")
          (version "2.4.1")
          (values
            (identityProvider
              (region   ($ (symbol->string (attr 'region))))
              (issuer   ($ (string-append "https://sso." (symbol->string (attr 'geo)) ".example.com")))
              (entityId ($ (string-append "keystone-" (symbol->string (attr 'region)))))))))

      (rally
        (chart
          (url     "https://charts.openstack.local")
          (version "1.8.0")
          (values
            (schedule     ($ (if (eq? (attr 'tier) 'prod) "0 */6 * * *" "0 4 * * *")))
            (targetRegion ($ (symbol->string (attr 'region))))
            (concurrency  ($ (if (eq? (attr 'tier) 'prod) 8 2))))))))
  (hx-append packages openstack-exporter)
  (hx-append packages keystone-federation)
  (hx-append packages rally)

  ;; ---------- Backup (skip dev tier — no SLO) ----------
  (hx-when (lambda (s) (not (eq? (attr 'tier) 'dev)))
    (hx-merge
      (apps
        (velero
          (chart
            (url     "https://vmware-tanzu.github.io/helm-charts")
            (version "7.2.1")
            (values
              (configuration
                (backupStorageLocation
                  ((name     default)
                   (provider aws)
                   (bucket   ($ (string-append "velero-" (symbol->string (attr 'region)))))
                   (config   (region ($ (symbol->string (attr 'region))))
                             (s3Url  ($ (string-append "https://s3."
                                                        (symbol->string (attr 'region))
                                                        ".example.com"))))))
                (volumeSnapshotLocation
                  ((name     default)
                   (provider aws)
                   (config   (region ($ (symbol->string (attr 'region))))))))
              (schedules
                (daily
                  (schedule "0 1 * * *")
                  (template (ttl ($ (if (eq? (attr 'tier) 'prod) "720h" "168h")))))))))))
    (hx-append packages velero))

  ;; ---------- GPU stack (hw-profile=gpu-dense only) ----------
  (hx-when (attrs (hw-profile gpu-dense))
    (hx-merge
      (apps
        (gpu-operator
          (chart
            (url     "https://nvidia.github.io/gpu-operator")
            (version "v24.6.1")
            (values
              (driver       (enabled #t))
              (toolkit      (enabled #t))
              (devicePlugin (enabled #t))
              (mig          (strategy mixed))
              (nodeSelector (nvidia.com/gpu "present"))
              (operator     (defaultRuntime containerd)))))
        (kserve
          (chart
            (url     "https://kserve.github.io/helm-charts")
            (version "0.13.1")
            (values
              (kserve
                (controller (gateway (ingressGateway (className "kserve-ingress-gateway"))))
                (modelmesh  (config (defaultModelDomain
                                      ($ (string-append "models."
                                                         (symbol->string (attr 'region))
                                                         ".example.com")))))))))))
    (hx-append packages gpu-operator)
    (hx-append packages kserve))

  ;; ---------- Sovereign audit stack (sovereignty=strict only) ----------
  (hx-when (attrs (sovereignty strict))
    (hx-merge
      (apps
        (falco
          (chart
            (url     "https://falcosecurity.github.io/charts")
            (version "4.8.4")
            (values
              (driver     (kind ebpf))
              (collectors (kubernetes (enabled #t)))
              (falcosidekick
                (enabled #t)
                (config  (webhook (address ($ (string-append "https://siem."
                                                              (symbol->string (attr 'geo))
                                                              ".example.com/ingest"))))))
              (tty 120))))
        (gatekeeper
          (chart
            (url     "https://open-policy-agent.github.io/gatekeeper/charts")
            (version "3.17.1")
            (values
              (replicas      3)
              (auditInterval 60)
              (constraintViolationsLimit 200))))
        (vault
          (chart
            (url     "https://helm.releases.hashicorp.com")
            (version "0.28.1")
            (values
              (server (ha           (enabled #t) (replicas 5))
                      (auditStorage (enabled #t))
                      (dataStorage  (size "100Gi") (storageClass "fast")))
              (injector (enabled #t)))))))
    (hx-append packages falco)
    (hx-append packages gatekeeper)
    (hx-append packages vault)
    (hx-append compliance-controls audit-all-syscalls)
    (hx-append compliance-controls deny-by-default-netpol)))
