;;; examples/homelab.scm — a whole homelab from one inventory.
;;;
;;; A self-hosted Kubernetes homelab end to end: infra (3-node Talos cluster on
;;; OVH public cloud) + cluster (platform Helm charts + self-hosted apps). Both
;;; live in one `(hx-ops …)` and split at *render* time by accumulator:
;;;
;;;   ./bin/hexol render -o terraform examples/homelab.scm > infra.tf.json  # infra
;;;   ./bin/hexol render -o yaml examples/homelab.scm | kubectl apply -f -  # cluster
;;;   ./bin/hexol tree / explain …                                          # introspection
;;;
;;; Bootstrap is the `siderolabs/talos` provider: `talos_machine_secrets` makes
;;; the PKI once, `data.talos_machine_configuration` renders per-node config from
;;; those secrets + our patches, each node boots it as `user_data`, and
;;; `talos_machine_bootstrap` inits etcd on node 1. Talos runs `cni: none` +
;;; `proxy.disabled`, so Cilium (below) is the CNI + kube-proxy replacement.
;;;
;;; Helm charts are expanded at render time via `helm template` and spliced into
;;; (kubernetes_resources) — not delegated to a Flux/Argo controller. So `-o yaml`
;;; is self-contained and every chart object is first-class/explainable. Needs
;;; helm + yq on PATH; `-o terraform` without them warns and skips charts.

(use-modules (hexol k8s)         ; Kubernetes vocab + external-manifest plumbing
             (hexol terraform)   ; Terraform language vocab
             (hexol yaml)        ; emit-yaml-document — Talos user_data + helm values
             (hexol apply)       ; appliers + checks for `hexol apply`
             (hexol secrets)     ; inline sops: secrets-store / secret-ref / resolve-secret-refs
             (ice-9 textual-ports) ; get-string-all — read SSH key / helm values file
             (srfi srfi-1)
             (srfi srfi-13))

;; ---------------------------------------------------------------------------
;; deployment knobs (content)
;; ---------------------------------------------------------------------------

;; Defaults, with `deep-merge` layering on env overrides. `(cfg 'key)` reads one.
(define config
  (deep-merge
   '((cluster-name  . "homelab")
     (domain        . "homelab.example")
     (node-count    . 3)
     (talos-version . "v1.13.4")         ; docs.siderolabs.com/talos/v1.13
     (talos-schematic . "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba") ; Image Factory; vanilla
     (os-region     . "GRA11")           ; an OVH public-cloud region
     (node-flavor   . "b2-7")            ; 2 vCPU / 7 GiB
     (ext-net       . "Ext-Net")         ; OVH's external (floating-IP) network
     (net-cidr      . "10.0.10.0/24")
     (dns-zone      . #f)                 ; OVH DNS zone owning `domain`; #f → `domain` itself
     (ovh-endpoint  . "ovh-eu")           ; OVH API region for the `ovh` provider
     (ingress-http-hostport  . 30080)     ; PUBLIC Gateway host ports; LB forwards 80/443 here
     (ingress-https-hostport . 30443)
     (private-http-hostport  . 80)        ; PRIVATE Gateway host ports — not LB-fronted, not in
     (private-https-hostport . 443)       ;   the secgroup, so VPN-only (node-to-node self-rule)
     (wg-port                . 51820))    ; WireGuard UDP — the only public VPN port
   (filter-map (lambda (binding)
                 (and=> (getenv (car binding))
                        (lambda (v) (cons (cdr binding) v))))
               '(("HOMELAB_DOMAIN"   . domain)       ("TALOS_VERSION"  . talos-version)
                 ("OS_REGION_NAME"   . os-region)    ("HOMELAB_FLAVOR" . node-flavor)
                 ("HOMELAB_DNS_ZONE" . dns-zone)     ("OVH_ENDPOINT"   . ovh-endpoint)))))

(define (cfg key) (assq-ref config key))

;; The kube-API endpoint: a DNS A record at the API load balancer.
(define (api-endpoint) (fmt "https://api.~a:6443" (cfg 'domain)))

;; A node's private IP, as a Terraform interpolation into its Neutron port's
;; allocated address. NOT pinned (see `talos-node`): each node draws a dynamic
;; IP, so nothing competes with auto-allocated ports (LB VIP, amphora) for a
;; fixed address. certSANs, LB members, `*.<domain>` DNS reference this.
(define (node-ip i)
  (tf-ref "openstack_networking_port_v2" (str "cp-" i) "all_fixed_ips[0]"))

;; Control-plane nodes as (index . private-ip-ref) pairs. These double as
;; workers — a homelab runs its apps on the same machines.
(define (nodes)
  (map (lambda (i) (cons i (node-ip i))) (iota (cfg 'node-count) 1)))

;; The OVH DNS zone owning `domain`. Defaults to `domain`; override
;; (HOMELAB_DNS_ZONE) when `domain` is a subdomain of a larger OVH zone.
(define (dns-zone) (or (cfg 'dns-zone) (cfg 'domain)))

;; OVH splits a record into (zone, subdomain); derive the subdomain from a full
;; host: "api.homelab.example" in zone "homelab.example" → "api"; zone → "".
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
;; A strategic-merge patch layered onto the provider's config, one per node.
;; `cni: none` + `proxy.disabled` hand networking to Cilium, KubePrism gives a
;; node-local API endpoint (localhost:7445) Cilium's kube-proxy replacement
;; targets, and control planes are made schedulable to run the apps below.

(define (yaml-string alist)
  "Serialize ALIST to a YAML document string (for a Terraform string field)."
  (call-with-output-string (lambda (p) (emit-yaml-document p alist))))

(define (talos-patch node)
  (let* ((i (car node)) (ip (cdr node))
         (node-fip (tf-ref "openstack_networking_floatingip_v2" (str "cp-" i) "address")))
    `((machine
        (type . "controlplane")
        (certSANs ,(str "api." (cfg 'domain)) ,ip ,node-fip "127.0.0.1" "localhost")
        ;; No machine.network.hostname: Talos v1.12+ auto-emits HostnameConfig
        ;; {auto: stable}, and a v1alpha1 hostname alongside it fails validation.
        ;; `auto` is lowest-priority, so OpenStack's metadata hostname (the
        ;; instance name) wins — nodes come up as homelab-cp-N.
        (install (disk . "/dev/vda") (wipe . #f))
        (features (kubePrism (enabled . #t) (port . 7445)))
        (kubelet (extraArgs (rotate-server-certificates . "true"))
                 ;; cinder-csi bind-mounts volumes via /var/lib/kubelet; that
                 ;; bidirectional propagation needs the kubelet mount rshared,
                 ;; declared explicitly on Talos. Rolled by `hexol config-apply`.
                 (extraMounts ((destination . "/var/lib/kubelet")
                               (type . "bind") (source . "/var/lib/kubelet")
                               (options "bind" "rshared" "rw")))))
      (cluster
        (allowSchedulingOnControlPlanes . #t)
        (network (cni (name . "none")))      ; Cilium is the CNI
        (proxy (disabled . #t))))))          ; Cilium replaces kube-proxy

;; ---------------------------------------------------------------------------
;; Terraform helpers (content) — OVH OpenStack + the talos provider.
;; ---------------------------------------------------------------------------

;; The deployer's SSH public key, read from ~/.ssh at render time. Talos has no
;; SSH, but OpenStack requires a keypair on the instance.
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

;; One ingress rule: TCP ports FROM..TO from CIDR (default anywhere). Returns a
;; procedure of the group label, so the call site states only the rule.
(define* (os-ingress suffix from to #:key (cidr "0.0.0.0/0") (protocol "tcp"))
  (lambda (group)
    (terraform-resource "openstack_networking_secgroup_rule_v2" (str group "-" suffix)
      (direction "ingress") (ethertype "IPv4") (protocol protocol)
      (port_range_min from) (port_range_max to)
      (remote_ip_prefix cidr)
      (security_group_id (tf-ref "openstack_networking_secgroup_v2" group "id")))))

;; An allow-all ingress rule from the group's own members (etcd, kubelet,
;; Cilium between nodes). Returns a procedure of the label.
(define (os-ingress-self suffix)
  (lambda (group)
    (terraform-resource "openstack_networking_secgroup_rule_v2" (str group "-" suffix)
      (direction "ingress") (ethertype "IPv4")
      (remote_group_id   (tf-ref "openstack_networking_secgroup_v2" group "id"))
      (security_group_id (tf-ref "openstack_networking_secgroup_v2" group "id")))))

;; A security group plus its ingress rules. #:name is the Terraform label;
;; #:os-name the OpenStack-visible name (defaults to #:name).
(define* (openstack-security-group #:key name os-name (description "") (rules '()))
  (compose-ops 'openstack-security-group `(openstack-security-group ,name)
    (cons
      (terraform-resource "openstack_networking_secgroup_v2" name
        (name (or os-name name))
        (description description))
      (map (lambda (rule) (rule name)) rules))))

;; The cluster's security group: Talos/Kubernetes API + ingress ports from
;; anywhere, plus an allow-all rule between members.
(define (talos-security-group)
  (openstack-security-group
    #:name "talos" #:os-name (str (cfg 'cluster-name) "-talos")
    #:description "Talos + Kubernetes control plane"
    #:rules (list (os-ingress "kube-api" 6443 6443)         ; kube-apiserver
                  (os-ingress "talos"   50000 50001)        ; Talos apid + trustd
                  ;; PUBLIC Gateway host-network ports — LB forwards 80/443 here.
                  ;; PRIVATE Gateway ports stay closed: VPN/node-internal only.
                  (os-ingress "ingress-http"  (cfg 'ingress-http-hostport)  (cfg 'ingress-http-hostport))
                  (os-ingress "ingress-https" (cfg 'ingress-https-hostport) (cfg 'ingress-https-hostport))
                  ;; WireGuard — the single public VPN entrypoint (UDP).
                  (os-ingress "wireguard" (cfg 'wg-port) (cfg 'wg-port) #:protocol "udp")
                  (os-ingress-self "internal"))))           ; etcd, kubelet, Cilium between nodes

;; One control-plane node: explicit Neutron port (dynamic IP), rendered machine
;; config (secrets + patch), the VM that boots it, and a floating IP.
;;
;; The port is explicit (not Nova-auto) so its IP is referenceable (`node-ip`,
;; used in certSANs/LB members/DNS) and nothing is pinned — removing the cp-3
;; collision where an auto-allocated port could grab a node's pinned IP first.
;; Security groups live on the port; the FIP binds to it directly.
(define (talos-node node)
  (let* ((i (car node))
         (host      (str (cfg 'cluster-name) "-cp-" i))
         (data-name (str "controlplane-" i))
         (port      (str "cp-" i)))
    (compose-ops 'talos-node `(talos-node ,i)
      (list
        (terraform-resource "openstack_networking_port_v2" port
          (name           (str host "-port"))
          (network_id     (ref openstack_networking_network_v2 talos id))
          (admin_state_up #t)
          (security_group_ids (list (ref openstack_networking_secgroup_v2 talos id))))
        (terraform-data "talos_machine_configuration" data-name
          (cluster_name     (cfg 'cluster-name))
          (cluster_endpoint (api-endpoint))
          (machine_type     "controlplane")
          ;; Pin to the booted image's version, else the provider emits keys
          ;; for its own newer schema that the running apid may reject.
          (talos_version    (cfg 'talos-version))
          (machine_secrets  (ref talos_machine_secrets this machine_secrets))
          (config_patches   (list (yaml-string (talos-patch node)))))
        (terraform-resource "openstack_compute_instance_v2" host
          (name        host)
          (image_id    (ref openstack_images_image_v2 talos id))
          (flavor_name (cfg 'node-flavor))
          (key_pair    (ref openstack_compute_keypair_v2 deployer name))
          (user_data   (tf-ref "data.talos_machine_configuration" data-name "machine_configuration"))
          (block network
            (port (tf-ref "openstack_networking_port_v2" port "id")))
          ;; `user_data' seeds first boot only. A later patch edit is ForceNew
          ;; (would replace the VM), so ignore it and let `hexol config-apply'
          ;; roll config via the talos API: day 1 = terraform, day 2 = the action.
          (block lifecycle
            (ignore_changes (list "user_data"))))
        (terraform-resource "openstack_networking_floatingip_v2" port
          (pool (cfg 'ext-net)))
        (terraform-resource "openstack_networking_floatingip_associate_v2" port
          (floating_ip (tf-ref "openstack_networking_floatingip_v2" port "address"))
          (port_id     (tf-ref "openstack_networking_port_v2" port "id")))))))


;; --- OpenStack load balancer (a generic Octavia LB builder) ---

;; One listener on the LB: listener + pool on PORT, one member per #:backends
;; entry ((suffix . ip)) on #:member-port (default PORT), and a TCP health
;; monitor when #:monitor. Returns a procedure of (lb-label subnet).
;; #:persistence (e.g. "SOURCE_IP") pins a client to one backend per session —
;; required for WireGuard, where each node runs an independent wg instance so a
;; round-robined client black-holes on the nodes it didn't handshake with.
(define* (lb-listener name #:key port (member-port port) (protocol "TCP")
                      (monitor #f) (persistence #f) (backends '()))
  (lambda (lb subnet)
    (append
      (list
        (terraform-resource "openstack_lb_listener_v2" name
          (name name) (protocol protocol) (protocol_port port)
          (loadbalancer_id (tf-ref "openstack_lb_loadbalancer_v2" lb "id")))
        ;; pool — optional SOURCE_IP stickiness
        (if persistence
            (terraform-resource "openstack_lb_pool_v2" name
              (name name) (protocol protocol) (lb_method "ROUND_ROBIN")
              (listener_id (tf-ref "openstack_lb_listener_v2" name "id"))
              (block persistence (type persistence)))
            (terraform-resource "openstack_lb_pool_v2" name
              (name name) (protocol protocol) (lb_method "ROUND_ROBIN")
              (listener_id (tf-ref "openstack_lb_listener_v2" name "id")))))
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

;; A complete Octavia LB fronting TCP services on one VIP: loadbalancer, a
;; floating IP bound to its VIP (from #:ext-net), and listeners. #:name labels
;; both the LB and the floating IP (the VIP); #:subnet is the member subnet.
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

;; One OVH A-record labelled RNAME, pointing HOST at TARGET (an IP or
;; interpolation). `zone`/`subdomain` are OVH's split of the FQDN.
(define-construct dns-a
  #:head (rname host)
  #:fields ((target #:required) (ttl #:default 60))
  #:build
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
;; The cluster bootstraps in two layers:
;;
;;   • Bootstrap (Cilium + Flux): must exist before anything else, and no
;;     controller exists yet to expand a release object — so expanded *here* by
;;     `helm-template`, each manifest appended as an ordinary `resource`.
;;
;;   • Everything else is GitOps: once Flux runs, the rest are declared as Flux
;;     `HelmRepository` + `HelmRelease` CRs and reconciled in-cluster.
;;
;; `helm-template` is a fold-time op: `tree`/`ops` never shell out, only a real
;; resolve does — and if `helm`/`yq` are missing it warns and skips.

;; Cluster-scoped kinds carry no namespace; the rest default to the release
;; namespace. (Not exhaustive — just the kinds these charts emit.)
(define cluster-scoped-kinds
  '("Namespace" "Node" "PersistentVolume" "ClusterRole" "ClusterRoleBinding"
    "CustomResourceDefinition" "ClusterIssuer" "StorageClass" "IngressClass"
    "GatewayClass" "PriorityClass" "RuntimeClass" "CSIDriver" "APIService"
    "ValidatingWebhookConfiguration" "MutatingWebhookConfiguration"))

;; Stamp metadata.namespace = NS onto R when it is namespaced but lacks one.
;; `helm template --namespace NS` only sets `.Release.Namespace`; charts that
;; don't reference it (e.g. flux2) emit none, so `kubectl apply` would drop them
;; in `default`. Mirrors `helm install -n NS`.
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

;; A fold-time op that renders CHART (from REPO, at VERSION) with `helm
;; template` and appends every manifest it emits to (kubernetes_resources).
;; `values` is a raw values.yaml alist (free-form, like a custom-resource spec).
(define-construct helm-template
  #:head name
  #:fields ((chart #:required) (repo #:required) (version #:required)
            (namespace #:required) (values #:default '()) (include-crds #:flag #:default #t))
  #:build
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
                    ;; Cache key: every input that changes the rendered output.
                    (key (format #f "helm\x00;~a\x00;~a\x00;~a\x00;~a\x00;~a\x00;~a\x00;~s"
                                 name chart repo version namespace include-crds values))
                    (manifests (cached-json-manifests key cmd name)))
               (fold (lambda (r s) (apply-op (resource (stamp-namespace namespace r)) s))
                     state manifests)))))))
    (string-append "helm-template " name)))

;; Upstream Gateway API CRDs. Cilium requires these to pre-exist but doesn't
;; ship them; the *experimental* channel because Cilium watches TLSRoute.
(define gateway-api-version "v1.1.0")
(define (gateway-api-crds)
  (remote-manifest "gateway-api-crds"
    (fmt (string-append "https://github.com/kubernetes-sigs/gateway-api"
                        "/releases/download/~a/experimental-install.yaml")
         gateway-api-version)))

;; cert-manager's CRDs as a pre-step, so the ClusterIssuer/Certificate CRs
;; validate at apply time even though cert-manager is installed by Flux (async).
;; The HelmRelease runs with crds disabled, so the two never fight over ownership.
(define cert-manager-version "v1.15.1")
(define (cert-manager-crds)
  (remote-manifest "cert-manager-crds"
    (fmt (string-append "https://github.com/cert-manager/cert-manager"
                        "/releases/download/~a/cert-manager.crds.yaml")
         cert-manager-version)))

;; --- GitOps layer: charts as Flux resources (reconciled in-cluster) ---

;; A Flux HelmRepository: where a chart comes from. Lives in flux-system.
(define-construct helm-repository
  #:head name
  #:fields ((url #:required) (namespace #:default "flux-system") (interval #:default "1h"))
  #:build
  (custom-resource name
    (api "source.toolkit.fluxcd.io/v1") (kind "HelmRepository")
    (namespace namespace)
    (spec `((interval . ,interval) (url . ,url)))))

;; A Flux HelmRelease: CHART from REPO at VERSION into TARGET-NAMESPACE with
;; VALUES. The CR lives in flux-system; Flux expands the chart.
(define-construct helm-release
  #:head name
  #:fields ((chart #:required) (repo #:required) (version #:required)
            (target-namespace #:default #f) (release-name #:default name)
            (timeout #:default #f) (namespace #:default "flux-system")
            (values #:default '()) (interval #:default "1h"))
  #:build
  (custom-resource name
    (api "helm.toolkit.fluxcd.io/v2") (kind "HelmRelease")
    (namespace namespace)
    (spec `((interval . ,interval)
             ;; Pin the release name; Flux otherwise defaults to
             ;; `<targetNamespace>-<name>`, breaking Service refs / RBAC that
             ;; assume the chart default.
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

;; Rancher local-path-provisioner, self-contained: namespace (PSS `privileged`,
;; helper pods mount hostPath), RBAC, config, Deployment, StorageClass.
;; Translated from the upstream v0.0.30 deploy manifest.
(define (local-path-provisioner)
  (let ((ns "local-path-storage")
        (sa "local-path-provisioner-service-account"))
    (compose-ops 'local-path-provisioner '(local-path-provisioner)
      (list
        (namespace ns (labels (pod-security.kubernetes.io/enforce "privileged")))
        (service-account sa (namespace ns))
        ;; namespaced Role + RoleBinding: manage helper pods in its own namespace.
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
        ;; config: data path /var/local-path-provisioner, NOT /var/mnt/… — on
        ;; Talos /var is writable but /var/mnt is read-only, so a hostPath mount
        ;; under it fails and every PVC hangs Pending.
        (configmap "local-path-config" (namespace ns)
          (data
            (config.json "{\n  \"nodePathMap\":[\n    { \"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\", \"paths\":[\"/var/local-path-provisioner\"] }\n  ]\n}")
            (setup "#!/bin/sh\nset -eu\nmkdir -m 0777 -p \"$VOL_DIR\"")
            (teardown "#!/bin/sh\nset -eu\nrm -rf \"$VOL_DIR\"")
            (helperPod.yaml "apiVersion: v1\nkind: Pod\nmetadata:\n  name: helper-pod\nspec:\n  priorityClassName: system-node-critical\n  tolerations:\n    - key: node.kubernetes.io/disk-pressure\n      operator: Exists\n      effect: NoSchedule\n  containers:\n  - name: helper-pod\n    image: busybox\n    imagePullPolicy: IfNotPresent")))
        ;; the provisioner itself; fieldRef env passed as raw EnvVar entries.
        (deployment "local-path-provisioner" (namespace ns) (port 0)
          (image "rancher/local-path-provisioner:v0.0.30")
          (service-account sa)
          (command "local-path-provisioner" "--debug" "start"
                   "--config" "/etc/config/config.json")
          (env '((name . "POD_NAMESPACE")
                 (valueFrom (fieldRef (fieldPath . "metadata.namespace"))))
               '((name . "CONFIG_MOUNT_PATH") (value . "/etc/config/")))
          (volumes (mount (cm "local-path-config") "/etc/config/")))
        ;; Node-local scratch StorageClass; non-default (no default annotation)
        ;; since cinder-csi is the one default.
        (storage-class "local-path" (provisioner "rancher.io/local-path")
          (volume-binding-mode "WaitForFirstConsumer") (reclaim-policy "Delete"))))))

;; edge-gateway: the library `gateway` wrapped with this homelab's two-listener
;; shape (plain HTTP + Terminate-TLS HTTPS on the wildcard cert). In host-network
;; mode the listener `port` is the host port Envoy binds on every node (unique
;; per Gateway); the Octavia LB forwards 80/443 to it.
(define-construct edge-gateway
  #:head name
  #:fields ((http-port #:required) (https-port #:required))
  #:build
  (gateway name (gateway-class-name "cilium") (namespace "gateway")
    (listener "http"  (protocol "HTTP")  (port http-port))
    (listener "https" (protocol "HTTPS") (port https-port)
              (hostname (str "*." (cfg 'domain))) (tls-certificate "wildcard-tls"))))

;; A stateful self-hosted app: PVC + single-replica Deployment that mounts it +
;; Service, built on the library `deployment` — the caller's `env` (a runtime
;; list of EnvVar entries) is spliced into the #:list `env` field with `,@env`.
;;
;; (route-host …), when set, appends an HTTPRoute on (route-gateway …) exposing
;; this app at <route-host>.<domain>.
(define-construct stateful-app
  #:head name
  #:fields ((image #:required) (port #:required)
            (namespace #:default (current-k8s-namespace))
            (storage #:default "5Gi") (mount-path #:default "/data")
            (env #:list) (resources #:default "100m-*/256Mi")
            (route-host #:default #f) (route-gateway #:default #f))
  #:build
  (compose-ops 'stateful-app `(stateful-app ,name)
    (append
      (list
        (persistent-volume-claim name (size storage) (namespace namespace))
        (deployment name (image image) (port port) (namespace namespace) (replicas 1)
          (env ,@env)
          (volumes (mount (pvc name) mount-path))
          (resources resources))
        (service name (port port) (namespace namespace)))
      (if route-host
          (list (http-route name (namespace namespace)
                  (parent-name route-gateway) (parent-namespace "gateway")
                  (hostnames (str route-host "." (cfg 'domain)))
                  (backend-service name) (backend-port port)))
          '()))))

;; ---------------------------------------------------------------------------
;; secrets store (content) — one inline, sops-encrypted document
;; ---------------------------------------------------------------------------
;;
;; Every secret in ONE embedded sops document, referenced via `(secret-ref 'key)`
;; and decrypted once by `(resolve-secret-refs)`. `data` keys are emitted sorted
;; before `sops -d`, so the MAC verifies regardless of order here.
;;
;; The real sealed store lives in a gitignored `homelab.secrets.scm`, loaded when
;; present. On a fresh public-repo clone it's absent, so we fall back to the dummy
;; store below — the example still renders, secrets as `<unresolved secret: …>`.
(let* ((here  (current-filename))
       (dir   (if here (dirname here) "."))
       (local (string-append dir "/homelab.secrets.scm")))
  (if (file-exists? local)
      (primitive-load local)                ; real store wins
      (secrets-store                        ; committed dummy
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
          (openstack/cloud.conf       . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")
          (ovh/applicationConsumerKey . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")
          (ovh/applicationKey         . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")
          (ovh/applicationSecret      . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")
          (wireguard/wg0.conf         . "ENC[AES256_GCM,data:DUMMY,iv:DUMMY,tag:DUMMY,type:str]")))))

;; ---------------------------------------------------------------------------
;; appliers (effects) — what `hexol apply` runs, in order, from the state
;; ---------------------------------------------------------------------------
;;
;; The `appliers` form names a sequence run in order: each reads resolved state
;; directly and shells out to its tool. Infra builds first and dumps its
;; kubeconfig to `deploy/kubeconfig`, so the cluster applies on it:
;;
;;   hexol apply examples/homelab.scm                              # whole bootstrap
;;   hexol apply --only check-api,kubernetes examples/homelab.scm  # re-apply cluster
;;
;; Between deploy steps sit checks (observe, don't mutate). `check-api` is a
;; *gate*: the kubeconfig points at the LB VIP via DNS, so it blocks until
;; kube-API answers there (DNS + Octavia settling) before manifests apply —
;; name it alongside `kubernetes` to keep the gate on a cluster re-apply.
(define (kubectl* . args)
  (apply cmd "kubectl" "--kubeconfig=deploy/kubeconfig" args))

;; The public URLs the cluster serves, read from resolved (kubernetes_resources)
;; — no cluster round-trip. Every HTTPRoute hostname plus any Ingress rule host,
;; as `https://…`, sorted + de-duped.
(define (ingress-urls state)
  (let ((rs (or (state-get state '(kubernetes_resources)) '())))
    (sort
      (delete-duplicates
        (append-map
          (lambda (r)
            (let ((kind (assq-ref r 'kind))
                  (spec (or (assq-ref r 'spec) '())))
              (cond
                ((equal? kind "HTTPRoute")
                 (map (lambda (h) (str "https://" h)) (or (assq-ref spec 'hostnames) '())))
                ((equal? kind "Ingress")
                 (filter-map (lambda (rule)
                               (and=> (assq-ref rule 'host) (lambda (h) (str "https://" h))))
                             (or (assq-ref spec 'rules) '())))
                (else '()))))
          rs))
      string<?)))

(appliers
  ("terraform"
   (terraform-applier #:workdir "deploy" #:binary "tofu"
                      #:output->file '(("kubeconfig" . "deploy/kubeconfig"))))

  ;; Infra smoke test: every control-plane VM ACTIVE (guards re-applies and
  ;; `-target` builds). `openstack` CLI with tofu's creds; true iff the unique
  ;; status of `<cluster>-cp-*` is exactly ACTIVE.
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
          #:fatal? #f))

  ;; A `report` (always runs, never fatal) printing every service URL from the
  ;; rendered HTTPRoutes. URLs to stdout (pipeable); framing line to stderr.
  ("ingress-urls"
   (report "service URLs"
           (lambda (state)
             (let ((urls (ingress-urls state)))
               (if (null? urls)
                   (format (current-error-port) ";;   (no HTTPRoutes/Ingresses rendered)~%")
                   (for-each (lambda (u) (format #t "~a~%" u)) urls)))))))

;; ---------------------------------------------------------------------------
;; actions (custom CLI verbs) — what this inventory adds to `hexol`
;; ---------------------------------------------------------------------------
;;
;; An applier is a *step* in `hexol apply`; an action is its own *verb*, run only
;; when named. So teardown belongs here, not the pipeline — unreachable by
;; accident, no HEXOL_DESTROY guard needed (tofu's own prompt still gates it).
;;
;;   hexol destroy            -i examples/homelab.scm   # tofu destroy (prompts)
;;   hexol destroy --dry-run  -i examples/homelab.scm   # tofu plan -destroy
(actions
  ("destroy" "destroy [--dry-run]   tear the stack down (tofu destroy)"
   (terraform-destroyer #:workdir "deploy" #:binary "tofu"))

  ;; Re-fetch cluster credentials from existing tofu state, no apply: writes
  ;; deploy/kubeconfig + deploy/talosconfig. Install with:
  ;;   hexol output -i examples/homelab.scm
  ;;   cp deploy/kubeconfig  ~/.kube/config
  ;;   cp deploy/talosconfig ~/.talos/config
  ("output" "output               write kubeconfig + talosconfig from tofu state"
   (terraform-outputter #:workdir "deploy" #:binary "tofu"
                        #:outputs '(("kubeconfig"  . "deploy/kubeconfig")
                                    ("talosconfig" . "deploy/talosconfig"))))

  ;; Day-2 config rollout: push machine config to nodes one at a time, waiting
  ;; for cluster health between each (so a reboot never breaks etcd quorum). Edit
  ;; the talos-patch, `hexol apply --only terraform` to refresh state, then:
  ;;   hexol config-apply --dry-run -i examples/homelab.scm   # show the diff
  ;;   hexol config-apply           -i examples/homelab.scm   # roll it live
  ("config-apply" "config-apply [--dry-run]   roll machine config to nodes (talosctl, health-gated)"
   (talos-config-applier
     #:workdir "deploy" #:binary "talosctl" #:tofu "tofu"
     #:talosconfig "deploy/talosconfig"
     #:nodes (map (lambda (n)
                    (let ((i (car n)))
                      (list (str "cp-" i) (str "cp_" i "_address") (str "cp_" i "_config"))))
                  (nodes)))))

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

  ;; The talos provider needs no static config — it talks to nodes.
  (terraform-provider "talos")

  ;; OVH DNS. Only the region is pinned; credentials come from the env
  ;; (OVH_APPLICATION_KEY/_SECRET, OVH_CONSUMER_KEY — create at
  ;; api.ovh.com/createToken with GET/POST/PUT/DELETE on /domain/zone/*).
  (terraform-provider "ovh"
    (endpoint (cfg 'ovh-endpoint)))

  ;; Cluster PKI + secrets, generated once, reused by every node config.
  (terraform-resource "talos_machine_secrets" "this"
    (talos_version (cfg 'talos-version)))

  ;; The Talos image, uploaded to Glance from Image Factory. A compressed raw
  ;; disk decompressed on upload.
  (terraform-resource "openstack_images_image_v2" "talos"
    (name (str "talos-" (cfg 'talos-version)))
    (image_source_url
      (fmt "https://factory.talos.dev/image/~a/~a/openstack-amd64.raw.xz"
           (cfg 'talos-schematic) (cfg 'talos-version)))
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

  ;; One Octavia LB fronting everything on a single VIP: kube-apiserver (6443,
  ;; health-monitored) and ingress (80/443). The Cilium Gateway runs host-network
  ;; (no cloud LB on bare OpenStack), so its Envoy binds host ports 30080/30443
  ;; on every node and the LB TCP-forwards 80/443 there (the Gateway terminates
  ;; the wildcard TLS itself). #:name labels both the LB and the floating IP.
  (openstack-lb #:name "api" #:os-name (str (cfg 'cluster-name) "-api")
    #:subnet "talos" #:ext-net (cfg 'ext-net)
    #:listeners
    (list (lb-listener "kube-api" #:port 6443 #:monitor #t #:backends (node-backends))
          (lb-listener "ingress-http"  #:port 80 #:member-port (cfg 'ingress-http-hostport)  #:backends (node-backends))
          (lb-listener "ingress-https" #:port 443 #:member-port (cfg 'ingress-https-hostport) #:backends (node-backends))
          ;; SOURCE_IP stickiness: wg sessions are per-node (see `lb-listener`).
          (lb-listener "wireguard" #:port (cfg 'wg-port) #:protocol "UDP"
                       #:persistence "SOURCE_IP" #:backends (node-backends))))

  ;; DNS. PUBLIC names resolve to the LB floating IP; the `*.<domain>` wildcard
  ;; resolves to the private node IPs (VPN-only), so every other app is private.
  ;; Explicit records beat the wildcard.
  (map (lambda (name)
         (dns-a name (str name "." (cfg 'domain))
                (target (ref openstack_networking_floatingip_v2 api address))))
       '("api" "vpn" "jellyfin"))
  (map (lambda (n)
         (dns-a (str "wildcard-cp-" (car n)) (str "*." (cfg 'domain)) (target (cdr n))))
       (nodes))

  ;; One-time bootstrap: init etcd on node 1, once its VM (and FIP) exist.
  (terraform-resource "talos_machine_bootstrap" "this"
    (node                 (tf-ref "openstack_networking_floatingip_v2" "cp-1" "address"))
    (endpoint             (tf-ref "openstack_networking_floatingip_v2" "cp-1" "address"))
    (client_configuration (ref talos_machine_secrets this client_configuration))
    (depends_on (list "openstack_networking_floatingip_associate_v2.cp-1")))

  ;; Pull kubeconfig + talosconfig back out as Terraform outputs. The
  ;; talos_cluster_kubeconfig *resource* fetches it once bootstrap ran (the
  ;; same-named data source is deprecated).
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

  ;; Per-node endpoint + rendered machine config, so `config-apply' can pull
  ;; each node's exact config from state and roll it. One (address, config) pair
  ;; per node: cp_<i>_address / cp_<i>_config.
  (append-map
    (lambda (n)
      (let ((i (car n)))
        (list
          (terraform-output (str "cp_" i "_address")
            (value (tf-ref "openstack_networking_floatingip_v2" (str "cp-" i) "address")))
          (terraform-output (str "cp_" i "_config")
            (value (tf-ref "data.talos_machine_configuration" (str "controlplane-" i) "machine_configuration"))
            (sensitive #t)))))
    (nodes))

  ;; ====================================================================
  ;; CLUSTER  — render with `-o yaml`
  ;; ====================================================================

  ;; ---- bootstrap layer: expanded inline (no controller exists yet) ----

  ;; Gateway API CRDs — before Cilium's Gateway controller and the routes.
  (gateway-api-crds)

  ;; --- Cilium: CNI + kube-proxy replacement + Gateway API ---
  ;; (cni:none in Talos means this is the cluster network; apply it first.)
  (helm-template "cilium" (namespace "kube-system")
    (chart "cilium") (repo "https://helm.cilium.io") (version "1.16.19")
    (values `((kubeProxyReplacement . #t)
               ;; Talos KubePrism: node-local apiserver endpoint.
               (k8sServiceHost . "localhost") (k8sServicePort . 7445)
               (ipam (mode . "kubernetes"))
               ;; Gateway API host-network: no cloud LB on bare OpenStack, so
               ;; the Gateway's Envoy binds listener ports on every node and the
               ;; Octavia LB forwards to them (see ingress LB + gateway).
               (gatewayAPI (enabled . #t) (hostNetwork (enabled . #t)))
               ;; The private Gateway binds privileged ports (80/443), so grant
               ;; NET_BIND_SERVICE + keepCapNetBindService (the `envoy` list
               ;; replaces the chart default, hence NET_ADMIN + SYS_ADMIN here).
               (envoy (enabled . #t)
                      (securityContext
                        (capabilities
                          (envoy "NET_ADMIN" "SYS_ADMIN" "NET_BIND_SERVICE")
                          (keepCapNetBindService . #t))))
               (hubble (relay (enabled . #t)) (ui (enabled . #t)))
               (securityContext
                 (capabilities
                   ;; flat list of cap strings (schema wants a sequence)
                   (ciliumAgent "CHOWN" "KILL" "NET_ADMIN" "NET_RAW"
                                "IPC_LOCK" "SYS_ADMIN" "SYS_RESOURCE"
                                "DAC_OVERRIDE" "FOWNER" "SETGID" "SETUID")
                   (cleanCiliumState "NET_ADMIN" "SYS_ADMIN" "SYS_RESOURCE")))
               ;; Talos mount points for CNI install + cgroup.
               (cgroup (autoMount (enabled . #f)) (hostRoot . "/sys/fs/cgroup")))))

  ;; The GatewayClass our Gateway binds to. Cilium controls one with this
  ;; controllerName but doesn't create it, so we must — else Gateways stall
  ;; "Waiting for controller".
  (gateway-class "cilium" (controller-name "io.cilium/gateway-controller"))

  ;; --- kubelet-csr-approver: auto-approve kubelet serving-cert CSRs ---
  ;; Talos sets `rotate-server-certificates: true`; nothing approves the
  ;; resulting CSRs by default, so `kubectl logs/exec` and metrics fail with
  ;; "tls: internal error". This approves CSRs whose SANs match our nodes
  ;; (hostname pattern + private subnet); node names aren't in DNS, so bypass it.
  (helm-template "kubelet-csr-approver" (namespace "kube-system")
    (chart "kubelet-csr-approver")
    (repo "https://postfinance.github.io/kubelet-csr-approver") (version "1.2.14")
    ;; Tolerate an optional domain suffix (FQDN-style hostnames).
    (values `((providerRegex . ,(str "^" (cfg 'cluster-name) "-cp-[0-9]+(\\..+)?$"))
              (bypassDnsResolution . #t)
              (providerIpPrefixes ,(cfg 'net-cidr)))))

  ;; --- local-path-provisioner: node-local scratch StorageClass (non-default) ---
  ;; Node-local hostPath volumes, non-default (cinder-csi is) since they pin to a
  ;; node for life. Keep for throwaway scratch (opt in with storageClassName
  ;; "local-path"). See `local-path-provisioner` for the Talos path/PSS details.
  (local-path-provisioner)

  ;; --- cinder-csi: OVH Block Storage as the DEFAULT StorageClass ---
  ;; Network-attached volumes that follow a pod across nodes (unlike local-path's
  ;; node-pinned PVs). The driver authenticates with `cloud.conf' (the whole INI
  ;; is one sealed secret). The driver is a Flux HelmRelease below; here we lay
  ;; down the credential Secret and the default StorageClass it backs. Volume
  ;; type unset → OVH project default.
  (secret "cloud-config" (namespace "kube-system")
    (string-data (cloud.conf (secret-ref 'openstack/cloud.conf))))
  (storage-class "cinder" (provisioner "cinder.csi.openstack.org") (default)
    (volume-binding-mode "WaitForFirstConsumer") (allow-volume-expansion)
    (reclaim-policy "Delete"))

  ;; --- WireGuard: the VPN that gates the private services ---
  ;; A host-networked wg server (UDP 51820). A DaemonSet so it runs on every node
  ;; — the LB's `wireguard` listener fans UDP to all backends with no monitor, so
  ;; each must listen or a source-IP-pinned client black-holes. PostUp masquerades
  ;; client traffic out eth0 so clients reach the PRIVATE Gateway on node IPs.
  ;; Privileged in its own PSS-privileged namespace (manages the kernel wg iface).
  (namespace "vpn" (labels (pod-security.kubernetes.io/enforce "privileged")))
  ;; wg0.conf (server key + peers) from the inline secrets-store.
  (secret "wireguard-config" (namespace "vpn")
    (string-data (wg0.conf (secret-ref 'wireguard/wg0.conf))))
  ;; nftables-only Talos kernel: the image must ship `nft' for wg-quick's PostUp
  ;; (the old 2021 -ls75 tag had only legacy iptables and never came up).
  (daemonset "wireguard" (namespace "vpn")
    (image "lscr.io/linuxserver/wireguard:1.0.20250521-r1-ls114")
    (port (cfg 'wg-port)) (host-port (cfg 'wg-port)) (protocol "UDP")
    (host-network) (privileged) (capabilities "NET_ADMIN" "SYS_MODULE")
    (volumes (mount (sec "wireguard-config") "/config/wg_confs")
             (mount (host-path "/lib/modules") "/lib/modules" #:read-only #t)))

  ;; --- Flux: the GitOps controller that reconciles everything below ---
  ;; with-namespace creates flux-system (the flux2 chart doesn't), co-located
  ;; with its consumer. Other namespaces come from their own with-namespace blocks.
  (with-namespace "flux-system"
    (helm-template "flux2" (namespace "flux-system")
      (chart "flux2") (repo "https://fluxcd-community.github.io/helm-charts")
      (version "2.14.0")))

  ;; ---- GitOps layer: Flux resources, reconciled in-cluster by Flux ----

  ;; chart sources (helm-repository defaults to flux-system).
  (helm-repository "jetstack" (url "https://charts.jetstack.io"))
  (helm-repository "prometheus-community" (url "https://prometheus-community.github.io/helm-charts"))
  (helm-repository "cert-manager-webhook-ovh" (url "https://aureq.github.io/cert-manager-webhook-ovh/"))
  (helm-repository "cloud-provider-openstack" (url "https://kubernetes.github.io/cloud-provider-openstack"))

  ;; --- cinder-csi driver (Flux): controller + per-node DaemonSet ---
  ;; Uses the pre-created `cloud-config' Secret (secret.create #f) and skips the
  ;; chart's StorageClass — we declared `cinder' (default) above. Talos: the node
  ;; plugin needs the rshared kubelet mount in the talos-patch. NOTE: pin the
  ;; chart version to the cluster's k8s minor — bump if Flux reports it unavailable.
  (helm-release "openstack-cinder-csi" (repo "cloud-provider-openstack")
    (chart "openstack-cinder-csi") (version "2.31.2") (target-namespace "kube-system")
    (values '((secret (enabled . #t) (create . #f) (name . "cloud-config"))
               (storageClass (enabled . #f))
               ;; Drop the chart's default `cacert' hostPath: its create-if-missing
               ;; mount fails on Talos's read-only /etc. We set no `ca-file' (OVH
               ;; keystone uses a public cert), so keep only the cloud-config mount.
               (csi (plugin
                      (volumes)            ; render {}: drop default cacert volume
                      (volumeMounts ((name . "cloud-config")
                                     (mountPath . "/etc/kubernetes")
                                     (readOnly . #t))))))))

  ;; --- cert-manager (Flux): ACME wildcard cert for *.<domain> ---
  ;; A wildcard cert, which Let's Encrypt only issues over DNS-01 — so we solve
  ;; DNS-01 against the OVH zone via cert-manager-webhook-ovh. Its OVH API creds
  ;; live in the `ovh-credentials` Secret, decrypted from sops at render time.
  ;; `groupName` must match the webhook chart + solver. CRDs are pre-applied by
  ;; `(cert-manager-crds)`, so this release runs with `crds.enabled #f`.
  (cert-manager-crds)
  (helm-release "cert-manager" (repo "jetstack")
    (chart "cert-manager") (version cert-manager-version) (target-namespace "cert-manager")
    (values '((crds (enabled . #f)))))
  (helm-release "cert-manager-webhook-ovh" (repo "cert-manager-webhook-ovh")
    (chart "cert-manager-webhook-ovh") (version "0.9.10") (target-namespace "cert-manager")
    (values `((groupName . ,(str "acme." (cfg 'domain))))))
  (with-namespace "cert-manager"
    ;; the ovh-credentials Secret — values from the inline secrets-store
    ;; (namespace defaults to the enclosing with-namespace, cert-manager)
    (secret "ovh-credentials"
      (string-data
        (applicationConsumerKey (secret-ref 'ovh/applicationConsumerKey))
        (applicationSecret      (secret-ref 'ovh/applicationSecret))
        (applicationKey         (secret-ref 'ovh/applicationKey))))
    ;; The chart only wires creds-Secret RBAC for issuers IT creates; ours are
    ;; managed here, so grant the webhook's SA read access to the Secret.
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
                     ;; solve ACME dns-01 via OVH webhook (wildcard-capable)
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
    ;; Two edge Gateways sharing the wildcard cert. The PUBLIC one binds the host
    ;; ports the LB forwards 80/443 to; the PRIVATE one binds ports left closed —
    ;; VPN-only. A route's choice of parent Gateway makes a service public/private.
    (edge-gateway "homelab-public"
                  (http-port  (cfg 'ingress-http-hostport))
                  (https-port (cfg 'ingress-https-hostport)))
    (edge-gateway "homelab-private"
                  (http-port  (cfg 'private-http-hostport))
                  (https-port (cfg 'private-https-hostport))))

  ;; --- kube-prometheus-stack (Flux): metrics + Grafana (via the Gateway) ---
  (helm-release "kube-prometheus-stack" (repo "prometheus-community")
    (chart "kube-prometheus-stack") (version "61.3.0") (target-namespace "monitoring")
    (timeout "15m")   ; big chart (operator + CRDs + Grafana) — exceeds Flux's 5m
    (values `((grafana (enabled . #t)
                       (adminPassword . "changeme"))
              (prometheus (prometheusSpec (retention . "30d"))))))
  (with-namespace "monitoring"
    (http-route "grafana" (parent-name "homelab-private") (parent-namespace "gateway")
      (hostnames (str "grafana." (cfg 'domain)))
      (backend-service "kube-prometheus-stack-grafana") (backend-port 80)))

  ;; --- a few standard self-hosted apps (namespace "apps") ---
  ;; Each app's `#:expose` appends its HTTPRoute (host + which Gateway).
  (with-namespace "apps"
    (stateful-app "vaultwarden" (image "vaultwarden/server:1.30.5") (port 80)
                  (storage "2Gi") (mount-path "/data")
                  (env `((name . "DOMAIN") (value . ,(str "https://vault." (cfg 'domain)))))
                  (route-host "vault") (route-gateway "homelab-private"))

    ;; jellyfin: the one PUBLIC app — public Gateway (LB-fronted).
    (stateful-app "jellyfin" (image "jellyfin/jellyfin:10.9.6") (port 8096)
                  (storage "20Gi") (mount-path "/config") (resources "500m-*/1Gi")
                  (route-host "jellyfin") (route-gateway "homelab-public"))

    (stateful-app "gitea" (image "gitea/gitea:1.22.1") (port 3000)
                  (storage "10Gi") (mount-path "/data")
                  (route-host "git") (route-gateway "homelab-private")))

  ;; One pass stamps every cluster resource with a common label.
  (label-all `((app.kubernetes.io/part-of . ,(cfg 'cluster-name))))

  ;; Decrypt the inline secrets-store, substituting each (secret-ref …). Last so
  ;; it sees every resource; render-only, never `tree`/`ops`.
  (resolve-secret-refs)
  (checksum-config))
