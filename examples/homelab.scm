;;; examples/homelab.scm — a whole homelab from one inventory.
;;;
;;; A single file that describes a self-hosted Kubernetes homelab end to end:
;;; the infrastructure that runs it (a 3-node Talos cluster on OVH's public
;;; cloud, an OpenStack region) and the cluster itself (the platform Helm
;;; charts plus a handful of self-hosted apps). Because every op bottoms out
;;; in the same state alist, the two concerns live in one `(hx-ops …)` and
;;; are pulled apart at *render* time by picking a different accumulator —
;;; this is hexol's "same inventory, different effects" property:
;;;
;;;   ;; 1. the infrastructure  →  Terraform JSON (the (terraform_config) tree)
;;;   ./bin/hexol render -o terraform examples/homelab.scm > infra.tf.json
;;;   terraform init && terraform apply           # OpenStack creds via OS_* / clouds.yaml
;;;   terraform output -raw talosconfig > ~/.talos/config
;;;   terraform output -raw kubeconfig  > ~/.kube/config
;;;
;;;   ;; 2. the cluster         →  multi-doc YAML (the (kubernetes_resources) list)
;;;   ./bin/hexol render -o yaml examples/homelab.scm | kubectl apply -f -
;;;
;;;   ;; and the usual introspection over the whole thing:
;;;   ./bin/hexol tree examples/homelab.scm
;;;   ./bin/hexol explain terraform_config.resource examples/homelab.scm
;;;
;;; Bootstrap. The hardest part of a Talos cluster is PKI + the one-time
;;; `bootstrap` call, and we let the `siderolabs/talos` Terraform provider own
;;; both: `talos_machine_secrets` generates the cluster CA/keys once,
;;; `data.talos_machine_configuration` renders a per-node machine config from
;;; those secrets plus our patches (built *here*, in Scheme, and serialized to
;;; YAML), each node boots that config as its `user_data`, and
;;; `talos_machine_bootstrap` initialises etcd on the first node. `terraform
;;; apply` therefore takes bare VMs to a running, kubeconfig-yielding cluster.
;;; Talos is configured with `cni: none` + `proxy.disabled`, so Cilium (below)
;;; is the CNI and the kube-proxy replacement — apply it first, then the rest.
;;;
;;; Helm charts are rendered, not delegated. Rather than emit a Flux/Argo
;;; release object and need a controller in-cluster to expand it, each chart is
;;; expanded *at render time* by shelling out to `helm template` and splicing
;;; the manifests it prints straight into `(kubernetes_resources)` — the same
;;; "read a local input while folding" trick as the SSH key above. So
;;; `-o yaml` is a complete, self-contained manifest stream (`kubectl apply`
;;; needs nothing else), every chart object is a first-class resource the CLI
;;; can label / explain, and the chart's `values` is a plain Scheme alist we
;;; serialize to the `--values` file. This needs `helm` and `yq` on PATH at
;;; render time; resolving the inventory runs them, so `-o terraform` on a host
;;; without them just warns and skips the charts (the infra is unaffected).
;;;
;;; The OVH/OpenStack resource types, the Talos config knobs, the chart list
;;; and the apps are all *content* and live here; (hexol terraform) only knows
;;; the Terraform language and (hexol k8s) only knows Kubernetes.

(use-modules (hexol k8s)         ; Kubernetes vocabulary (+ surface: hx-ops, str, fmt, …;
                                 ; namespace, role/role-binding, which-cmd/json-manifests,
                                 ; remote-manifest — the external-manifest plumbing)
             (hexol terraform)   ; Terraform language vocabulary
             (hexol yaml)        ; emit-yaml-document — to build Talos user_data + helm values
             (hexol apply)       ; appliers / terraform-applier / kubectl-applier + checks
                                 ; (wait-for / check / report / cmd) — the `hexol apply` effects
             (hexol secrets)     ; secrets-store / secret-ref / resolve-secret-refs — inline sops
             (ice-9 textual-ports) ; get-string-all — read the SSH key / helm values file
             (srfi srfi-1)
             (srfi srfi-13))

;; ---------------------------------------------------------------------------
;; deployment knobs (content)
;; ---------------------------------------------------------------------------

;; Every knob in one place: the defaults, with a single `deep-merge` layering
;; on any environment overrides (only keys whose var is actually set win).
;; `(cfg 'key)` reads one; the two derived values are functions of it.
(define config
  (deep-merge
   '((cluster-name  . "homelab")
     (domain        . "homelab.example")
     (node-count    . 3)
     (talos-version . "v1.7.5")          ; docs.siderolabs.com/talos/v1.7
     (os-region     . "GRA11")           ; an OVH public-cloud region
     (node-flavor   . "b2-7")            ; 2 vCPU / 7 GiB
     (ext-net       . "Ext-Net")         ; OVH's external (floating-IP) network
     (net-cidr      . "10.0.10.0/24")
     (dns-zone      . #f)                 ; OVH DNS zone owning `domain`; #f → `domain` itself
     (ovh-endpoint  . "ovh-eu")           ; OVH API region for the `ovh` provider
     (ingress-http-hostport  . 30080)     ; PUBLIC Gateway host ports (host-network); the
     (ingress-https-hostport . 30443)     ;   ingress LB forwards 80/443 here
     (private-http-hostport  . 80)        ; PRIVATE Gateway host ports — VPN-only: not
     (private-https-hostport . 443)       ;   LB-fronted and not opened in the secgroup, so
                                          ;   reachable only over the VPN (node-to-node self-rule)
     (wg-port                . 51820))    ; WireGuard UDP — the only publicly exposed VPN port
   (filter-map (lambda (binding)
                 (and=> (getenv (car binding))
                        (lambda (v) (cons (cdr binding) v))))
               '(("HOMELAB_DOMAIN"   . domain)       ("TALOS_VERSION"  . talos-version)
                 ("OS_REGION_NAME"   . os-region)    ("HOMELAB_FLAVOR" . node-flavor)
                 ("HOMELAB_DNS_ZONE" . dns-zone)     ("OVH_ENDPOINT"   . ovh-endpoint)))))

(define (cfg key) (assq-ref config key))

;; The kube-API endpoint: a DNS A record pointing at the API load balancer.
(define (api-endpoint) (fmt "https://api.~a:6443" (cfg 'domain)))

;; The control-plane nodes, as (index . private-ip) pairs: homelab-cp-1 …
;; on 10.0.10.11…  (these double as control plane + workers — a homelab runs
;; its apps on the same three machines).
(define (nodes)
  (map (lambda (i) (cons i (str "10.0.10." (+ 10 i)))) (iota (cfg 'node-count) 1)))

;; The OVH DNS zone that owns `domain`. Defaults to `domain` itself; override
;; (HOMELAB_DNS_ZONE) when `domain` is a subdomain of a larger zone you hold at
;; OVH — e.g. zone "example.com", domain "homelab.example.com".
(define (dns-zone) (or (cfg 'dns-zone) (cfg 'domain)))

;; OVH splits a record into (zone, subdomain); `subdomain-of` derives the
;; subdomain from a full host: "api.homelab.example" in zone "homelab.example"
;; → "api"; the bare zone → "" (the apex).
(define (subdomain-of fqdn)
  (let ((z (dns-zone)))
    (cond ((string=? fqdn z) "")
          ((string-suffix? (string-append "." z) fqdn)
           (substring fqdn 0 (- (string-length fqdn) (string-length z) 1)))
          (else (error "homelab: host not within DNS zone" fqdn z)))))

;; ---------------------------------------------------------------------------
;; Talos machine config (content) — built as Scheme data, rendered to YAML.
;; ---------------------------------------------------------------------------
;;
;; A strategic-merge patch layered onto the config the talos provider renders
;; from the cluster secrets. One per node so each gets its own hostname; the
;; rest is shared. `cni: none` + `proxy.disabled` hand networking to Cilium,
;; KubePrism gives every node a local API endpoint (localhost:7445) that
;; Cilium's kube-proxy replacement targets, and control planes are made
;; schedulable so the apps below have somewhere to run.

(define (yaml-string alist)
  "Serialize ALIST to a YAML document string (for a Terraform string field)."
  (call-with-output-string (lambda (p) (emit-yaml-document p alist))))

(define (talos-patch node)
  (let* ((i (car node)) (ip (cdr node))
         (host (str (cfg 'cluster-name) "-cp-" i))
         (node-fip (tf-ref "openstack_networking_floatingip_v2" (str "cp-" i) "address")))
    `((machine
        (type . "controlplane")
        (certSANs ,(str "api." (cfg 'domain)) ,ip ,node-fip "127.0.0.1" "localhost")
        (network (hostname . ,host))
        (install (disk . "/dev/vda") (wipe . #f))
        (features (kubePrism (enabled . #t) (port . 7445)))
        (kubelet (extraArgs (rotate-server-certificates . "true"))))
      (cluster
        (allowSchedulingOnControlPlanes . #t)
        (network (cni (name . "none")))      ; Cilium is the CNI
        (proxy (disabled . #t))))))          ; Cilium replaces kube-proxy

;; ---------------------------------------------------------------------------
;; Terraform helpers (content) — OVH OpenStack + the talos provider.
;; ---------------------------------------------------------------------------

;; The deployer's SSH public key, read from ~/.ssh at render time (the one
;; place the inventory touches the local machine — same trick as
;; examples/terraform.scm). Talos itself has no SSH, but OpenStack requires a
;; keypair on the instance.
(define (read-ssh-public-key)
  (let* ((home (or (getenv "HOME") "."))
         (path (find file-exists?
                     (map (lambda (f) (string-append home "/.ssh/" f))
                          '("id_ed25519.pub" "id_rsa.pub")))))
    (unless path
      (error "homelab: no SSH public key in ~/.ssh (id_ed25519.pub / id_rsa.pub)"))
    (call-with-input-file path
      (lambda (p) (string-trim-right (get-string-all p))))))

;; --- OpenStack security groups (generic, not Talos-specific) ---

;; One ingress rule: TCP ports FROM..TO reachable from CIDR (default anywhere).
;; Returns a procedure of the group's resource label, which
;; `openstack-security-group` supplies — so the call site states only the rule.
(define* (os-ingress suffix from to #:key (cidr "0.0.0.0/0") (protocol "tcp"))
  (lambda (group)
    (terraform-resource "openstack_networking_secgroup_rule_v2" (str group "-" suffix)
      (direction "ingress") (ethertype "IPv4") (protocol protocol)
      (port_range_min from) (port_range_max to)
      (remote_ip_prefix cidr)
      (security_group_id (tf-ref "openstack_networking_secgroup_v2" group "id")))))

;; An allow-all ingress rule from members of the group itself (e.g. etcd,
;; kubelet, Cilium between cluster nodes). Like `os-ingress`, returns a
;; procedure of the group label.
(define (os-ingress-self suffix)
  (lambda (group)
    (terraform-resource "openstack_networking_secgroup_rule_v2" (str group "-" suffix)
      (direction "ingress") (ethertype "IPv4")
      (remote_group_id   (tf-ref "openstack_networking_secgroup_v2" group "id"))
      (security_group_id (tf-ref "openstack_networking_secgroup_v2" group "id")))))

;; A security group plus its ingress rules, bundled. #:name is the Terraform
;; resource label other resources reference; #:os-name the OpenStack-visible
;; name (defaults to #:name). Each rule in #:rules is built by `os-ingress` /
;; `os-ingress-self` and wired to this group here.
(define* (openstack-security-group #:key name os-name (description "") (rules '()))
  (compose-ops 'openstack-security-group `(openstack-security-group ,name)
    (cons
      (terraform-resource "openstack_networking_secgroup_v2" name
        (name (or os-name name))
        (description description))
      (map (lambda (rule) (rule name)) rules))))

;; The cluster's security group: the Talos / Kubernetes API + ingress ports
;; from anywhere, plus an allow-all rule between cluster members.
(define (talos-security-group)
  (openstack-security-group
    #:name "talos" #:os-name (str (cfg 'cluster-name) "-talos")
    #:description "Talos + Kubernetes control plane"
    #:rules (list (os-ingress "kube-api" 6443 6443)         ; kube-apiserver
                  (os-ingress "talos"   50000 50001)        ; Talos apid + trustd
                  ;; the PUBLIC Cilium Gateway's host-network ports — the ingress
                  ;; LB forwards 80/443 here. The PRIVATE Gateway's ports
                  ;; (31080/31443) are deliberately NOT opened: they're reachable
                  ;; only between nodes (the rule below) and over the VPN.
                  (os-ingress "ingress-http"  (cfg 'ingress-http-hostport)  (cfg 'ingress-http-hostport))
                  (os-ingress "ingress-https" (cfg 'ingress-https-hostport) (cfg 'ingress-https-hostport))
                  ;; WireGuard — the single public VPN entrypoint (UDP).
                  (os-ingress "wireguard" (cfg 'wg-port) (cfg 'wg-port) #:protocol "udp")
                  (os-ingress-self "internal"))))           ; etcd, kubelet, Cilium between nodes

;; One control-plane node: the machine config Terraform renders for it (from
;; the shared secrets + our patch), the VM that boots that config as
;; user_data, and a floating IP so `talosctl`/`kubectl` can reach it.
(define (talos-node node)
  (let* ((i (car node)) (ip (cdr node))
         (host      (str (cfg 'cluster-name) "-cp-" i))
         (data-name (str "controlplane-" i)))
    (compose-ops 'talos-node `(talos-node ,i)
      (list
        ;; data "talos_machine_configuration" "<data-name>" — config = secrets + patch
        (terraform-data "talos_machine_configuration" data-name
          (cluster_name     (cfg 'cluster-name))
          (cluster_endpoint (api-endpoint))
          (machine_type     "controlplane")
          ;; Pin to the booted image's Talos version — otherwise the provider
          ;; generates config for its own (newer) schema, which adds keys like
          ;; `install.grubUseUKICmdline` that v1.7.5 rejects on config load.
          (talos_version    (cfg 'talos-version))
          (machine_secrets  (ref talos_machine_secrets this machine_secrets))
          (config_patches   (list (yaml-string (talos-patch node)))))
        ;; the VM, booting that machine config
        (terraform-resource "openstack_compute_instance_v2" host
          (name        host)
          (image_id    (ref openstack_images_image_v2 talos id))
          (flavor_name (cfg 'node-flavor))
          (key_pair    (ref openstack_compute_keypair_v2 deployer name))
          (user_data   (tf-ref "data.talos_machine_configuration" data-name "machine_configuration"))
          (security_groups (list (ref openstack_networking_secgroup_v2 talos name)))
          (block network
            (uuid        (ref openstack_networking_network_v2 talos id))
            (fixed_ip_v4 ip)))
        ;; a floating IP, associated to the node's Neutron port. (The compute
        ;; `*_floatingip_associate_v2` resource was dropped in openstack
        ;; provider v3; the networking one binds the FIP to a port id. The
        ;; instance does NOT expose its Nova-auto-created port as
        ;; `network.0.port` (empty in provider v3), so we look the port up by
        ;; device + network — otherwise the associate binds nothing and the FIP
        ;; stays DOWN.)
        (terraform-resource "openstack_networking_floatingip_v2" (str "cp-" i)
          (pool (cfg 'ext-net)))
        (terraform-data "openstack_networking_port_v2" (str "cp-" i)
          (device_id  (tf-ref "openstack_compute_instance_v2" host "id"))
          (network_id (ref openstack_networking_network_v2 talos id)))
        (terraform-resource "openstack_networking_floatingip_associate_v2" (str "cp-" i)
          (floating_ip (tf-ref "openstack_networking_floatingip_v2" (str "cp-" i) "address"))
          (port_id     (tf-ref "data.openstack_networking_port_v2" (str "cp-" i) "id")))))))


;; --- OpenStack load balancer (a generic Octavia LB builder) ---

;; One listener on the LB: a listener + pool on PORT, one member per backend in
;; #:backends (a list of (suffix . ip)) on #:member-port (default PORT), and a
;; TCP health monitor when #:monitor. Returns a procedure of (lb-label subnet)
;; that `openstack-lb` applies — so the call site states only the service.
(define* (lb-listener name #:key port (member-port port) (protocol "TCP")
                      (monitor #f) (backends '()))
  (lambda (lb subnet)
    (append
      (list
        (terraform-resource "openstack_lb_listener_v2" name
          (name name) (protocol protocol) (protocol_port port)
          (loadbalancer_id (tf-ref "openstack_lb_loadbalancer_v2" lb "id")))
        (terraform-resource "openstack_lb_pool_v2" name
          (name name) (protocol protocol) (lb_method "ROUND_ROBIN")
          (listener_id (tf-ref "openstack_lb_listener_v2" name "id"))))
      (if monitor
          (list (terraform-resource "openstack_lb_monitor_v2" name
                  (pool_id (tf-ref "openstack_lb_pool_v2" name "id"))
                  (type "TCP") (delay 10) (timeout 5) (max_retries 3)))
          '())
      (map (lambda (b)
             (terraform-resource "openstack_lb_member_v2" (str name "-" (car b))
               (pool_id       (tf-ref "openstack_lb_pool_v2" name "id"))
               (address       (cdr b))
               (protocol_port member-port)
               (subnet_id     (tf-ref "openstack_networking_subnet_v2" subnet "id"))))
           backends))))

;; A complete Octavia load balancer fronting a set of TCP services on one VIP.
;; Builds the loadbalancer, a floating IP bound to its VIP (from #:ext-net), and
;; the listener/pool/members for each entry in #:listeners (built with
;; `lb-listener`). #:name is the resource label of both the LB and the floating
;; IP — so `(ref openstack_networking_floatingip_v2 <name> address)` is the VIP.
;; #:subnet is the member subnet's resource label.
(define* (openstack-lb #:key name os-name subnet ext-net (listeners '()))
  (compose-ops 'openstack-lb `(openstack-lb ,name)
    (append
      (list
        (terraform-resource "openstack_lb_loadbalancer_v2" name
          (name (or os-name name))
          (vip_subnet_id (tf-ref "openstack_networking_subnet_v2" subnet "id")))
        (terraform-resource "openstack_networking_floatingip_v2" name
          (pool ext-net)
          (port_id (tf-ref "openstack_lb_loadbalancer_v2" name "vip_port_id"))))
      (append-map (lambda (mk) (mk name subnet)) listeners))))

;; The control-plane nodes as LB backends: (suffix . private-ip) pairs.
(define (node-backends)
  (map (lambda (n) (cons (str "cp-" (car n)) (cdr n))) (nodes)))

;; ---------------------------------------------------------------------------
;; OVH DNS (content) — records in an OVH-hosted zone, via the `ovh` provider.
;; ---------------------------------------------------------------------------

;; One OVH A-record named RNAME (the Terraform resource label), pointing the
;; full host HOST at TARGET (an IP or a `${…address}` interpolation). `zone`
;; and `subdomain` are OVH's split of the FQDN, derived from HOST so the call
;; site reads as the name it creates.
(define* (dns-a rname host #:key target (ttl 60))
  (terraform-resource "ovh_domain_zone_record" rname
    (zone      (dns-zone))
    (subdomain (subdomain-of host))
    (fieldtype "A")
    (ttl       ttl)
    (target    target)))

;; ---------------------------------------------------------------------------
;; Kubernetes helpers (content) — two layers of Helm + Gateway API + apps.
;; ---------------------------------------------------------------------------
;;
;; The cluster bootstraps in two layers, and the two layers use Helm two
;; different ways:
;;
;;   • Bootstrap (Cilium + Flux). These must exist before anything else can:
;;     Cilium is the CNI (Talos runs `cni: none`), and Flux is the controller
;;     that reconciles everything below. There is no controller yet to expand
;;     a release object, so they are expanded *here* by `helm-template` —
;;     shelling out to `helm template`, converting the YAML to JSON with `yq`,
;;     reading it back with guile-json, and appending each manifest as an
;;     ordinary `resource`. So `-o yaml` carries their full manifests, ready
;;     to `kubectl apply` before the cluster has any operators.
;;
;;   • Everything else is GitOps. Once Flux runs, the remaining charts are
;;     declared as Flux resources — a `HelmRepository` (chart source) plus a
;;     `HelmRelease` (chart ref + version + `values`) — and Flux reconciles
;;     them in-cluster. We only emit the small CRs; the chart's own objects
;;     are Flux's job.
;;
;; `helm-template` is a fold-time op (a `make-op`, like `expose`): `tree`/`ops`
;; never shell out, only a real resolve does — and if `helm`/`yq` are missing
;; it warns and skips, leaving the rest of the render intact.

;; `namespace`, `which-cmd`, `json-manifests`, and `remote-manifest` now live in
;; (hexol k8s); `helm-template` and `sops-manifest` below build on the shared
;; `which-cmd` / `json-manifests` plumbing.

;; Cluster-scoped kinds carry no namespace; everything else defaults to the
;; release namespace. (Not exhaustive — just the kinds these charts emit.)
(define cluster-scoped-kinds
  '("Namespace" "Node" "PersistentVolume" "ClusterRole" "ClusterRoleBinding"
    "CustomResourceDefinition" "ClusterIssuer" "StorageClass" "IngressClass"
    "GatewayClass" "PriorityClass" "RuntimeClass" "CSIDriver" "APIService"
    "ValidatingWebhookConfiguration" "MutatingWebhookConfiguration"))

;; Stamp metadata.namespace = NS onto R when it is a namespaced kind that
;; lacks one. `helm template --namespace NS` only sets `.Release.Namespace`;
;; charts that don't reference it in their templates (e.g. flux2) emit no
;; namespace, so `kubectl apply` would drop them in `default`. This mirrors
;; what `helm install -n NS` does, keeping the rendered stream self-contained.
(define (stamp-namespace ns r)
  (let ((kind (assq-ref r 'kind))
        (meta (or (assq-ref r 'metadata) '())))
    (if (or (member kind cluster-scoped-kinds) (assq 'namespace meta))
        r
        (map (lambda (kv)
               (if (eq? (car kv) 'metadata)
                   (cons 'metadata (cons (cons 'namespace ns) (cdr kv)))
                   kv))
             r))))

(define* (helm-template #:key name chart repo version namespace (values '()) (include-crds #t))
  "Return a fold-time op that renders CHART (from REPO, at VERSION) with `helm
template` and appends every manifest it emits to (kubernetes_resources)."
  (make-op 'helm-template `(helm-template ,name)
    (lambda (state)
      (let ((helm (which-cmd "helm")) (yq (which-cmd "yq")))
        (cond
          ((not (and helm yq))
           (format (current-error-port)
                   ";; homelab: helm/yq not on PATH — skipping chart ~a (install them to template it)~%"
                   name)
           state)
          (else
           (let ((values-file (string-append "/tmp/hexol-helm-" name ".values.yaml")))
             (call-with-output-file values-file
               (lambda (p) (emit-yaml-document p values)))
             (let* ((cmd (fmt (string-append "~a template ~a ~a --repo ~a --version ~a "
                                             "--namespace ~a~a --values ~a | ~a ea -o=json '[.]'")
                              helm name chart repo version namespace
                              (if include-crds " --include-crds" "") values-file yq))
                    (manifests (json-manifests cmd name)))
               (fold (lambda (r s) (apply-op (resource (stamp-namespace namespace r)) s))
                     state manifests)))))))
    (string-append "helm-template " name)))

;; The upstream Gateway API CRDs. Cilium's Gateway API support requires these to
;; pre-exist, and Cilium does not ship them; we use the *experimental* channel
;; because Cilium watches TLSRoute. Pinned to a release.
;; This could actually be hardcoded directly in the hx-ops. The function is very small
(define gateway-api-version "v1.1.0")
(define (gateway-api-crds)
  (remote-manifest "gateway-api-crds"
    (fmt (string-append "https://github.com/kubernetes-sigs/gateway-api"
                        "/releases/download/~a/experimental-install.yaml")
         gateway-api-version)))

;; cert-manager's CRDs, pulled from the chart's standalone CRD bundle and
;; applied as a pre-step — so the ClusterIssuer / Certificate CRs below
;; validate at apply time even though cert-manager *itself* is installed by
;; Flux (asynchronously). The Flux HelmRelease runs with crds disabled, so the
;; two never fight over CRD ownership. Same pattern as `gateway-api-crds`;
;; pinned to the chart version below.
(define cert-manager-version "v1.15.1")
(define (cert-manager-crds)
  (remote-manifest "cert-manager-crds"
    (fmt (string-append "https://github.com/cert-manager/cert-manager"
                        "/releases/download/~a/cert-manager.crds.yaml")
         cert-manager-version)))

;; Secrets are no longer spliced from per-secret `*.sops.yaml` files; they live
;; in one inline `(secrets-store …)` (below), referenced at each field with
;; `(secret-ref 'key)` and decrypted once at render time by the terminal
;; `(resolve-secret-refs)` op. See (hexol secrets).

;; --- GitOps layer: charts as Flux resources (reconciled in-cluster) ---

;; A Flux HelmRepository: where a chart comes from. Lives in flux-system.
(define* (helm-repository #:key name url (namespace "flux-system") (interval "1h"))
  (custom-resource name
    (api "source.toolkit.fluxcd.io/v1") (kind "HelmRepository")
    (namespace namespace)
    (spec `((interval . ,interval) (url . ,url)))))

;; A Flux HelmRelease: CHART from the REPO HelmRepository at VERSION, deployed
;; into TARGET-NAMESPACE with VALUES. The CR itself lives in flux-system (where
;; Flux watches); Flux expands the chart and creates the target namespace.
(define* (helm-release #:key name chart repo version target-namespace
                       (release-name name) (timeout #f)
                       (namespace "flux-system") (values '()) (interval "1h"))
  (custom-resource name
    (api "helm.toolkit.fluxcd.io/v2") (kind "HelmRelease")
    (namespace namespace)
    (spec `((interval . ,interval)
             ;; Pin the Helm release name. Flux otherwise defaults it to
             ;; `<targetNamespace>-<name>`, which doubles every chart resource
             ;; name (e.g. `monitoring-kube-prometheus-stack-grafana`) and
             ;; breaks Service references / RBAC that assume the chart default.
             (releaseName . ,release-name)
             ,@(if target-namespace
                   `((targetNamespace  . ,target-namespace)
                     (storageNamespace . ,target-namespace))
                   '())
             (chart (spec (chart . ,chart)
                          (version . ,version)
                          (sourceRef (kind . "HelmRepository") (name . ,repo) (namespace . ,namespace))))
             ,@(if timeout `((timeout . ,timeout)) '())
             (install (createNamespace . #t) (crds . "Create"))
             (upgrade (crds . "CreateReplace") (remediation (retries . 3)))
             (values ,@values)))))

;; Rancher local-path-provisioner as a self-contained bundle: namespace (PSS
;; `privileged` — its helper pods mount hostPath), RBAC, the config (data path
;; under Talos's writable /var), the provisioner Deployment, and a default
;; StorageClass. Translated from the upstream v0.0.30 deploy manifest.
(define (local-path-provisioner)
  (let ((ns "local-path-storage")
        (sa "local-path-provisioner-service-account"))
    (compose-ops 'local-path-provisioner '(local-path-provisioner)
      (list
        (namespace ns (labels (pod-security.kubernetes.io/enforce "privileged")))
        (service-account sa (namespace ns))
        ;; namespaced Role + RoleBinding: manage the helper pods in its own
        ;; namespace (library `role`/`role-binding` — the namespaced counterparts
        ;; of `cluster-role`/`cluster-role-binding`).
        (role "local-path-provisioner-role" (namespace ns)
          (rule (api-groups "") (resources "pods")
                (verbs "get" "list" "watch" "create" "patch" "update" "delete")))
        (role-binding "local-path-provisioner-bind" (namespace ns)
          (role "local-path-provisioner-role") (service-account sa) (sa-namespace ns))
        ;; cluster-scoped perms: PVs, nodes, storageclasses, events
        (cluster-role "local-path-provisioner-role"
          (rule (api-groups "")
                (resources "nodes" "persistentvolumeclaims" "configmaps" "pods" "pods/log")
                (verbs "get" "list" "watch"))
          (rule (api-groups "") (resources "persistentvolumes")
                (verbs "get" "list" "watch" "create" "patch" "update" "delete"))
          (rule (api-groups "") (resources "events") (verbs "create" "patch"))
          (rule (api-groups "storage.k8s.io") (resources "storageclasses")
                (verbs "get" "list" "watch")))
        (cluster-role-binding "local-path-provisioner-bind"
          (role "local-path-provisioner-role") (service-account sa) (sa-namespace ns))
        ;; config: data path under /var (Talos-writable), helper pod + scripts
        (configmap "local-path-config" (namespace ns)
          (data
            (config.json "{\n  \"nodePathMap\":[\n    { \"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\", \"paths\":[\"/var/mnt/local-path-provisioner\"] }\n  ]\n}")
            (setup "#!/bin/sh\nset -eu\nmkdir -m 0777 -p \"$VOL_DIR\"")
            (teardown "#!/bin/sh\nset -eu\nrm -rf \"$VOL_DIR\"")
            (helperPod.yaml "apiVersion: v1\nkind: Pod\nmetadata:\n  name: helper-pod\nspec:\n  priorityClassName: system-node-critical\n  tolerations:\n    - key: node.kubernetes.io/disk-pressure\n      operator: Exists\n      effect: NoSchedule\n  containers:\n  - name: helper-pod\n    image: busybox\n    imagePullPolicy: IfNotPresent")))
        ;; the provisioner itself (raw: needs a fieldRef env the generic
        ;; `deployment` constructor doesn't model)
        (resource
          `((apiVersion . "apps/v1") (kind . "Deployment")
            (metadata (namespace . ,ns) (name . "local-path-provisioner")
                      (labels (app . "local-path-provisioner")))
            (spec (replicas . 1)
                  (selector (matchLabels (app . "local-path-provisioner")))
                  (template
                    (metadata (labels (app . "local-path-provisioner")))
                    (spec (serviceAccountName . ,sa)
                          (containers
                            ((name . "local-path-provisioner")
                             (image . "rancher/local-path-provisioner:v0.0.30")
                             (command "local-path-provisioner" "--debug" "start"
                                      "--config" "/etc/config/config.json")
                             (volumeMounts ((name . "config-volume") (mountPath . "/etc/config/")))
                             (env ((name . "POD_NAMESPACE")
                                   (valueFrom (fieldRef (fieldPath . "metadata.namespace"))))
                                  ((name . "CONFIG_MOUNT_PATH") (value . "/etc/config/")))))
                          (volumes ((name . "config-volume")
                                    (configMap (name . "local-path-config")))))))))
        ;; the default StorageClass (annotated so unclassed PVCs use it)
        (resource
          `((apiVersion . "storage.k8s.io/v1") (kind . "StorageClass")
            (metadata (name . "local-path")
                      (annotations (storageclass.kubernetes.io/is-default-class . "true")))
            (provisioner . "rancher.io/local-path")
            (volumeBindingMode . "WaitForFirstConsumer")
            (reclaimPolicy . "Delete")))))))

;; A Gateway API Gateway (handled by Cilium's GatewayClass) terminating TLS
;; for *.<domain> with the wildcard cert cert-manager issues below.
;; In host-network mode the listener `port` is the host port Envoy binds on
;; every node (must be unique per Gateway and >1023 — we use 30080/30443, so no
;; privileged-port capability is needed). The Octavia ingress LB forwards
;; 80→http-port and 443→https-port.
(define* (gateway #:key name (class "cilium") (namespace (current-k8s-namespace))
                  (http-port 80) (https-port 443))
  (custom-resource name
    (api "gateway.networking.k8s.io/v1") (kind "Gateway")
    (namespace namespace)
    (spec `((gatewayClassName . ,class)
             (listeners
               ((name . "http") (protocol . "HTTP") (port . ,http-port)
                (allowedRoutes (namespaces (from . "All"))))
               ((name . "https") (protocol . "HTTPS") (port . ,https-port)
                (hostname . ,(str "*." (cfg 'domain)))
                (allowedRoutes (namespaces (from . "All")))
                (tls (mode . "Terminate")
                     (certificateRefs ((kind . "Secret") (name . "wildcard-tls"))))))))))

;; An HTTPRoute attaching one Service to that Gateway under host.<domain>.
(define* (httproute #:key name (namespace (current-k8s-namespace)) host service port
                    (gateway-name "homelab") (gateway-namespace "gateway"))
  (custom-resource name
    (api "gateway.networking.k8s.io/v1") (kind "HTTPRoute")
    (namespace namespace)
    (spec `((parentRefs ((name . ,gateway-name) (namespace . ,gateway-namespace)))
             (hostnames ,(str host "." (cfg 'domain)))
             (rules ((backendRefs ((name . ,service) (port . ,port)))))))))

(define* (pvc #:key name size (namespace (current-k8s-namespace)) (mode "ReadWriteOnce"))
  (resource `((apiVersion . "v1") (kind . "PersistentVolumeClaim")
              (metadata (namespace . ,namespace) (name . ,name) (labels (app . ,name)))
              (spec (accessModes ,mode)
                    (resources (requests (storage . ,size)))))))

;; A stateful self-hosted app: a PVC, a single-replica Deployment that mounts
;; it, and a Service. The Deployment is built as a raw `resource` (like the
;; local-path-provisioner / wireguard workloads above) rather than via the
;; library `deployment`: its `env` is a runtime list, and the record-body
;; `(env …)` field expects literal entries, not a spliced variable — the
;; alist below mirrors exactly what `(deployment …)` would emit. The PVC and
;; the matching Service round out the bundle.
;;
;; `#:expose`, when non-empty, is a list of `httproute` keyword arguments
;; (e.g. `'(#:host "vault" #:gateway-name "homelab-private")`) — the route is
;; appended to the bundle with #:name / #:service / #:port / #:namespace
;; defaulting to this app's (override any by listing it in #:expose, which wins).
(define* (stateful-app #:key name image port (namespace (current-k8s-namespace))
                       (storage "5Gi") (mount "/data") (env '()) (resources "100m-*/256Mi")
                       (expose '()))
  (let ((vol (string-append "pvc-" name)))
    (compose-ops 'stateful-app `(stateful-app ,name)
      (append
        (list
          (pvc #:name name #:size storage #:namespace namespace)
          (resource
            `((apiVersion . "apps/v1") (kind . "Deployment")
              (metadata (namespace . ,namespace) (name . ,name) (labels (app . ,name)))
              (spec (replicas . 1)
                    (selector (matchLabels (app . ,name)))
                    (template
                      (metadata (labels (app . ,name)))
                      (spec
                        (containers
                          ((name . ,name) (image . ,image)
                           (ports ((containerPort . ,port)))
                           ,@(if (null? env) '() `((env ,@env)))
                           (volumeMounts ((name . ,vol) (mountPath . ,mount)))
                           (resources ,@(res resources))))
                        (volumes ((name . ,vol)
                                  (persistentVolumeClaim (claimName . ,name)))))))))
          (service name (port port) (namespace namespace)))
        (if (null? expose)
            '()
            (list (apply httproute #:name name #:service name #:port port
                         #:namespace namespace expose)))))))

;; ---------------------------------------------------------------------------
;; secrets store (content) — one inline, sops-encrypted document
;; ---------------------------------------------------------------------------
;;
;; Every secret the cluster needs, in ONE sops document embedded right here:
;; a single PGP-encrypted data key and MAC cover all of them (the same key
;; the old `secrets/*.sops.yaml` files used). Values are referenced at their
;; fields with `(secret-ref 'key)` and decrypted once at render time by the
;; terminal `(resolve-secret-refs)` op. `data` keys are emitted sorted before
;; `sops -d`, so the MAC verifies regardless of the order written here.
;;
;; The real, sops-sealed store lives in a sibling `homelab.secrets.scm` that is
;; gitignored and never committed. We `load` it when present; on a fresh clone
;; of the public repo it is absent, so we fall back to the dummy store below —
;; the example still renders end to end, with secrets emitted as
;; `<unresolved secret: …>` placeholders (the dummy ciphertext won't decrypt).
;; To change a secret: decrypt the local file, edit, re-seal to the PGP key,
;; and paste it back (a `hexol secret edit` helper will automate this).
(let* ((here  (current-filename))
       (dir   (if here (dirname here) "."))
       (local (string-append dir "/homelab.secrets.scm")))
  (if (file-exists? local)
      (primitive-load local)                ; real store wins (last registration)
      (secrets-store                        ; committed, self-contained dummy
        (version "3.12.2")
        (lastmodified "1970-01-01T00:00:00Z")
        (mac "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")
        (keys
          (pgp
            (fp "0000000000000000000000000000000000000000")
            (created-at "1970-01-01T00:00:00Z")
            (enc
              "-----BEGIN PGP MESSAGE-----"
              ""
              "DUMMY-PLACEHOLDER-NOT-A-REAL-KEY"
              "-----END PGP MESSAGE-----")))
        (data
          (ovh/applicationConsumerKey . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")
          (ovh/applicationKey         . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")
          (ovh/applicationSecret      . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")
          (wireguard/wg0.conf         . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")))))

;; ---------------------------------------------------------------------------
;; appliers (effects) — what `hexol apply` runs, in order, from the state
;; ---------------------------------------------------------------------------
;;
;; `render` turns this inventory into artifacts; `apply` pushes them to the
;; world. The `appliers` form names a sequence and runs it in order: each entry
;; reads the resolved state directly — no intermediate file to render and
;; manage — and shells out to its tool. The infra is built and its kubeconfig
;; dumped to `deploy/kubeconfig` first, so the cluster applies against it:
;;
;;   hexol apply examples/homelab.scm                       # whole bootstrap
;;   hexol apply --only check-api,kubernetes examples/homelab.scm  # re-apply cluster
;;   hexol apply --only terraform --dry-run …               # tofu plan only
;;
;; Between deploy steps sit checks (ordinary appliers whose effect is
;; observation, not mutation): `check-vms` asserts the control-plane VMs are
;; ACTIVE after terraform; `check-api` is a *gate* — the kubeconfig points at the
;; LB VIP via DNS, so it blocks until the kube-API actually answers there (DNS
;; propagation + Octavia health-check settling) before manifests apply.
;; `check-nodes` is a *smoke test*, non-fatal, after the apply. As standalone
;; entries both are `--only`-selectable; name `check-api` alongside `kubernetes`
;; to keep the gate when re-applying just the cluster. (A gate that must *never*
;; be skipped by `--only kubernetes` could instead ride along as the kubectl
;; applier's #:pre.)
;;
;; No hexol-level prompt: `tofu apply` gates itself; kubectl applies directly.
(define (kubectl* . args)
  (apply cmd "kubectl" "--kubeconfig=deploy/kubeconfig" args))

(appliers
  ("terraform"
   (terraform-applier #:workdir "deploy" #:binary "tofu"
                      #:output->file '(("kubeconfig" . "deploy/kubeconfig"))))

  ;; Infra smoke test: every control-plane VM reached ACTIVE. `tofu apply` blocks
  ;; on ACTIVE already, so this mostly guards re-applies and a partial/`-target`
  ;; build. Uses the `openstack` CLI with the same OS_*/openrc creds tofu used;
  ;; the one-liner is true iff the unique status of the `<cluster>-cp-*` servers
  ;; is exactly ACTIVE (empty — none found — fails too).
  ("check-vms"
   (check "OpenStack control-plane VMs ACTIVE"
          (cmd "sh" "-c"
               (str "test \"$(openstack server list --name " (cfg 'cluster-name)
                    "-cp -f value -c Status | sort -u)\" = ACTIVE"))
          #:needs "openstack"))

  ("check-api"
   (wait-for "kube-API reachable via the LB"
             (kubectl* "get" "--raw=/readyz")
             #:timeout 180 #:interval 5))

  ("kubernetes"
   (kubectl-applier #:kubeconfig "deploy/kubeconfig" #:server-side #t))

  ("check-nodes"
   (check "all nodes Ready (Cilium up)"
          (kubectl* "wait" "node" "--all"
                    "--for=condition=Ready" "--timeout=10s")
          #:fatal? #f)))

;; ---------------------------------------------------------------------------
;; actions (custom CLI verbs) — what this inventory adds to `hexol`
;; ---------------------------------------------------------------------------
;;
;; An applier is a *step* in the `hexol apply` pipeline; an action is its own
;; *verb*, run only when named — never as part of a bare `hexol apply`. So
;; teardown belongs here, not in the pipeline: it can't be reached by accident,
;; and needs no HEXOL_DESTROY guard. `terraform-destroyer` returns the
;; (state args -> effects) action; `defines-action` registers it as the verb
;; `hexol` discovers when no built-in matches (built-ins always win).
;;
;;   hexol destroy            -i examples/homelab.scm   # tofu destroy (prompts)
;;   hexol destroy --dry-run  -i examples/homelab.scm   # tofu plan -destroy
;;
;; tofu's own "Enter a value: yes" prompt still gates the real destruction.
(actions
  ("destroy" "destroy [--dry-run]   tear the stack down (tofu destroy)"
   (terraform-destroyer #:workdir "deploy" #:binary "tofu")))

;; ---------------------------------------------------------------------------
;; the homelab
;; ---------------------------------------------------------------------------

(hx-ops

  ;; ====================================================================
  ;; INFRASTRUCTURE  — render with `-o terraform`
  ;; ====================================================================

  (terraform-settings
    (required_version ">= 1.5.0")
    (block required_providers
      (block openstack (source "terraform-provider-openstack/openstack") (version "~> 3.0"))
      (block talos     (source "siderolabs/talos")                       (version "~> 0.6"))
      (block ovh       (source "ovh/ovh")                                (version "~> 1.0"))))

  ;; OpenStack auth comes from OS_* / clouds.yaml; only the region is pinned.
  (terraform-provider "openstack"
    (auth_url    "https://auth.cloud.ovh.net/v3")
    (domain_name "Default")
    (region      (cfg 'os-region)))

  ;; The talos provider needs no static config — it talks to the nodes.
  (terraform-provider "talos")

  ;; OVH DNS. Only the API endpoint (region) is pinned here; the API
  ;; credentials come from the environment: OVH_APPLICATION_KEY,
  ;; OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY (create at api.ovh.com/createToken
  ;; with GET/POST/PUT/DELETE on /domain/zone/*).
  (terraform-provider "ovh"
    (endpoint (cfg 'ovh-endpoint)))

  ;; Cluster PKI + secrets, generated once and reused by every node config.
  (terraform-resource "talos_machine_secrets" "this"
    (talos_version (cfg 'talos-version)))

  ;; The Talos image, uploaded to Glance from the upstream OpenStack release
  ;; asset (a compressed raw disk the provider decompresses on upload).
  (terraform-resource "openstack_images_image_v2" "talos"
    (name (str "talos-" (cfg 'talos-version)))
    (image_source_url
      (fmt "https://github.com/siderolabs/talos/releases/download/~a/openstack-amd64.raw.xz"
           (cfg 'talos-version)))
    (container_format "bare")
    (disk_format      "raw")
    (decompress       #t)
    (visibility       "private"))

  (terraform-resource "openstack_compute_keypair_v2" "deployer"
    (name       (str (cfg 'cluster-name) "-deployer"))
    (public_key (read-ssh-public-key)))

  ;; A private network + subnet, and a router uplinking it to the internet.
  (terraform-resource "openstack_networking_network_v2" "talos"
    (name (str (cfg 'cluster-name) "-net")) (admin_state_up #t))
  (terraform-resource "openstack_networking_subnet_v2" "talos"
    (name (str (cfg 'cluster-name) "-subnet"))
    (network_id (ref openstack_networking_network_v2 talos id))
    (cidr (cfg 'net-cidr)) (ip_version 4)
    (dns_nameservers (list "1.1.1.1" "9.9.9.9")))
  (terraform-data "openstack_networking_network_v2" "ext"
    (name (cfg 'ext-net)))
  (terraform-resource "openstack_networking_router_v2" "talos"
    (name (str (cfg 'cluster-name) "-router"))
    (external_network_id (tf-ref "data.openstack_networking_network_v2" "ext" "id")))
  (terraform-resource "openstack_networking_router_interface_v2" "talos"
    (router_id (ref openstack_networking_router_v2 talos id))
    (subnet_id (ref openstack_networking_subnet_v2 talos id)))

  (talos-security-group)

  ;; The 3 control-plane nodes: config + VM + floating IP each.
  (map talos-node (nodes))

  ;; One Octavia load balancer fronting everything on a single VIP / floating
  ;; IP: the kube-apiserver (6443, health-monitored) and application ingress
  ;; (80/443). The Cilium Gateway runs in host-network mode (Cilium 1.16+) —
  ;; there is no cloud LoadBalancer Service on bare OpenStack — so its Envoy
  ;; binds the `config` host ports (30080/30443) on every node and the LB
  ;; forwards 80→30080, 443→30443 straight to them. TCP/passthrough: the Gateway
  ;; terminates the wildcard TLS itself (see the `gateway`/cert-manager section).
  ;; DNS `api.<domain>` and `*.<domain>` both point at this LB's floating IP.
  ;; (#:name is required — it's the resource label both the LB and its floating
  ;; IP take, which the DNS records and the `api_endpoint` output reference.)
  (openstack-lb #:name "api" #:os-name (str (cfg 'cluster-name) "-api")
    #:subnet "talos" #:ext-net (cfg 'ext-net)
    #:listeners
    (list (lb-listener "kube-api" #:port 6443 #:monitor #t #:backends (node-backends))
          (lb-listener "ingress-http"  #:port 80 #:member-port (cfg 'ingress-http-hostport)  #:backends (node-backends))
          (lb-listener "ingress-https" #:port 443 #:member-port (cfg 'ingress-https-hostport) #:backends (node-backends))
          (lb-listener "wireguard" #:port (cfg 'wg-port) #:protocol "UDP" #:backends (node-backends))))

  ;; DNS. PUBLIC names resolve to the LB's floating IP: `api.<domain>` (kube-API
  ;; 6443), `vpn.<domain>` (the WireGuard UDP endpoint), and `jellyfin.<domain>`
  ;; (the one app on the public Gateway). The `*.<domain>` wildcard instead
  ;; resolves to the private node IPs — routable only over the VPN — so every
  ;; other app is private by default (reached on the private Gateway via the
  ;; node network). Explicit records beat the wildcard, so the public names win.
  ;; TODO: Move this to a map too
  (dns-a "api"      (str "api." (cfg 'domain))
         #:target (ref openstack_networking_floatingip_v2 api address))
  (dns-a "vpn"      (str "vpn." (cfg 'domain))
         #:target (ref openstack_networking_floatingip_v2 api address))
  (dns-a "jellyfin" (str "jellyfin." (cfg 'domain))
         #:target (ref openstack_networking_floatingip_v2 api address))
  (map (lambda (n)
         (dns-a (str "wildcard-cp-" (car n)) (str "*." (cfg 'domain)) #:target (cdr n)))
       (nodes))

  ;; The one-time bootstrap: initialise etcd on the first node, once its VM
  ;; (and floating IP) exist.
  (terraform-resource "talos_machine_bootstrap" "this"
    (node                 (tf-ref "openstack_networking_floatingip_v2" "cp-1" "address"))
    (endpoint             (tf-ref "openstack_networking_floatingip_v2" "cp-1" "address"))
    (client_configuration (ref talos_machine_secrets this client_configuration))
    (depends_on (list "openstack_networking_floatingip_associate_v2.cp-1")))

  ;; Pull the kubeconfig + talosconfig back out as Terraform outputs.
  ;; talos_cluster_kubeconfig is the *resource* (the data source of the same
  ;; name is deprecated and slated for removal); it fetches the kubeconfig once
  ;; the bootstrap has run and stores it in state.
  (terraform-resource "talos_cluster_kubeconfig" "this"
    (client_configuration (ref talos_machine_secrets this client_configuration))
    (node       (tf-ref "openstack_networking_floatingip_v2" "cp-1" "address"))
    (depends_on (list "talos_machine_bootstrap.this")))
  (terraform-data "talos_client_configuration" "this"
    (cluster_name         (cfg 'cluster-name))
    (client_configuration (ref talos_machine_secrets this client_configuration))
    (endpoints (list (tf-ref "openstack_networking_floatingip_v2" "cp-1" "address"))))

  (terraform-output "api_endpoint"
    (value (ref openstack_networking_floatingip_v2 api address)))
  (terraform-output "kubeconfig"
    (value (ref talos_cluster_kubeconfig this kubeconfig_raw))
    (sensitive #t))
  (terraform-output "talosconfig"
    (value (tf-ref "data.talos_client_configuration" "this" "talos_config"))
    (sensitive #t))

  ;; ====================================================================
  ;; CLUSTER  — render with `-o yaml`
  ;; ====================================================================

  ;; flux-system must exist before the flux2 bootstrap chart below (which the
  ;; chart does not create itself), and that chart is applied before the
  ;; HelmRepository CRs that need Flux's CRDs — so it is declared up front. The
  ;; other namespaces (gateway / apps / cert-manager / monitoring) are created by
  ;; their `with-namespace` blocks, which prepend the Namespace.
  (namespace "flux-system")

  ;; ---- bootstrap layer: expanded inline (no controller exists yet) ----

  ;; Gateway API CRDs — must exist before Cilium's operator starts its Gateway
  ;; controller (and before the Gateway/HTTPRoutes below).
  (gateway-api-crds)

  ;; --- Cilium: CNI + kube-proxy replacement + Gateway API ---
  ;; (cni:none in Talos means this is the cluster network; apply it first.)
  (helm-template #:name "cilium" #:namespace "kube-system"
    #:chart "cilium" #:repo "https://helm.cilium.io" #:version "1.16.19"
    #:values `((kubeProxyReplacement . #t)
               ;; Talos KubePrism: a node-local apiserver endpoint.
               (k8sServiceHost . "localhost") (k8sServicePort . 7445)
               (ipam (mode . "kubernetes"))
               ;; Gateway API in host-network mode: there is no cloud LB on bare
               ;; OpenStack, so instead of a (forever-pending) LoadBalancer
               ;; Service, the Gateway's Envoy binds its listener ports directly
               ;; on every node — the Octavia ingress LB forwards to those host
               ;; ports (see the ingress LB + gateway sections).
               (gatewayAPI (enabled . #t) (hostNetwork (enabled . #t)))
               ;; The private Gateway binds privileged ports (80/443) directly on
               ;; the host. cilium-envoy-starter drops every capability after fork
               ;; except NET_BIND_SERVICE, and only when keepCapNetBindService is
               ;; set *and* the cap is granted to the container — so grant both
               ;; (the `envoy` list replaces the chart default, hence NET_ADMIN +
               ;; SYS_ADMIN are repeated here).
               (envoy (enabled . #t)
                      (securityContext
                        (capabilities
                          (envoy "NET_ADMIN" "SYS_ADMIN" "NET_BIND_SERVICE")
                          (keepCapNetBindService . #t))))
               (hubble (relay (enabled . #t)) (ui (enabled . #t)))
               (securityContext
                 (capabilities
                   ;; flat list of capability strings (the chart's values schema
                   ;; wants a sequence here, not a nested list)
                   (ciliumAgent "CHOWN" "KILL" "NET_ADMIN" "NET_RAW"
                                "IPC_LOCK" "SYS_ADMIN" "SYS_RESOURCE"
                                "DAC_OVERRIDE" "FOWNER" "SETGID" "SETUID")
                   (cleanCiliumState "NET_ADMIN" "SYS_ADMIN" "SYS_RESOURCE")))
               ;; Talos mount points for the CNI install + cgroup.
               (cgroup (autoMount (enabled . #f)) (hostRoot . "/sys/fs/cgroup"))))

  ;; The GatewayClass our Gateway binds to. Cilium does NOT create it itself —
  ;; it only acts as the controller for one with this controllerName — so the
  ;; cluster must declare it, or every Gateway stays "Waiting for controller".
  ;; (The Gateway API CRDs it depends on are spliced in by `gateway-api-crds`.)
  (resource `((apiVersion . "gateway.networking.k8s.io/v1") (kind . "GatewayClass")
              (metadata (name . "cilium"))
              (spec (controllerName . "io.cilium/gateway-controller"))))

  ;; --- kubelet-csr-approver: auto-approve kubelet serving-cert CSRs ---
  ;; Talos sets `rotate-server-certificates: true`, so each kubelet requests a
  ;; serving cert via CSR — but nothing approves them by default, so
  ;; `kubectl logs/exec` and metrics scraping fail with "tls: internal error".
  ;; This approves CSRs whose SANs match our nodes (hostname pattern + the
  ;; private subnet); node names aren't in DNS, so resolution is bypassed.
  (helm-template #:name "kubelet-csr-approver" #:namespace "kube-system"
    #:chart "kubelet-csr-approver"
    #:repo "https://postfinance.github.io/kubelet-csr-approver" #:version "1.2.14"
    #:values `((providerRegex . ,(str "^" (cfg 'cluster-name) "-cp-[0-9]+$"))
               (bypassDnsResolution . #t)
               (providerIpPrefixes ,(cfg 'net-cidr))))

  ;; --- local-path-provisioner: the cluster's default StorageClass ---
  ;; Talos ships no CSI / StorageClass, so the apps' PVCs would hang Pending.
  ;; Rancher's local-path-provisioner hands out node-local hostPath volumes —
  ;; right for a homelab. Talos specifics: the data path must live under the
  ;; writable /var (not the default /opt, which is read-only on Talos), and the
  ;; namespace is labelled `privileged` because the helper pods mount hostPath
  ;; (which Talos's default `baseline` PodSecurity forbids).
  (local-path-provisioner)

  ;; --- WireGuard: the VPN that gates the private services ---
  ;; A host-networked WireGuard server (UDP 51820, exposed only via the LB's UDP
  ;; listener). A DaemonSet, so it runs on *every* node — the LB's `wireguard`
  ;; listener fans UDP out to all node-backends with no health monitor, so every
  ;; backend must actually listen or a source-IP-pinned client black-holes. Its
  ;; wg0.conf — server key + peers — comes from the inline secrets-store. PostUp
  ;; masquerades VPN-client traffic out eth0, so connected clients route the
  ;; cluster subnets (pushed via the client's AllowedIPs) and reach the PRIVATE
  ;; Gateway on the node IPs. Runs privileged in its own PSS-privileged namespace
  ;; (it manages the kernel WireGuard interface).
  (namespace "vpn" (labels (pod-security.kubernetes.io/enforce "privileged")))
  ;; wg0.conf (server key + peers) comes from the inline secrets-store,
  ;; resolved into this Secret's stringData at render time.
  ;; TODO: This should use the standard library of k8s.scm. Patch it if needed
  (resource
    `((apiVersion . "v1") (kind . "Secret")
      (metadata (namespace . "vpn") (name . "wireguard-config"))
      (type . "Opaque")
      (stringData (wg0.conf . ,(secret-ref 'wireguard/wg0.conf)))))
  ;; TODO: This should use the standard library of k8s.scm. Patch it if needed
  (resource
    `((apiVersion . "apps/v1") (kind . "DaemonSet")
      (metadata (namespace . "vpn") (name . "wireguard") (labels (app . "wireguard")))
      (spec (selector (matchLabels (app . "wireguard")))
            (template
              (metadata (labels (app . "wireguard")))
              (spec
                (hostNetwork . #t)
                (containers
                  ((name . "wireguard")
                   (image . "lscr.io/linuxserver/wireguard:1.0.20210914-r4-ls75")
                   (securityContext (privileged . #t)
                                    (capabilities (add "NET_ADMIN" "SYS_MODULE")))
                   (ports ((containerPort . ,(cfg 'wg-port)) (hostPort . ,(cfg 'wg-port))
                           (protocol . "UDP")))
                   (volumeMounts ((name . "config") (mountPath . "/config/wg_confs"))
                                 ((name . "modules") (mountPath . "/lib/modules") (readOnly . #t)))))
                (volumes
                  ((name . "config")
                   (secret (secretName . "wireguard-config")
                           (items ((key . "wg0.conf") (path . "wg0.conf")))))
                  ((name . "modules") (hostPath (path . "/lib/modules")))))))))

  ;; --- Flux: the GitOps controller that reconciles everything below ---
  ;; TODO: Move with-namespace here
  (helm-template #:name "flux2" #:namespace "flux-system"
    #:chart "flux2" #:repo "https://fluxcd-community.github.io/helm-charts"
    #:version "2.14.0")

  ;; ---- GitOps layer: Flux resources, reconciled in-cluster by Flux ----

  ;; chart sources (helm-repository defaults to the flux-system namespace,
  ;; declared up front for the bootstrap above — no with-namespace needed).
  (helm-repository #:name "jetstack" #:url "https://charts.jetstack.io")
  (helm-repository #:name "prometheus-community" #:url "https://prometheus-community.github.io/helm-charts")
  (helm-repository #:name "cert-manager-webhook-ovh" #:url "https://aureq.github.io/cert-manager-webhook-ovh/")

  ;; --- cert-manager (Flux): ACME wildcard cert for *.<domain> ---
  ;; The cert is a *wildcard* (`*.<domain>`), which Let's Encrypt only issues
  ;; over DNS-01 — http-01 can't prove ownership of a wildcard. So we solve
  ;; DNS-01 against the OVH zone via the cert-manager-webhook-ovh solver. Its
  ;; OVH API credentials live in the `ovh-credentials` Secret, decrypted from
  ;; sops at render time (inside the with-namespace block, so it lands after the
  ;; namespace it belongs to) and spliced inline — encrypted at rest in the repo,
  ;; yet `-o yaml` stays a complete, self-contained stream that carries no
  ;; plaintext secret on disk. `groupName` must match the webhook chart + solver.
  ;;
  ;; CRDs are pre-applied by `(cert-manager-crds)` below, so this release runs
  ;; with `crds.enabled #f` — Flux owns the controller, the pre-step owns the
  ;; CRDs, and the ClusterIssuer/Certificate CRs validate without waiting for
  ;; Flux to reconcile the chart.
  (cert-manager-crds)
  (helm-release #:name "cert-manager" #:repo "jetstack"
    #:chart "cert-manager" #:version cert-manager-version #:target-namespace "cert-manager"
    #:values '((crds (enabled . #f))))
  (helm-release #:name "cert-manager-webhook-ovh" #:repo "cert-manager-webhook-ovh"
    #:chart "cert-manager-webhook-ovh" #:version "0.9.10" #:target-namespace "cert-manager"
    #:values `((groupName . ,(str "acme." (cfg 'domain)))))
  (with-namespace "cert-manager"
    ;; the ovh-credentials Secret — values resolved from the inline secrets-store
    (resource
      `((apiVersion . "v1") (kind . "Secret")
        (metadata (namespace . "cert-manager") (name . "ovh-credentials"))
        (type . "Opaque")
        (stringData
          (applicationConsumerKey . ,(secret-ref 'ovh/applicationConsumerKey))
          (applicationSecret      . ,(secret-ref 'ovh/applicationSecret))
          (applicationKey         . ,(secret-ref 'ovh/applicationKey)))))
    ;; The webhook reads the OVH creds Secret, but the chart only wires that RBAC
    ;; for issuers IT creates from values — our ClusterIssuer + Secret are managed
    ;; here, so grant the webhook's ServiceAccount read access to the one Secret.
    (role "ovh-credentials-reader"
      (rule (api-groups "") (resources "secrets") (verbs "get" "watch")
            (resource-names "ovh-credentials")))
    (role-binding "ovh-credentials-reader" (role "ovh-credentials-reader")
                  (service-account "cert-manager-webhook-ovh"))
    (custom-resource "letsencrypt"
      (api "cert-manager.io/v1") (kind "ClusterIssuer")
      (spec `((acme (server . "https://acme-v02.api.letsencrypt.org/directory")
                     (email . ,(str "admin@" (cfg 'domain)))
                     (privateKeySecretRef (name . "letsencrypt-account"))
                     ;; solve ACME dns-01 via the OVH webhook (wildcard-capable)
                     (solvers ((dns01 (webhook
                                        (groupName  . ,(str "acme." (cfg 'domain)))
                                        (solverName . "ovh")
                                        (config
                                          (authenticationMethod . "application")
                                          (ovhEndpointName . ,(cfg 'ovh-endpoint))
                                          (applicationKeyRef         (name . "ovh-credentials") (key . "applicationKey"))
                                          (applicationSecretRef      (name . "ovh-credentials") (key . "applicationSecret"))
                                          (applicationConsumerKeyRef (name . "ovh-credentials") (key . "applicationConsumerKey"))))))))))))
  (with-namespace "gateway"
    (custom-resource "wildcard"
      (api "cert-manager.io/v1") (kind "Certificate")
      (spec `((secretName . "wildcard-tls")
               (issuerRef (name . "letsencrypt") (kind . "ClusterIssuer"))
               (dnsNames ,(str "*." (cfg 'domain)) ,(cfg 'domain)))))
    ;; Two edge Gateways sharing the wildcard cert. The PUBLIC one binds the
    ;; host ports the Octavia LB forwards 80/443 to (internet-reachable); the
    ;; PRIVATE one binds ports the LB does not expose and the secgroup leaves
    ;; closed — reachable only over the WireGuard VPN. A route's choice of
    ;; parent Gateway is what makes a service public or private.
    (gateway #:name "homelab-public"
             #:http-port  (cfg 'ingress-http-hostport)
             #:https-port (cfg 'ingress-https-hostport))
    (gateway #:name "homelab-private"
             #:http-port  (cfg 'private-http-hostport)
             #:https-port (cfg 'private-https-hostport)))

  ;; --- kube-prometheus-stack (Flux): metrics + Grafana (via the Gateway) ---
  (helm-release #:name "kube-prometheus-stack" #:repo "prometheus-community"
    #:chart "kube-prometheus-stack" #:version "61.3.0" #:target-namespace "monitoring"
    #:timeout "15m"   ; big chart (operator + CRDs + Grafana) — exceeds Flux's 5m default
    #:values `((grafana (enabled . #t)
                        (adminPassword . "changeme"))
               (prometheus (prometheusSpec (retention . "30d")))))
  (with-namespace "monitoring"
    (httproute #:name "grafana" #:host "grafana" #:gateway-name "homelab-private"
               #:service "kube-prometheus-stack-grafana" #:port 80))

  ;; --- a few standard self-hosted apps (in namespace "apps") ---
  ;; Each app's `#:expose` appends its HTTPRoute to the bundle (host + which
  ;; Gateway it attaches to — private by default, public for the one exception).
  (with-namespace "apps"
    (stateful-app #:name "vaultwarden" #:image "vaultwarden/server:1.30.5" #:port 80
                  #:storage "2Gi" #:mount "/data"
                  #:env `(((name . "DOMAIN") (value . ,(str "https://vault." (cfg 'domain)))))
                  #:expose '(#:host "vault" #:gateway-name "homelab-private"))

    ;; jellyfin is the one PUBLIC app — attaches to the public Gateway (LB-fronted).
    (stateful-app #:name "jellyfin" #:image "jellyfin/jellyfin:10.9.6" #:port 8096
                  #:storage "20Gi" #:mount "/config" #:resources "500m-*/1Gi"
                  #:expose '(#:host "jellyfin" #:gateway-name "homelab-public"))

    (stateful-app #:name "gitea" #:image "gitea/gitea:1.22.1" #:port 3000
                  #:storage "10Gi" #:mount "/data"
                  #:expose '(#:host "git" #:gateway-name "homelab-private")))

  ;; One pass stamps every cluster resource with a common label.
  (label-all `((app.kubernetes.io/part-of . ,(cfg 'cluster-name))))

  ;; Decrypt the inline secrets-store and substitute every (secret-ref …) with
  ;; its plaintext.  Placed last so it sees every resource; runs only during
  ;; render, never for `tree`/`ops`.
  (resolve-secret-refs)
  (checksum-config))
