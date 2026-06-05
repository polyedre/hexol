;;; examples/inventory.scm — a small OpenStack-on-Kubernetes region fleet.
;;;
;;; One self-contained file: the region table, the per-region body, and the
;;; enumeration that folds the body over the table. `hx-each` (surface, over
;;; the kernel's `for-each-into`) resolves the body once per region with that
;;; region's attributes as the query, stashing each result under
;;; `(regions <name>)`:
;;;
;;;   ./bin/hexol render examples/inventory.scm                 # whole fleet
;;;   ./bin/hexol render --path regions.alpha5 examples/inventory.scm
;;;   ./bin/hexol explain regions.alpha5.network.cni examples/inventory.scm
;;;
;;; The body is a pure function of a region's attributes: `hx-case` on the geo
;;; / hardware / network axes selects the config, `hx-when` gates the k8s app
;;; load and the sovereign cross-cuts, and `$` computes derived identifiers.
;;; Three regions exercise the branches (gpu/advanced/prod, sovereign/strict,
;;; standard/basic/dev). The example is independent of the CMDB subsystem.

(use-modules (hexol))

;; ---------- the region table (data) ----------
;;
;; Dispatch axes pre-derived as data: dc, geo, hw-profile, network-profile,
;; tier, sovereignty. Each entry's cdr is the attribute seed for the body.

(define regions
  '((alpha5 (region . alpha5) (dc . alpha) (geo . eu) (hw-profile . gpu-dense)
     (network-profile . advanced)  (tier . prod) (sovereignty . none))
    (bravo1 (region . bravo1) (dc . bravo) (geo . eu) (hw-profile . standard)
          (network-profile . sovereign) (tier . prod) (sovereignty . strict))
    (charlie6 (region . charlie6) (dc . charlie) (geo . na) (hw-profile . standard)
          (network-profile . basic)     (tier . dev)  (sovereignty . none))))

(hx-each regions #:into regions
   ;; Per-region defaults.
   (hx-merge
    (helm
     (repos
      (jetstack      "https://charts.jetstack.io")
      (ingress-nginx "https://kubernetes.github.io/ingress-nginx")
      (prometheus    "https://prometheus-community.github.io/helm-charts")
      (nvidia        "https://nvidia.github.io/gpu-operator")
      (cilium        "https://helm.cilium.io")))
    (kubernetes
     (version       "1.33.0")
     (control-plane (replicas 3) (etcd-backup-schedule "0 */4 * * *"))
     (runtime       containerd)))

   ;; Computed identifiers from the query attributes. `str` concatenates
   ;; (coercing the symbol attrs); `fmt` fills a template — no
   ;; `string-append` / `symbol->string` ceremony either way.
   (hx-merge
    (cluster-name ($ (str "k8s-" (attr 'region))))
    (kubernetes
     (api-endpoint ($ (fmt "https://api.~a.example.com:6443" (attr 'region)))))
    (mirror ($ (fmt "rpm.~a.example.com" (attr 'dc))))
    (network
     (region-domain ($ (fmt "~a.~a.example.com" (attr 'region) (attr 'dc))))))

   ;; Geo defaults.
   (hx-case (attr 'geo)
            ((eu) (hx-merge (locale (timezone "Europe/Paris"))
                            (ntp    (pool "europe.pool.ntp.org"))))
            ((na) (hx-merge (locale (timezone "America/Toronto"))
                            (ntp    (pool "north-america.pool.ntp.org"))))
            ((apac) (hx-merge (locale (timezone "Asia/Singapore"))
                              (ntp    (pool "asia.pool.ntp.org")))))

   ;; Hardware profile.
   (hx-case (attr 'hw-profile)
            ((standard)
             (hx-merge (hardware (cpu (cores 64)) (memory (total-gb 256))
                                 (storage (kind nvme) (size-gb 1920)))))
            ((gpu-dense)
             (hx-merge (hardware (cpu (cores 96)) (memory (total-gb 1024))
                                 (storage (kind nvme) (size-gb 7680))
                                 (gpu (model "NVIDIA H100") (count 8))))
             (hx-append features gpu-acceleration)))

   ;; Network profile.
   (hx-case (attr 'network-profile)
            ((basic)
             (hx-merge (network (cni flannel) (pod-cidr "10.244.0.0/16") (mtu 1500))))
            ((advanced)
             (hx-merge (network (cni cilium) (pod-cidr "10.42.0.0/16") (mtu 9000)
                                (encryption wireguard)))
             (hx-append features advanced-networking))
            ((sovereign)
             (hx-merge (network (cni cilium) (pod-cidr "10.42.0.0/16") (mtu 9000)
                                (encryption mtls-mandatory)
                                (egress (mode allow-list)) (egress-default deny)))
             (hx-append features sovereign-networking)))

   ;; Pull in the k8s app manifests (only on a recent enough cluster).
   ;; `load-inventory-file` reads the fragment and returns its list of ops;
   ;; `hx-when` flattens that list into its body and folds it when the
   ;; predicate fires. (The read is eager — the gate is on the effect, the
   ;; way the old lazy `load` op gated the read.) The predicate is a bare
   ;; expression evaluated at fold time, where `get` reads accumulated state.
   (hx-when (semver> (get '(kubernetes version)) "1.32.4")
            (load-inventory-file "examples/kubernetes.scm"))

   ;; Sovereign regions: stamp every loaded k8s resource, whatever its source.
   (hx-when (attrs (sovereignty strict))
            (annotate-all '((audit.example.com/required . "true")))
            (label-all    '((compliance . "strict"))))

   ;; Derived summary, once features exist.
   (hx-when (pair? (get '(features)))
            (hx-merge (provisioning (feature-count ($ (length (get '(features)))))))))
