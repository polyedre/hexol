;;; cmdb/region-body.scm — per-region rendering body for the CMDB.
;;;
;;; `region-body-ops` returns the ops that build one region's subtree
;;; from its attr alist; region-render.scm runs (resolve (region-body-ops)
;;; attrs) per `(region <name> <attrs>)` fact. Lives in the CMDB, not the
;;; examples — examples stay independent of this subsystem.

(define-module (cmdb region-body)
  #:use-module (hexol kernel)
  #:use-module (hexol surface)
  #:export (region-body-ops))

(define (region-body-ops)
  (hx-ops

    ;; ---------- Per-region defaults ----------
    (hx-merge
      (helm
        (repos
          (jetstack            "https://charts.jetstack.io")
          (ingress-nginx       "https://kubernetes.github.io/ingress-nginx")
          (prometheus          "https://prometheus-community.github.io/helm-charts")
          (grafana             "https://grafana.github.io/helm-charts")
          (nvidia              "https://nvidia.github.io/gpu-operator")
          (falco               "https://falcosecurity.github.io/charts")
          (hashicorp           "https://helm.releases.hashicorp.com")
          (vmware-tanzu        "https://vmware-tanzu.github.io/helm-charts")
          (openstack-exporter  "https://openstack-exporter.github.io/helm-charts")
          (kserve              "https://kserve.github.io/helm-charts")
          (gatekeeper          "https://open-policy-agent.github.io/gatekeeper/charts")))
      (kubernetes
        (version       "1.33.0")
        (control-plane (replicas 3) (etcd-backup-schedule "0 */4 * * *"))
        (runtime       containerd)))

    ;; ---------- Computed identifiers ----------
    (hx-merge
      (cluster-name    ($ (string-append "k8s-" (symbol->string (attr 'region)))))
      (kubernetes
        (api-endpoint  ($ (string-append "https://api."
                                          (symbol->string (attr 'region))
                                          ".example.com:6443"))))
      (mirror          ($ (string-append "rpm." (symbol->string (attr 'dc)) ".example.com")))
      (network
        (region-domain ($ (string-append (symbol->string (attr 'region))
                                          "." (symbol->string (attr 'dc))
                                          ".example.com")))))

    ;; ---------- Geo defaults ----------
    (hx-case (attr 'geo)
      ((eu)    (hx-merge (locale (timezone "Europe/Paris"))
                         (ntp    (pool "europe.pool.ntp.org"))
                         (cdn    (edge "edge-eu.example.com"))))
      ((na)    (hx-merge (locale (timezone "America/Toronto"))
                         (ntp    (pool "north-america.pool.ntp.org"))
                         (cdn    (edge "edge-na.example.com"))))
      ((apac)  (hx-merge (locale (timezone "Asia/Singapore"))
                         (ntp    (pool "asia.pool.ntp.org"))
                         (cdn    (edge "edge-apac.example.com"))))
      ((latam) (hx-merge (locale (timezone "America/Sao_Paulo"))
                         (ntp    (pool "south-america.pool.ntp.org"))
                         (cdn    (edge "edge-latam.example.com"))))
      ((me)    (hx-merge (locale (timezone "Asia/Dubai"))
                         (ntp    (pool "asia.pool.ntp.org"))
                         (cdn    (edge "edge-me.example.com")))))

    ;; ---------- Hardware profiles ----------
    (hx-case (attr 'hw-profile)
      ((standard)
       (hx-merge
         (hardware
           (cpu     (sockets 2) (cores-per-socket 32) (smt #t))
           (memory  (total-gb 256))
           (storage (kind nvme) (size-gb 1920) (raid 1))
           (nic     (model "Mellanox CX-5") (speed-gbps 25) (count 2)))
         (kubernetes
           (node-pool (default (machine-type s4-32-256) (min-size 3) (max-size 50))))))

      ((gpu-dense)
       (hx-merge
         (hardware
           (cpu     (sockets 2) (cores-per-socket 48) (smt #t))
           (memory  (total-gb 1024))
           (storage (kind nvme) (size-gb 7680) (raid 0))
           (nic     (model "Mellanox CX-7") (speed-gbps 200) (count 2))
           (gpu     (model "NVIDIA H100") (count 8) (mig-enabled #t)))
         (kubernetes
           (node-pool
             (default (machine-type s4-48-512) (min-size 3) (max-size 30))
             (gpu     (machine-type g5-h100-8) (min-size 2) (max-size 16)
                      (taints ("nvidia.com/gpu=present:NoSchedule"))))))
       (hx-append features gpu-acceleration))

      ((storage-heavy)
       (hx-merge
         (hardware
           (cpu     (sockets 2) (cores-per-socket 24) (smt #t))
           (memory  (total-gb 512))
           (storage (kind hdd-jbod) (size-gb 192000) (disks 24))
           (nic     (model "Mellanox CX-6") (speed-gbps 100) (count 2)))
         (kubernetes
           (node-pool
             (default (machine-type s4-24-512)      (min-size 3) (max-size 20))
             (storage (machine-type x-storage-192t) (min-size 6) (max-size 60)
                      (taints ("workload=storage:NoSchedule"))))))
       (hx-append features bulk-storage))

      ((compute-optimized)
       (hx-merge
         (hardware
           (cpu     (sockets 2) (cores-per-socket 64) (smt #f) (turbo-pinned #t))
           (memory  (total-gb 384))
           (storage (kind nvme) (size-gb 3840) (raid 1))
           (nic     (model "Mellanox CX-6") (speed-gbps 100) (count 2)))
         (kubernetes
           (node-pool (default (machine-type c4-64-384) (min-size 3) (max-size 80)))))))

    ;; ---------- Network profiles ----------
    (hx-case (attr 'network-profile)
      ((basic)
       (hx-merge
         (network
           (cni      flannel)
           (pod-cidr "10.244.0.0/16")
           (svc-cidr "10.96.0.0/12")
           (mtu      1500)
           (egress   (mode shared-nat)))))

      ((advanced)
       (hx-merge
         (network
           (cni           cilium)
           (pod-cidr      "10.42.0.0/16")
           (svc-cidr      "10.96.0.0/12")
           (mtu           9000)
           (encryption    wireguard)
           (bgp           (enabled #t) (asn 64512) (peers ("10.0.0.1" "10.0.0.2")))
           (egress        (mode bgp-direct))
           (load-balancer (mode l2-announcement))))
       (hx-append features advanced-networking))

      ((sovereign)
       (hx-merge
         (network
           (cni             cilium)
           (pod-cidr        "10.42.0.0/16")
           (svc-cidr        "10.96.0.0/12")
           (mtu             9000)
           (encryption      mtls-mandatory)
           (egress          (mode allow-list) (peers ("internal-peer.sovereign.local")))
           (egress-default  deny)
           (audit-all-flows #t)))
       (hx-append features sovereign-networking)))

    ;; ---------- Apps (only on Kubernetes > 1.32.4) ----------
    ;; load-inventory-file returns the fragment's ops; hx-when folds them
    ;; when the predicate holds.
    (hx-when (lambda (s) (semver> (get '(kubernetes version)) "1.32.4"))
      (load-inventory-file "cmdb/apps.scm"))

    ;; ---------- Cross-cutting: sovereign regions label + annotate every
    ;; k8s resource for compliance/audit, regardless of source.
    (hx-when (attrs (sovereignty strict))
      (annotate-all '((audit.example.com/required . "true")))
      (label-all    '((compliance . "strict"))))

    ;; ---------- Derived summaries ----------
    (hx-when (lambda (s) (pair? (get '(packages))))
      (hx-merge
        (provisioning
          (app-count     ($ (length (get '(packages)))))
          (feature-count ($ (length (or (get '(features)) '())))))))))
