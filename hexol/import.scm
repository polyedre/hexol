;;; hexol/import.scm — `hexol import`: existing manifests -> a hexol inventory.
;;;
;;; Lowers the migration cost from "rewrite" to "wrap": feed what you already
;;; have and get a Scheme inventory file back, one op per object, that renders
;;; to the same thing. From there you refactor at your own pace — pull a
;;; repeated `resource` into a helper, swap a `(resource …)` for its typed
;;; construct, gate a block with `hx-when`.
;;;
;;;   (import-yaml text #:sugar? #:clean? #:source)   k8s manifest stream
;;;   (import-terraform-json text #:source)           Terraform JSON config
;;;
;;; Both return the inventory file as a string (`(use-modules …)` + `(hx-ops
;;; …)`), documents in input order.
;;;
;;; YAML: the (yaml) module's `read-yaml-file` reads one document, from a
;;; file, and drops scalar style — so `"true"` and `true` come back the same
;;; string. Manifests need all three (multi-doc streams, stdin, and a
;;; ConfigMap's `"256"` staying a string while `replicas: 2` becomes a
;;; number), so `read-yaml-documents` drives the same (yaml libyaml) bindings
;;; directly: plain scalars get YAML core-schema typing, quoted/block scalars
;;; stay strings. Values land in the (hexol yaml) model — symbol-keyed alists
;;; for maps, lists for sequences, string/number/boolean leaves — which is
;;; what `resource` consumes and `hexol render -o yaml` emits.
;;;
;;; `--sugar` lifts an object to its typed (hexol k8s) construct (namespace /
;;; configmap / secret / service / deployment) when the object is exactly what
;;; that construct would build: the candidate form is *evaluated* and its
;;; resource compared (maps order-insensitively) to the imported object;
;;; anything else — an extra annotation, a second container — stays a
;;; `resource`. So sugar never changes what renders.
;;;
;;; Terraform: JSON config only (`*.tf.json`, what `render -o terraform`
;;; emits). HCL text is out of scope — there is no HCL parser here.

(define-module (hexol import)
  #:use-module (hexol kernel)
  #:use-module ((hexol yaml) #:select (object-shape?))
  #:autoload   (hexol k8s) (res)
  #:use-module (yaml libyaml)
  #:use-module (nyacc foreign cdata)
  #:use-module ((system foreign) #:prefix ffi:)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 pretty-print)
  #:use-module (ice-9 format)
  #:export (read-yaml-documents clean-k8s-object
            k8s-object->form terraform-config->forms
            import-yaml import-terraform-json
            same-shape?))

;; ---------------------------------------------------------------------------
;; YAML reader — multi-document, style-aware
;; ---------------------------------------------------------------------------

;; Plain-scalar typing (YAML 1.2 core schema, plus the 1.1 spellings k8s
;; tooling still emits). Quoted scalars never reach this.
(define number-rx
  (make-regexp "^[-+]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?$"))

(define (plain-scalar->scm s)
  (cond
    ((member s '("" "~" "null" "Null" "NULL"))    'null)
    ((member s '("true" "True" "TRUE"))           #t)
    ((member s '("false" "False" "FALSE"))        #f)
    ;; `string->number' raises on out-of-range spellings ("266437e999999999")
    ;; that number-rx still matches; those stay strings.
    ((and (regexp-exec number-rx s)
          (false-if-exception (string->number s)))
     => (lambda (n) n))
    (else s)))

;; libyaml node -> (hexol yaml) value. Mappings become symbol-keyed alists
;; in source order; a `null` value drops its key (there is no null in the
;; state model — an absent key renders the same as YAML's absence). Sequences
;; become lists; a null item becomes '() (renders `{}`).
;; libyaml's node stack is a yaml_node_t* (1-based indices); compute the
;; element address by hand and wrap it as a node pointer.
(define (node-at stack index)
  (make-cdata yaml_node_t*
              (+ (ffi:pointer-address (cdata-ref stack))
                 (* (1- index) (ctype-size yaml_node_t)))))

(define (convert-tree root stack)
  (define (scalar node)
    (let ((style (cdata*-ref node 'data 'scalar 'style))
          (text  (ffi:pointer->string (cdata*-ref node 'data 'scalar 'value))))
      (if (eq? style 'YAML_PLAIN_SCALAR_STYLE) (plain-scalar->scm text) text)))
  ;; Walk a libyaml stack (items or pairs) from TOP back to START, SIZE bytes
  ;; per slot, collecting (f slot-address) in order.
  (define (slots start top size f)
    (let loop ((acc '()) (addr (- (ffi:pointer-address top) size)))
      (if (>= addr (ffi:pointer-address start))
          (loop (cons (f addr) acc) (- addr size))
          acc)))
  (define (convert node)
    (case (cdata*-ref node 'type)
      ((YAML_SCALAR_NODE) (scalar node))
      ((YAML_SEQUENCE_NODE)
       (map (lambda (v) (if (eq? v 'null) '() v))
            (slots (cdata*-ref node 'data 'sequence 'items 'start)
                   (cdata*-ref node 'data 'sequence 'items 'top)
                   (ctype-size yaml_node_item_t)
                   (lambda (addr)
                     (convert (node-at stack (cdata-ref (make-cdata (cpointer 'int) addr) '*)))))))
      ((YAML_MAPPING_NODE)
       (filter-map
         (lambda (kv) (and (not (eq? (cdr kv) 'null)) kv))
         (slots (cdata*-ref node 'data 'mapping 'pairs 'start)
                (cdata*-ref node 'data 'mapping 'pairs 'top)
                (ctype-size yaml_node_pair_t)
                (lambda (addr)
                  (let ((pair (make-cdata yaml_node_pair_t* addr)))
                    (cons (string->symbol
                            (let ((k (convert (node-at stack (cdata*-ref pair 'key)))))
                              (if (string? k) k (format #f "~a" k))))
                          (convert (node-at stack (cdata*-ref pair 'value)))))))))
      (else (error "yaml: unexpected node type"))))
  (convert root))

(define (read-yaml-documents text)
  "Parse TEXT, a YAML stream, into a list of documents in stream order.
Maps are symbol-keyed alists, sequences lists; plain scalars are typed
(number / boolean), quoted and block scalars stay strings."
  (let* ((parser  (make-cdata yaml_parser_t))
         (&parser (cdata& parser))
         (bv      (string->utf8 text)))
    (yaml_parser_initialize &parser)
    (yaml_parser_set_input_string &parser (ffi:bytevector->pointer bv) (bytevector-length bv))
    (let loop ((docs '()))
      (let* ((document  (make-cdata yaml_document_t))
             (&document (cdata& document)))
        (when (zero? (yaml_parser_load &parser &document))
          (let ((problem (cdata-ref parser 'problem))
                (line    (cdata-ref parser 'problem_mark 'line)))
            (yaml_parser_delete &parser)
            (error (format #f "yaml: line ~a: ~a" (1+ line)
                           (if (NULL? problem) "parse error"
                               (ffi:pointer->string problem))))))
        (let ((root (yaml_document_get_root_node &document)))
          (if (NULL? root)                             ; NULL root: end of stream
              (begin (yaml_document_delete &document)
                     (yaml_parser_delete &parser)
                     (reverse docs))
              (let* ((stack (cdata-sel document 'nodes 'start))
                     (tree  (convert-tree root stack)))
                (yaml_document_delete &document)
                (loop (cons tree docs)))))))))

;; ---------------------------------------------------------------------------
;; alist helpers
;; ---------------------------------------------------------------------------

;; Nested lookup; #f when any step is missing or not a map.
(define (ref obj . keys)
  (let loop ((obj obj) (keys keys))
    (cond ((null? keys) obj)
          ((and (object-shape? obj) (assq (car keys) obj))
           => (lambda (e) (loop (cdr e) (cdr keys))))
          (else #f))))

(define (without alist . keys)
  (remove (lambda (e) (memq (car e) keys)) alist))

(define (same-shape? a b)
  "Structural equality where maps compare order-insensitively (sequences
stay ordered) and a symbol equals the string of its name."
  (cond
    ((and (object-shape? a) (object-shape? b))
     (and (= (length a) (length b))
          (every (lambda (e)
                   (let ((o (assq (car e) b)))
                     (and o (same-shape? (cdr e) (cdr o)))))
                 a)))
    ((and (pair? a) (pair? b))
     (and (= (length a) (length b)) (every same-shape? a b)))
    ((and (symbol? a) (string? b)) (string=? (symbol->string a) b))
    ((and (string? a) (symbol? b)) (string=? a (symbol->string b)))
    (else (equal? a b))))

;; ---------------------------------------------------------------------------
;; k8s: cleaning and the generic form
;; ---------------------------------------------------------------------------

;; Server-populated fields a `kubectl get -o yaml` dump carries; none belong
;; in a manifest you apply. A `kind: List` wrapper is unwrapped by the caller.
(define runtime-metadata
  '(managedFields uid resourceVersion creationTimestamp generation selfLink))

(define (clean-k8s-object obj)
  "Strip status, managedFields and the other server-populated metadata
(uid, resourceVersion, creationTimestamp, generation, selfLink, the
last-applied-configuration annotation) from a k8s object alist."
  (map (lambda (e)
         (if (eq? (car e) 'metadata)
             (cons 'metadata
                   (filter-map
                     (lambda (m)
                       (if (eq? (car m) 'annotations)
                           (let ((kept (without (cdr m) 'kubectl.kubernetes.io/last-applied-configuration)))
                             (and (pair? kept) (cons 'annotations kept)))
                           m))
                     (apply without (cdr e) runtime-metadata)))
             e))
       (without obj 'status)))

;; kubectl's `kind: List` envelope holds the real objects under `items`.
(define (unwrap-list doc)
  (if (and (equal? (ref doc 'kind) "List") (list? (ref doc 'items)))
      (ref doc 'items)
      (list doc)))

(define (resource-form obj) `(resource ',obj))

;; ---------------------------------------------------------------------------
;; k8s: sugar — lift to a typed construct when it rebuilds the same object
;; ---------------------------------------------------------------------------

;; A map-field key: the bare symbol when it reads back as itself, else the
;; string form (construct-map-entries accepts both).
(define (map-key sym)
  (let ((name (symbol->string sym)))
    (if (string=? (object->string sym) name) sym name)))

(define (map-entries alist)
  (map (lambda (e) (list (map-key (car e)) (cdr e))) alist))

;; `(labels …)` for the labels beyond the construct's own `app`/name label.
(define (extra-labels obj own)
  (let ((extra (apply without (or (ref obj 'metadata 'labels) '()) own)))
    (if (null? extra) '() `((labels ,@(map-entries extra))))))

(define (opt key val default)
  (if (equal? val default) '() `((,key ,val))))

;; envFrom entry -> (cm "n") / (sec "n"); #f when it is anything else.
(define (env-from-form e)
  (cond ((ref e 'configMapRef 'name) => (lambda (n) `(cm ,n)))
        ((ref e 'secretRef 'name)    => (lambda (n) `(sec ,n)))
        (else #f)))

;; (volumeMount . volume) -> (mount <source> "/path" [#:read-only #t]).
(define (mount-form vm vol)
  (let ((source (cond ((ref vol 'secret 'secretName)              => (lambda (n) `(sec ,n)))
                      ((ref vol 'configMap 'name)                 => (lambda (n) `(cm ,n)))
                      ((ref vol 'persistentVolumeClaim 'claimName) => (lambda (n) `(pvc ,n)))
                      ((ref vol 'hostPath 'path)                  => (lambda (p) `(host-path ,p)))
                      (else #f))))
    (and source (equal? (ref vm 'name) (ref vol 'name))
         `(mount ,source ,(ref vm 'mountPath)
                 ,@(if (ref vm 'readOnly) '(#:read-only #t) '())))))

;; The compact "cpu/mem" spec when `res` parses it back to RESOURCES; else
;; the alist itself, quoted.
(define (resources-field resources)
  (let* ((side (lambda (k) (cons (ref resources 'requests k) (ref resources 'limits k))))
         (cpu  (side 'cpu))
         (mem  (side 'memory))
         (bound (lambda (b single-means-lim?)
                  (match b
                    ((#f . #f) "*")
                    ((r . #f)  (if single-means-lim? (string-append r "-*") r))
                    ((#f . l)  (string-append "*-" l))
                    ((r . l)   (if (and single-means-lim? (equal? r l)) r
                                   (string-append r "-" l))))))
         (spec (let ((c (bound cpu #f)) (m (bound mem #t)))
                 (if (string=? m "*") c (string-append c "/" m)))))
    (if (same-shape? (res spec) resources) spec `',resources)))

;; Candidate construct form for OBJ, or #f when the kind has no construct or
;; the object is structurally out of reach (several containers, an envFrom
;; that isn't a ConfigMap/Secret …). Verified by `lifted` before use.
(define (candidate-form obj)
  (let* ((kind (ref obj 'kind))
         (name (ref obj 'metadata 'name))
         (ns   (ref obj 'metadata 'namespace))
         (namespaced (lambda (forms)          ; the constructs always emit one
                       (and ns `(,@forms (namespace ,ns))))))
    (and
      (string? name)
      (match kind
        ("Namespace"
         `(namespace ,name
            ,@(extra-labels obj '(kubernetes.io/metadata.name))))
        ("ConfigMap"
         (namespaced
           `(configmap ,name
              ,@(let ((d (ref obj 'data))) (if (pair? d) `((data ,@(map-entries d))) '()))
              ,@(extra-labels obj '(app)))))
        ("Secret"
         (namespaced
           `(secret ,name
              ,@(opt 'type (ref obj 'type) "Opaque")
              ,@(let ((d (ref obj 'data)))       (if (pair? d) `((data ,@(map-entries d))) '()))
              ,@(let ((d (ref obj 'stringData))) (if (pair? d) `((string-data ,@(map-entries d))) '()))
              ,@(extra-labels obj '(app)))))
        ("Service"
         (let* ((ports (ref obj 'spec 'ports))
                (p     (and (pair? ports) (null? (cdr ports)) (car ports)))
                (sel   (ref obj 'spec 'selector 'app)))
           (and p sel
                (namespaced
                  `(service ,name
                     (port ,(ref p 'port))
                     ,@(opt 'target-port (ref p 'targetPort) (ref p 'port))
                     ,@(opt 'port-name (ref p 'name) "http")
                     ,@(opt 'type (ref obj 'spec 'type) #f)
                     ,@(opt 'selector-name sel name)
                     ,@(extra-labels obj '(app)))))))
        ("Deployment"
         (let* ((pod    (ref obj 'spec 'template 'spec))
                (cs     (ref pod 'containers))
                (c      (and (pair? cs) (null? (cdr cs)) (car cs)))
                (ports  (ref c 'ports))
                (port   (if (pair? ports) (ref (car ports) 'containerPort) 0))
                (env-from (map env-from-form (or (ref c 'envFrom) '())))
                (mounts (or (ref c 'volumeMounts) '()))
                (vols   (or (ref pod 'volumes) '()))
                (mounts (if (= (length mounts) (length vols))
                            (map mount-form mounts vols)
                            '(#f)))
                (list-field (lambda (key val) (if (pair? val) `((,key ,@val)) '()))))
           (and c (every identity env-from) (every identity mounts)
                (namespaced
                  `(deployment ,name
                     (image ,(ref c 'image))
                     ,@(opt 'port port 8080)
                     ,@(opt 'replicas (ref obj 'spec 'replicas) 1)
                     ,@(opt 'service-account (ref pod 'serviceAccountName) #f)
                     ,@(list-field 'command (ref c 'command))
                     ,@(list-field 'args (ref c 'args))
                     ,@(list-field 'env (map (lambda (e) `',e) (or (ref c 'env) '())))
                     ,@(list-field 'env-from env-from)
                     ,@(list-field 'volumes mounts)
                     ,@(let ((r (ref c 'resources)))
                         (if (pair? r) `((resources ,(resources-field r))) '()))
                     ,@(if (eq? (ref c 'securityContext 'privileged) #t) '((privileged)) '())
                     ,@(extra-labels obj '(app)))))))
        (_ #f)))))

;; Evaluate a construct FORM as an inventory would and return the resource
;; it appends — the ground truth for "fits exactly".
(define (form->resource form)
  (let ((m (make-fresh-user-module)))
    (module-use! m (resolve-interface '(hexol k8s)))
    (let ((op (eval form m)))
      (car (state-get (resolve (list op) '()) '(kubernetes_resources))))))

(define (lifted obj)
  (let ((form (candidate-form obj)))
    (and form
         (same-shape? (form->resource form) obj)
         form)))

(define* (k8s-object->form obj #:key sugar?)
  "The op form for one k8s object alist: its typed construct when SUGAR? and
the construct rebuilds OBJ exactly, else `(resource '<obj>)`."
  (or (and sugar? (lifted obj))
      (resource-form obj)))

;; ---------------------------------------------------------------------------
;; Terraform JSON config -> block forms
;; ---------------------------------------------------------------------------

;; guile-json hands objects back as alists in reverse key order and arrays as
;; vectors. Restore order and make arrays lists; drop nulls (unset).
(define (json->scm v)
  (cond
    ((vector? v) (map json->scm (vector->list v)))
    ((and (pair? v) (every pair? v))
     (filter-map (lambda (e) (and (not (eq? (cdr e) 'null))
                                  (cons (string->symbol (car e)) (json->scm (cdr e)))))
                 (reverse v)))
    (else v)))

;; One `body` entry per attribute: a nested object is a `(block k …)`, a list
;; of scalars `(k (list …))`, anything else a quoted datum.
(define (body-entries alist)
  (map (lambda (e)
         (let ((k (car e)) (v (cdr e)))
           (cond ((object-shape? v) `(block ,k ,@(body-entries v)))
                 ((and (pair? v) (every (lambda (x) (not (pair? x))) v)) `(,k (list ,@v)))
                 ((pair? v) `(,k ',v))
                 (else `(,k ,v)))))
       alist))

;; How many labels each top-level keyword carries in the JSON object model.
(define (label-depth keyword)
  (case keyword
    ((resource data) 2)
    ((provider output variable module) 1)
    (else 0)))

;; The construct for a block: the named macro where (hexol terraform) has
;; one, else the `terraform-block` escape hatch with labels as a list.
(define (block-form keyword labels body)
  (let ((entries (body-entries body)))
    (match (cons keyword labels)
      (('terraform)          `(terraform-settings ,@entries))
      (('provider n)         `(terraform-provider ,n ,@entries))
      (('resource t n)       `(terraform-resource ,t ,n ,@entries))
      (('data t n)           `(terraform-data ,t ,n ,@entries))
      (('output n)           `(terraform-output ,n ,@entries))
      (_ `(terraform-block ,(symbol->string keyword) ',labels ,@entries)))))

;; Walk DEPTH label levels under KEYWORD; a body that is a list (provider
;; aliases, repeated blocks) yields one form per element.
(define (block-forms keyword labels depth v)
  (cond
    ((and (> depth 0) (object-shape? v))
     (append-map (lambda (e)
                   (block-forms keyword (append labels (list (symbol->string (car e))))
                                (1- depth) (cdr e)))
                 v))
    ((object-shape? v) (list (block-form keyword labels v)))
    ((null? v) (list (block-form keyword labels '())))
    ((pair? v) (append-map (lambda (b) (block-forms keyword labels 0 b)) v))
    (else (error "terraform import: unexpected value under" keyword labels))))

(define (terraform-config->forms text)
  "Parse TEXT, a Terraform JSON config, into (hexol terraform) block forms in
source order."
  (let ((config (json->scm (json-string->scm text))))
    (append-map (lambda (e)
                  (block-forms (car e) '() (label-depth (car e)) (cdr e)))
                config)))

;; ---------------------------------------------------------------------------
;; file assembly
;; ---------------------------------------------------------------------------

(define (inventory-text header module forms)
  (call-with-output-string
    (lambda (port)
      (format port ";;; ~a~%~%(use-modules ~s)~%~%(hx-ops~%" header module)
      (let loop ((fs forms))
        (let ((text (call-with-output-string
                      (lambda (p) (pretty-print (car fs) p #:per-line-prefix "  ")))))
          (if (null? (cdr fs))
              (format port "~a)~%" (string-trim-right text))
              (begin (display text port) (newline port) (loop (cdr fs)))))))))

(define* (import-yaml text #:key sugar? (clean? #t) (source "stdin"))
  "Return a hexol inventory file (as a string) equivalent to the k8s manifest
stream TEXT: one op per document, in order.  CLEAN? strips server-populated
fields; SUGAR? lifts objects to typed constructs where they fit exactly."
  (let* ((objs  (append-map unwrap-list (read-yaml-documents text)))
         (objs  (if clean? (map clean-k8s-object objs) objs))
         (forms (map (lambda (o) (k8s-object->form o #:sugar? sugar?)) objs)))
    (when (null? forms) (error "import: no documents in" source))
    (inventory-text (format #f "imported by `hexol import` from ~a — ~a object~p"
                            source (length forms) (length forms))
                    '(hexol k8s) forms)))

(define* (import-terraform-json text #:key (source "stdin"))
  "Return a hexol inventory file (as a string) equivalent to the Terraform
JSON config TEXT: one op per block, in order."
  (let ((forms (terraform-config->forms text)))
    (when (null? forms) (error "import: no blocks in" source))
    (inventory-text (format #f "imported by `hexol import --from terraform` from ~a — ~a block~p"
                            source (length forms) (length forms))
                    '(hexol terraform) forms)))
