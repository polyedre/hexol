;;; hexol/terraform.scm — the Terraform target library.
;;;
;;; Provider-agnostic Terraform vocabulary, the way (hexol k8s) is the
;;; Kubernetes vocabulary. It knows about *Terraform* — top-level blocks
;;; (terraform / provider / resource / output …), interpolation references,
;;; outputs, JSON config syntax — but nothing about any specific provider.
;;; `aws_db_instance`, `openstack_compute_instance_v2`, the OpenStack auth URL,
;;; etc. are content: they live in the example that consumes this library
;;; (examples/aws-stack.scm, examples/openstack-stack.scm), not here.
;;; (See the "What goes in the library" rule in the README.)
;;;
;;; Authoring surface. The block constructors are macros with an HCL-ish
;;; body: each entry is either an attribute `(key <expr>)` whose value is
;;; ordinary, evaluated Scheme, or a nested block `(block key <entry>…)`.
;;; Lists are just `(list …)`, and `(ref type name attr)` is sugar for an
;;; interpolation string from bare symbols. So:
;;;
;;;   (terraform-resource "openstack_compute_instance_v2" name
;;;     (flavor_name flavor)                       ; attribute, value evaluated
;;;     (security_groups (list (ref … web name)))  ; list attribute
;;;     (block network                             ; nested block
;;;       (uuid (ref openstack_networking_network_v2 internal id))))
;;;
;;; No quasiquote, no dotted pairs, no paren-counting. Because values are
;;; evaluated, string literals are quoted (`"tcp"`, not `tcp`) — the right
;;; default for a reference-heavy domain.
;;;
;;; Sink: every block constructor deep-merges its body straight into the
;;; Terraform-JSON tree under `(terraform_config <keyword> <labels…>)`, so
;;; the resolved state *is* the `*.tf.json` object Terraform expects —
;;;   (terraform_config (provider …) (resource (<type> (<name> …))) …)
;;; — with no tags and no post-hoc regrouping. `emit-terraform-json` then
;;; just pretty-prints that subtree, reached via `hexol render -o terraform`
;;; (Terraform reads JSON config natively).
;;;
;;; `tf-output` is a different thing from the Terraform `output` block: it
;;; records logical outputs under `(terraform_outputs <type> <name> <attr>)`
;;; as interpolation strings, so later ops in the fold can `get` them by
;;; name and wire one resource's output into another target (a K8s Secret,
;;; an Ingress host, …) — see examples/aws-stack.scm.

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
;; The body macros build a clean nested alist: attribute values are plain
;; scalars, nested blocks are alists, and lists are Scheme lists.
;; `alist->json` turns that into what guile-json renders directly — alists
;; become JSON objects (symbol keys become string keys) and lists become
;; vectors (JSON arrays):
;;
;;   (network (uuid "…"))            -> "network": { "uuid": "…" }
;;   (security_groups (list "web"))  -> "security_groups": ["web"]

(define (alist->json alist)
  (map (lambda (e) (cons (car e) (value->json (cdr e)))) alist))

(define (value->json v)
  (cond
    ((symbol? v)       (symbol->string v))        ; symbol  -> string
    ((object-shape? v) (alist->json v))           ; alist   -> object
    ((and (pair? v) (list? v))                     ; list    -> array
     (list->vector (map value->json v)))
    (else v)))                                      ; string / number / boolean

;; ---------- the runtime block op ----------
;;
;; Every top-level Terraform construct is a *block*: a keyword, zero or
;; more string labels, and a body alist. The keyword and labels ARE the
;; block's path in Terraform's JSON object model, so we translate the body
;; to JSON-ready form and deep-merge it in at `(terraform_config <keyword>
;; <label…>)`. Sibling blocks (two resources of one type) merge under the
;; shared keys, so the accumulator carries the final grouped shape.

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

;; Interpolation reference — "${<type>.<name>.<attr>}". `tf-interp` is a
;; kept alias (the name the AWS example originally used).
(define (tf-ref type name attr)
  "Build a Terraform interpolation string \"${TYPE.NAME.ATTR}\" from string
arguments.  `tf-interp' is a kept alias."
  (string-append "${" type "." name "." attr "}"))
(define tf-interp tf-ref)

;; `(ref type name attr)` — the same, from bare symbols (no quotes), for
;; the common case of referencing a statically-named resource. For a
;; computed type/name, use `tf-ref` with strings.
(define-syntax ref
  (syntax-rules ()
    ((_ type name attr)
     (tf-ref (symbol->string 'type) (symbol->string 'name) (symbol->string 'attr)))))

;; ---------- block constructors ----------
;;
;; type/name/labels are ordinary expressions (evaluated); the body is the
;; shared `block`/`body` HCL-ish surface from (hexol surface). Each expands
;; to a `block-op` call.

;; resource "<type>" "<name>" { … }. The tree label keeps the
;; `terraform <type>.<name>` form the AWS example relies on.
(define-syntax terraform-resource
  (syntax-rules ()
    ((_ type name entry ...)
     (block-op "resource" (list type name) (body entry ...)
               (list 'terraform-resource type name)
               (string-append "terraform " type "." name)))))

;; data "<type>" "<name>" { … } — a data source. Same body surface as
;; terraform-resource, but lands under (terraform_config data <type> <name>);
;; reference its attributes with `(tf-ref "data.<type>" "<name>" "<attr>")`.
(define-syntax terraform-data
  (syntax-rules ()
    ((_ type name entry ...)
     (block-op "data" (list type name) (body entry ...)
               (list 'terraform-data type name)
               (string-append "data " type "." name)))))

;; provider "<name>" { … } — provider configuration (region, auth_url, …).
(define-syntax terraform-provider
  (syntax-rules ()
    ((_ name entry ...)
     (block-op "provider" (list name) (body entry ...)
               (list 'terraform-provider name)
               (string-append "provider " name)))))

;; terraform { … } — settings: required_version, required_providers, backend.
(define-syntax terraform-settings
  (syntax-rules ()
    ((_ entry ...)
     (block-op "terraform" '() (body entry ...)
               '(terraform-settings) "terraform"))))

;; output "<name>" { … } — a real Terraform output block (`terraform output`).
;; Distinct from `tf-output`, which only records a string into fold state.
(define-syntax terraform-output
  (syntax-rules ()
    ((_ name entry ...)
     (block-op "output" (list name) (body entry ...)
               (list 'terraform-output name)
               (string-append "output " name)))))

;; Generic escape hatch: any block keyword, labels given as a list.
(define-syntax terraform-block
  (syntax-rules ()
    ((_ keyword labels entry ...)
     (block-op keyword labels (body entry ...)
               (list 'terraform-block keyword)
               (label-with keyword labels)))))

;; ---------- logical outputs (cross-target wiring) ----------

;; Record a logical output under (terraform_outputs <type> <name> <attr>),
;; holding the interpolation string. Provider-agnostic; downstream ops read
;; it with `(get '(terraform_outputs …))`. (Cross-target wiring, not a block.)
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
;; The Terraform analogue of surface's `transform-resources`. Walk every
;; resource in the `(terraform_config resource …)` tree and replace each
;; body with `(f <type> <name> <body>)` (type/name as strings). Reusable
;; and provider-agnostic — *what* to change (stamp tags, inject a policy,
;; rewrite a field) is content built on top, the way `annotate-all` is
;; built on `transform-resources`.
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
;; The `(terraform_config)` subtree is already JSON-ready and already has
;; Terraform's grouped shape, so emitting is just a pretty-print.

(define (emit-terraform-json port config)
  "Pretty-print the JSON-ready CONFIG (the (terraform_config) subtree) to
PORT as Terraform `*.tf.json'."
  (display (scm->json-string config #:pretty #t) port)
  (newline port))

(define (terraform->json config)
  "Return the JSON-ready CONFIG (the (terraform_config) subtree) as a
pretty-printed Terraform `*.tf.json' string."
  (scm->json-string config #:pretty #t))
