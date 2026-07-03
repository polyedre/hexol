;;; examples/oslo-config.scm — bootstrapping a NEW domain target in one file.
;;;
;;; This is the thin layer every hexol user writes for their own domain: a
;;; renderer (registered with `renders-with`) plus a couple of domain
;;; constructs (`define-construct`). Nothing here is in the library — it is
;;; the ~40 lines you stand up on top of the engine to teach it a new output
;;; format and vocabulary. Here that format is OpenStack-style oslo.config
;;; INI, and the vocabulary is a service's config sections.
;;;
;;; hexol/sql.scm and hexol/ledger.scm are exactly this pattern promoted to
;;; library modules; this file keeps it inline so the whole bootstrap is
;;; visible at once. Every CLI view still works, for free:
;;;
;;;   ./bin/hexol render -o ini -i examples/oslo-config.scm   # the INI file
;;;   ./bin/hexol render        -i examples/oslo-config.scm   # resolved state
;;;   ./bin/hexol tree          -i examples/oslo-config.scm   # the op tree
;;;
;;; Numbers and endpoints are made up.

(use-modules (hexol) (hexol construct)
             (srfi srfi-1) (ice-9 format))

;; ---------- the renderer (state -> INI text) ----------
;;
;; Each construct below appends a `(section-name . ((key . value) …))` pair to
;; the `(ini_sections)` accumulator, so resolving the inventory *is* the build.
;; This walks that list and prints each section. Registered as `-o ini`.

(define (ini-value v)
  (cond ((eq? v #t)   "true")
        ((eq? v #f)   "false")
        ((string? v)  v)
        ((symbol? v)  (symbol->string v))
        ((number? v)  (number->string v))
        ((list? v)    (string-join (map ini-value v) ", "))   ; multi-opt values
        (else (format #f "~a" v))))

(define (render-ini state)
  (for-each
   (lambda (section)
     (format #t "[~a]\n" (car section))
     (for-each (lambda (kv) (format #t "~a = ~a\n" (car kv) (ini-value (cdr kv))))
               (cdr section))
     (newline))
   (or (state-get state '(ini_sections)) '())))

(renders-with "ini" render-ini)

;; ---------- domain constructs (define-construct) ----------
;;
;; `config-section`: the generic INI section. `#:open? #t` lets any `(key
;; value)` through into `extra` — an INI section has no fixed key set. Values
;; are evaluated Scheme (typed-constructor rule), so booleans and refs are
;; natural.
(define-construct config-section
  #:head name
  #:open? #t
  #:build (op:append '(ini_sections) (cons name extra) (list 'config-section name)))

;; `keystone-authtoken`: domain *vocabulary* — the `[keystone_authtoken]`
;; block every OpenStack service carries, with the boilerplate defaulted so a
;; caller only states what differs. This is the "service vocabulary" a thin
;; layer adds; `config-section` alone would make you respell it every time.
(define-construct keystone-authtoken
  #:head ()
  #:fields ((auth-url        #:required)
            (username        #:default "nova")
            (password        #:required)
            (project-name    #:default "service")
            (user-domain     #:default "Default")
            (project-domain  #:default "Default"))
  #:build
  (op:append '(ini_sections)
    `(keystone_authtoken
      (auth_url            . ,auth-url)
      (auth_type           . password)
      (username            . ,username)
      (password            . ,password)
      (project_name        . ,project-name)
      (user_domain_name    . ,user-domain)
      (project_domain_name . ,project-domain))
    (list 'keystone-authtoken)))

;; ---------- the inventory: one service's nova.conf ----------

(hx-ops
  (config-section 'DEFAULT
    (transport_url "rabbit://openstack:secret@controller:5672/")
    (my_ip "10.0.0.31")
    (debug #f)
    (enabled_apis (list 'osapi_compute 'metadata)))

  (config-section 'api
    (auth_strategy "keystone"))

  (keystone-authtoken
    (auth-url "https://controller:5000/v3")
    (password "nova-service-password"))

  (config-section 'vnc
    (enabled #t)
    (server_listen "$my_ip")
    (server_proxyclient_address "$my_ip")))
