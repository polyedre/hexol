;;; examples/terraform.scm — one Terraform config spanning two providers.
;;;
;;; A single-file consumer of (hexol terraform) rendering a combined,
;;; init-ready `*.tf.json`: AWS (RDS + network LB) alongside an OpenStack web
;;; fleet (keypair, private network, N VMs), both providers in one
;;; `terraform {}` block. One inventory, one `(terraform_config)` tree, one render:
;;;
;;;   ./bin/hexol render -o terraform examples/terraform.scm > main.tf.json
;;;   terraform init && terraform apply        # creds via env / clouds.yaml
;;;   ./bin/hexol tree examples/terraform.scm  # the op tree
;;;
;;; The point: what inventory-as-a-program buys over hand-written HCL. Each is
;;; a few lines of Scheme here, a dedicated feature (or no equivalent) in HCL:
;;;
;;;   • Fleet by loop — `(map app-vm (iota vm-count))`; HCL needs count/for_each.
;;;   • Computed values — per-VM IPs are index arithmetic, cloud-init a string
;;;     fn (HCL: cidrhost()/templatefile()).
;;;   • Real abstraction — `aws-rds`, `aws-lb`, `web-security-group` return
;;;     *bundles* of resources (HCL's unit is a module).
;;;   • Plain conditionals — dev/prod sizing is `(if prod? …)`.
;;;   • Cross-cutting edits — `metadata-all` stamps every instance in one pass.
;;;   • Local inputs at render time — keypair public_key read from ~/.ssh.
;;;
;;; Provider names, resource types, and fleet shape are content here; (hexol
;;; terraform) only knows the language. Creds aren't baked in — AWS reads its
;;; env/profile, OpenStack reads OS_* / clouds.yaml.

(use-modules (hexol terraform)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

;; ---------- deployment knobs (content) ----------
;;
;; One symbol flips dev/prod: bigger flavor, more VMs, prod region.

(define env      (string->symbol (or (getenv "HEXOL_ENV") "dev")))
(define prod?    (eq? env 'prod))
(define vm-count (if prod? 5 2))
(define flavor   (if prod? "m1.large" "m1.small"))   ; instance flavors
(define os-region (if prod? "ALPHA11" "DELTA5"))
(define aws-region "eu-west-3")
(define image    "Debian 12")
(define net-cidr "192.168.42.0/24")

;; Read deployer's SSH public key from ~/.ssh at render time (ed25519, then
;; RSA). The one place the inventory touches the local machine.
(define (read-ssh-public-key)
  (let* ((home (or (getenv "HOME") "."))
         (path (find file-exists?
                     (map (lambda (f) (string-append home "/.ssh/" f))
                          '("id_ed25519.pub" "id_rsa.pub")))))
    (unless path
      (error "terraform: no SSH public key in ~/.ssh (id_ed25519.pub / id_rsa.pub)"))
    (string-trim-right (call-with-input-file path get-string-all))))

;; Per-VM cloud-init in Scheme — no templatefile() indirection.
(define (cloud-init hostname)
  (fmt "#cloud-config\nhostname: ~a\npackage_update: true\npackages: [nginx]\n"
       hostname))

;; ---------- AWS infrastructure (content) ----------
;;
;; Each builder bundles `terraform-resource` ops plus the `tf-output`s
;; downstream tooling reads back.

(define* (aws-rds #:key name engine (engine-version "15")
                  (instance-class "db.t3.medium")
                  (allocated-storage 20) (username "app") (multi-az #f))
  (compose-ops 'aws-rds `(aws-rds ,name)
    (list
      (terraform-resource "aws_security_group" (str name "-sg")
        (description (fmt "RDS ~a ingress from VPC" name))
        (block ingress
          (from_port   5432)
          (to_port     5432)
          (protocol    "tcp")
          (cidr_blocks (list "10.0.0.0/8"))))
      (terraform-resource "aws_db_instance" name
        (engine              engine)
        (engine_version      engine-version)
        (instance_class      instance-class)
        (allocated_storage   allocated-storage)
        (username            username)
        (multi_az            multi-az)
        (skip_final_snapshot #t)
        (vpc_security_group_ids
          (list (tf-ref "aws_security_group" (str name "-sg") "id"))))
      (tf-output "aws_db_instance" name "endpoint")
      (tf-output "aws_db_instance" name "port"))))

(define* (aws-lb #:key name (scheme "internet-facing") (port 443) (protocol "TCP"))
  (compose-ops 'aws-lb `(aws-lb ,name)
    (list
      (terraform-resource "aws_lb" name
        (load_balancer_type "network")
        (internal           (string=? scheme "internal"))
        (subnets            (list "subnet-aaa" "subnet-bbb" "subnet-ccc")))
      (terraform-resource "aws_lb_target_group" name
        (port     port)
        (protocol protocol)
        (vpc_id   "vpc-main")
        (block health_check
          (protocol protocol)
          (port     (number->string port))))
      (terraform-resource "aws_lb_listener" name
        (load_balancer_arn (tf-ref "aws_lb" name "arn"))
        (port              port)
        (protocol          protocol)
        (block default_action
          (type             "forward")
          (target_group_arn (tf-ref "aws_lb_target_group" name "arn"))))
      (tf-output "aws_lb" name "dns_name"))))

;; ---------- OpenStack infrastructure (content) ----------

(define (os-keypair name)
  (terraform-resource "openstack_compute_keypair_v2" name
    (name       (str "hexol-" name))
    (public_key (read-ssh-public-key))))

(define (os-network name)
  (terraform-resource "openstack_networking_network_v2" name
    (name           (str "hexol-" name))
    (admin_state_up #t)))

(define (os-subnet name network cidr)
  (terraform-resource "openstack_networking_subnet_v2" name
    (name       (str "hexol-" name))
    ;; `network` is a computed parameter, so `tf-ref`, not `ref`.
    (network_id (tf-ref "openstack_networking_network_v2" network "id"))
    (cidr       cidr)
    (ip_version 4)))

;; Reusable bundle: security group + its one HTTP ingress rule.
(define (web-security-group)
  (compose-ops 'web-security-group '(web-security-group)
    (list
      (terraform-resource "openstack_networking_secgroup_v2" "web"
        (name        "hexol-web")
        (description "hexol web tier"))
      (terraform-resource "openstack_networking_secgroup_rule_v2" "web-http"
        (direction         "ingress")
        (ethertype         "IPv4")
        (protocol          "tcp")
        (port_range_min    80)
        (port_range_max    80)
        (remote_ip_prefix  "0.0.0.0/0")
        (security_group_id (ref openstack_networking_secgroup_v2 web id))))))

;; One VM from its fleet index: derived name, index-computed IP, per-host
;; cloud-init.
(define (app-vm i)
  (let ((name (str "app-" (1+ i)))
        (ip   (str "192.168.42." (+ 10 i))))
    (terraform-resource "openstack_compute_instance_v2" name
      (name            name)
      (image_name      image)
      (flavor_name     flavor)
      (key_pair        (ref openstack_compute_keypair_v2 deployer name))
      (user_data       (cloud-init name))
      (security_groups (list (ref openstack_networking_secgroup_v2 web name)))
      (block network
        (uuid        (ref openstack_networking_network_v2 internal id))
        (fixed_ip_v4 ip)))))

(define (web-fleet n)
  (compose-ops 'web-fleet `(web-fleet ,n) (map app-vm (iota n))))

;; Stamp `md` into every compute instance's `metadata` in one pass, via the
;; library's generic `transform-terraform-resources`.
(define (metadata-all md)
  (let ((op (transform-terraform-resources
              (lambda (type name body)
                (if (string-prefix? "openstack_compute_instance" type)
                    (deep-merge body `((metadata . ,md)))
                    body)))))
    (make-op (op-kind op) (op-source op) (op-effect op) "metadata-all" (op-children op))))

;; ---------- the stack ----------

(hx-ops

  ;; --- settings: both providers, one terraform {} block ---
  (terraform-settings
    (required_version ">= 1.3.0")
    (block required_providers
      (block aws       (source "hashicorp/aws") (version "~> 5.0"))
      (block openstack (source "terraform-provider-openstack/openstack")
                       (version "~> 3.0.0"))))

  (terraform-provider "aws"
    (region aws-region))

  (terraform-provider "openstack"
    (auth_url    "https://auth.cloud.example.com/v3")
    (domain_name "Default")
    (region      os-region))

  ;; --- AWS ---
  (aws-rds #:name "api-db" #:engine "postgres" #:multi-az prod?)
  (aws-lb  #:name "frontend-lb" #:port 443)

  ;; --- OpenStack: keypair, network, the web fleet ---
  (os-keypair "deployer")
  (os-network "internal")
  (os-subnet  "internal" "internal" net-cidr)
  (web-security-group)
  (web-fleet vm-count)

  ;; --- one pass tags every OpenStack instance ---
  (metadata-all `((managed_by  . "hexol")
                  (environment . ,(str env))
                  (fleet_size  . ,(str vm-count)))))
