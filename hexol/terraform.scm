;;; hexol/terraform.scm — the Terraform target library.
;;;
;;; Provider-agnostic Terraform vocabulary (cf. (hexol k8s) for K8s). Knows
;;; *Terraform* — top-level blocks (terraform / provider / resource / output
;;; …), interpolation refs, outputs, JSON config — but no specific provider.
;;; `aws_db_instance`, `openstack_compute_instance_v2`, etc. are content: they
;;; live in the consuming example (examples/aws-stack.scm,
;;; examples/openstack-stack.scm). (See the README's "What goes in the
;;; library" rule.)
;;;
;;; Authoring surface: block constructors are macros with an HCL-ish body.
;;; Each entry is an attribute `(key <expr>)` (value is evaluated Scheme) or a
;;; nested `(block key <entry>…)`. Lists are `(list …)`; `(ref type name
;;; attr)` is sugar for an interpolation string from bare symbols:
;;;
;;;   (terraform-resource "openstack_compute_instance_v2" name
;;;     (flavor_name flavor)                       ; attribute, value evaluated
;;;     (security_groups (list (ref … web name)))  ; list attribute
;;;     (block network                             ; nested block
;;;       (uuid (ref openstack_networking_network_v2 internal id))))
;;;
;;; No quasiquote/dotted pairs/paren-counting. Values evaluated, so string
;;; literals are quoted (`"tcp"`) — right for a reference-heavy domain.
;;;
;;; Sink: each constructor deep-merges its body into the Terraform-JSON tree
;;; under `(terraform_config <keyword> <labels…>)`, so resolved state *is* the
;;; `*.tf.json` Terraform expects —
;;;   (terraform_config (provider …) (resource (<type> (<name> …))) …)
;;; — no tags, no regrouping. `emit-terraform-json` then pretty-prints that
;;; subtree, reached via `hexol render -o terraform` (Terraform reads JSON
;;; config natively).
;;;
;;; `tf-output` ≠ the Terraform `output` block: it records logical outputs
;;; under `(terraform_outputs <type> <name> <attr>)` as interpolation strings,
;;; so later ops `get` them by name and wire one resource's output into
;;; another target (K8s Secret, Ingress host …) — see examples/aws-stack.scm.

(define-module (hexol terraform)
  #:use-module (hexol kernel)
  #:use-module ((hexol yaml) #:select (object-shape?))
  #:use-module ((hexol surface) #:select (block body))
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (terraform-block terraform-resource terraform-data terraform-provider
            terraform-settings terraform-output
            ref tf-ref tf-interp tf-output
            transform-terraform-resources
            emit-terraform-json terraform->json))

;; ---------- body -> JSON-ready translation ----------
;;
;; Body macros build a nested alist (scalar attrs, alist blocks, Scheme
;; lists). `alist->json` maps it to what guile-json renders directly: alists
;; -> JSON objects (symbol keys -> string keys), lists -> vectors (arrays):
;;
;;   (network (uuid "…"))            -> "network": { "uuid": "…" }
;;   (security_groups (list "web"))  -> "security_groups": ["web"]

(define (alist->json alist)
  (map (lambda (e) (cons (car e) (value->json (cdr e)))) alist))

(define (value->json v)
  (cond
    ((symbol? v)       (symbol->string v))        ; symbol -> string
    ((object-shape? v) (alist->json v))           ; alist  -> object
    ((and (pair? v) (list? v))                     ; list   -> array
     (list->vector (map value->json v)))
    (else v)))                                      ; string / number / boolean

;; ---------- the runtime block op ----------
;;
;; Every top-level construct is a *block*: keyword + string labels + body
;; alist. Keyword and labels ARE the block's path in Terraform's JSON object
;; model, so we JSON-ify the body and deep-merge at `(terraform_config
;; <keyword> <label…>)`. Sibling blocks merge under shared keys, so the
;; accumulator holds the final grouped shape.

(define (nest path leaf)
  (if (null? path)
      leaf
      (list (cons (car path) (nest (cdr path) leaf)))))

(define (label-with keyword labels)
  (fold (lambda (l acc) (string-append acc " " l)) keyword labels))

(define (block-op keyword labels body source label)
  (let* ((path (cons* 'terraform_config (string->symbol keyword)
                      (map string->symbol labels))))
    (relabel (op:merge (nest path (alist->json body)) source) label)))

;; ---------- interpolation references ----------

;; Interpolation reference "${<type>.<name>.<attr>}". `tf-interp` is a kept
;; alias (the AWS example's original name).
(define (tf-ref type name attr)
  "Build a Terraform interpolation string \"${TYPE.NAME.ATTR}\" from string
arguments.  `tf-interp' is a kept alias."
  (string-append "${" type "." name "." attr "}"))
(define tf-interp tf-ref)

;; `(ref type name attr)` — same, from bare symbols, for statically-named
;; resources. Computed type/name: use `tf-ref` with strings.
(define-syntax ref
  (syntax-rules ()
    ((_ type name attr)
     (tf-ref (symbol->string 'type) (symbol->string 'name) (symbol->string 'attr)))))

;; ---------- block constructors ----------
;;
;; type/name/labels are evaluated expressions; body is the shared
;; `block`/`body` surface from (hexol surface). Each expands to `block-op`.

;; resource "<type>" "<name>" { … }. Tree label keeps the
;; `terraform <type>.<name>` form the AWS example relies on.
(define-syntax terraform-resource
  (syntax-rules ()
    ((_ type name entry ...)
     (block-op "resource" (list type name) (body entry ...)
               (list 'terraform-resource type name)
               (string-append "terraform " type "." name)))))

;; data "<type>" "<name>" { … } — data source. Lands under
;; (terraform_config data <type> <name>); reference attrs with
;; `(tf-ref "data.<type>" "<name>" "<attr>")`.
(define-syntax terraform-data
  (syntax-rules ()
    ((_ type name entry ...)
     (block-op "data" (list type name) (body entry ...)
               (list 'terraform-data type name)
               (string-append "data " type "." name)))))

;; provider "<name>" { … } — provider config (region, auth_url, …).
(define-syntax terraform-provider
  (syntax-rules ()
    ((_ name entry ...)
     (block-op "provider" (list name) (body entry ...)
               (list 'terraform-provider name)
               (string-append "provider " name)))))

;; terraform { … } — required_version, required_providers, backend.
(define-syntax terraform-settings
  (syntax-rules ()
    ((_ entry ...)
     (block-op "terraform" '() (body entry ...)
               '(terraform-settings) "terraform"))))

;; output "<name>" { … } — a real Terraform output block (`terraform
;; output`). Distinct from `tf-output`, which only records a string into
;; fold state.
(define-syntax terraform-output
  (syntax-rules ()
    ((_ name entry ...)
     (block-op "output" (list name) (body entry ...)
               (list 'terraform-output name)
               (string-append "output " name)))))

;; Escape hatch: any block keyword, labels as a list.
(define-syntax terraform-block
  (syntax-rules ()
    ((_ keyword labels entry ...)
     (block-op keyword labels (body entry ...)
               (list 'terraform-block keyword)
               (label-with keyword labels)))))

;; ---------- logical outputs (cross-target wiring) ----------

;; Record a logical output under (terraform_outputs <type> <name> <attr>)
;; holding the interpolation string. Downstream ops read it with
;; `(get '(terraform_outputs …))`. Cross-target wiring, not a block.
(define (tf-output type name attr)
  "Return an op that records a logical output under
(terraform_outputs TYPE NAME ATTR) holding the interpolation string, so
downstream ops can wire one resource's output into another target.  This is
cross-target state, distinct from a real Terraform `output' block."
  (op:set (list 'terraform_outputs (string->symbol type)
                (string->symbol name) (string->symbol attr))
          (tf-ref type name attr)
          `(tf-output ,type ,name ,attr)))

;; ---------- cross-cutting transforms ----------
;;
;; Terraform analogue of surface's `transform-resources`. Walks every
;; resource in `(terraform_config resource …)` and replaces each body with
;; `(f <type> <name> <body>)` (type/name as strings). *What* to change (tags,
;; policy, field rewrite) is content built on top, like `annotate-all`.
(define (transform-terraform-resources f)
  "Return an op that walks every resource in the (terraform_config resource)
tree and replaces each body with (f TYPE NAME BODY), with TYPE and NAME as
strings.  The Terraform analogue of surface's `transform-resources'."
  (make-op 'transform-terraform-resources '(transform-terraform-resources)
    (lambda (state)
      (let ((tree (state-get state '(terraform_config resource))))
        (if tree
            (state-set state '(terraform_config resource)
              (map (lambda (type-entry)
                     (cons (car type-entry)
                           (map (lambda (inst)
                                  (cons (car inst)
                                        (f (symbol->string (car type-entry))
                                           (symbol->string (car inst))
                                           (cdr inst))))
                                (cdr type-entry))))
                   tree))
            state)))
    "transform-terraform-resources"))

;; ---------- JSON emitter ----------
;;
;; The `(terraform_config)` subtree is already JSON-ready and grouped, so
;; emitting is just a pretty-print.

(define (emit-terraform-json port config)
  "Pretty-print the JSON-ready CONFIG (the (terraform_config) subtree) to
PORT as Terraform `*.tf.json'."
  (display (scm->json-string config #:pretty #t) port)
  (newline port))

(define (terraform->json config)
  "Return the JSON-ready CONFIG (the (terraform_config) subtree) as a
pretty-printed Terraform `*.tf.json' string."
  (scm->json-string config #:pretty #t))
