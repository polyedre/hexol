;;; test.scm — smoke tests. Run: guile -L . test.scm  (or `make test`)

(add-to-load-path (dirname (current-filename)))

(use-modules (hexol kernel)
             (hexol surface)
             (srfi srfi-1)
             (ice-9 format))

(define failures 0)

(define-syntax check
  (syntax-rules ()
    ((_ desc expected actual)
     (let ((e expected) (a actual))
       (if (equal? e a)
           (format #t "  ok   ~a~%" desc)
           (begin
             (set! failures (+ failures 1))
             (format #t "  FAIL ~a~%       expected: ~s~%       got:      ~s~%"
                     desc e a)))))))

(format #t "~%kernel: state helpers~%")
(check "state-get root"      'v   (state-get '((k . v)) '(k)))
(check "state-get nested"    8    (state-get '((nginx (workers . 8))) '(nginx workers)))
(check "state-get missing"   #f   (state-get '() '(k)))
(check "state-get deep miss" #f   (state-get '((a (b . 1))) '(a c)))

(check "state-set fresh"     '((k . v))                     (state-set '() '(k) 'v))
(check "state-set nested"    '((a (b . 1)))                 (state-set '() '(a b) 1))
(check "state-set update"    '((k . 2))                     (state-set '((k . 1)) '(k) 2))
(check "state-set adds key"  '((a . 1) (b . 2))             (state-set '((a . 1)) '(b) 2))

(check "deep-merge add"      '((a . 1) (b . 2))             (deep-merge '((a . 1)) '((b . 2))))
(check "deep-merge override" '((a . 2))                     (deep-merge '((a . 1)) '((a . 2))))
(check "deep-merge nested"
       '((nginx (workers . 8) (user . "nginx")))
       (deep-merge '((nginx (workers . 4) (user . "nginx")))
                   '((nginx (workers . 8)))))

(format #t "~%kernel: ops + resolve (raw constructors)~%")

(define baseline  (op:merge '((nginx (workers . 4))) 'baseline))
(define override  (op:merge '((nginx (workers . 8))) 'override))
(define add-pkg   (op:append '(packages) 'nginx 'add-pkg))
(define web-block
  (op:when (lambda (s) (eq? (state-get s '(attributes role)) 'web))
           (list override add-pkg)
           '(when web)))

(define r1 (resolve (list baseline web-block) '((dc . alpha) (role . web))))
(check "when fires — workers"  8           (state-get r1 '(nginx workers)))
(check "when fires — packages" '(nginx)    (state-get r1 '(packages)))

(define r2 (resolve (list baseline web-block) '((dc . alpha) (role . db))))
(check "when skipped — workers" 4          (state-get r2 '(nginx workers)))
(check "when skipped — no pkg"  #f         (state-get r2 '(packages)))

(format #t "~%kernel: copy / move / delete~%")

(check "state-delete leaf"      '((a . 1))            (state-delete '((a . 1) (b . 2)) '(b)))
(check "state-delete nested"    '((a (c . 2)))        (state-delete '((a (b . 1) (c . 2))) '(a b)))
(check "state-delete missing key (no-op)" '((a . 1))  (state-delete '((a . 1)) '(z)))
(check "state-delete missing path (no-op)" '((a (b . 1)))
       (state-delete '((a (b . 1))) '(a z)))

(format #t "~%surface: macros~%")

(define inv-1
  (hx-ops
    (hx-merge (ssh (port 22)))
    (hx-merge (mirror ($ (string-append "rpm."
                                        (symbol->string (attr 'dc))
                                        ".internal"))))))

(define r3 (resolve inv-1 '((dc . alpha))))
(check "surface: scalar"     22                  (state-get r3 '(ssh port)))
(check "surface: $ computed" "rpm.alpha.internal"  (state-get r3 '(mirror)))

;; hx-append with a computed ($) value defers to fold time (attr/get work),
;; matching hx-merge — the value is read from state during the fold.
(define inv-2
  (hx-ops
    (hx-merge  (base (n 2)))
    (hx-append items ($ (get '(base n))))))
(define r-app (resolve inv-2 '()))
(check "surface: hx-append $ fold-time" '(2) (state-get r-app '(items)))

;; hx-ops / hx-when flatten body slots one level, so a helper procedure that
;; returns a *list* of ops drops straight in (the sub-inventory pattern).
(define (extra-ops) (list (hx-merge (a 1)) (hx-merge (b 2))))
(define inv-3 (hx-ops (hx-when (lambda (s) #t) (extra-ops))))
(define r-flat (resolve inv-3 '()))
(check "surface: hx-when flattens list-returning proc (a)" 1 (state-get r-flat '(a)))
(check "surface: hx-when flattens list-returning proc (b)" 2 (state-get r-flat '(b)))

;; str / fmt: string building inside a computed value, no symbol->string.
(check "surface: str coerces symbol"  "k8s-alpha5" (str "k8s-" 'alpha5))
(check "surface: str coerces number"  "node-3"   (str "node-" 3))
(check "surface: fmt template"        "https://api.alpha5:6443"
       (fmt "https://api.~a:6443" 'alpha5))
(define inv-str
  (hx-ops (hx-merge (host ($ (str "rpm." (attr 'dc) ".internal"))))))
(check "surface: str inside $"  "rpm.alpha.internal"
       (state-get (resolve inv-str '((dc . alpha))) '(host)))

;; hx-when predicate forms all agree: an `attrs` shorthand, a bare expression
;; (evaluated against state with attr/get in scope, the way hx-case's dispatch
;; expr is), and an explicit procedure. The predicate must sit directly in the
;; macro form to defer to fold time — routing it through a proc arg would
;; evaluate attr/get eagerly, exactly as for hx-case.
(define (when-hit s) (state-get s '(hit)))
;; attrs shorthand (yields a procedure, applied to state)
(check "surface: hx-when attrs true"  'yes
       (when-hit (resolve (hx-ops (hx-when (attrs (role web)) (hx-merge (hit yes)))) '((role . web)))))
(check "surface: hx-when attrs false" #f
       (when-hit (resolve (hx-ops (hx-when (attrs (role web)) (hx-merge (hit yes)))) '((role . db)))))
;; bare expression, attr/get read fold state directly
(check "surface: hx-when bare expr true" 'yes
       (when-hit (resolve (hx-ops (hx-when (eq? (attr 'role) 'web) (hx-merge (hit yes)))) '((role . web)))))
(check "surface: hx-when bare get false" #f
       (when-hit (resolve (hx-ops (hx-merge (base (n 5))) (hx-when (> (get '(base n)) 99) (hx-merge (hit yes)))) '())))
(check "surface: hx-when bare get true" 'yes
       (when-hit (resolve (hx-ops (hx-merge (base (n 5))) (hx-when (> (get '(base n)) 1) (hx-merge (hit yes)))) '())))
;; an explicit (lambda (s) …) predicate still works unchanged
(check "surface: hx-when lambda still works" 'yes
       (when-hit (resolve (hx-ops (hx-when (lambda (s) (eq? (state-get s '(attributes role)) 'web))
                                           (hx-merge (hit yes)))) '((role . web)))))

(format #t "~%example inventory: 3-region fleet (single render)~%")

;; One fold renders every region. No per-query attributes; pull each
;; region's sub-tree out of the materialized result.
(define example  (load-inventory-file "examples/inventory.scm"))
(define rendered (resolve example '()))

(define (q region) (state-get rendered (list 'regions region)))

(check "rendered: all regions present" 3
       (length (or (state-get rendered '(regions)) '())))

;; alpha5: EU / gpu-dense / advanced network / prod
(define alpha5 (q 'alpha5))
(check "alpha5 region-derived dc"     'alpha            (state-get alpha5 '(attributes dc)))
(check "alpha5 hw-profile"            'gpu-dense      (state-get alpha5 '(attributes hw-profile)))
(check "alpha5 gpu count"             8               (state-get alpha5 '(hardware gpu count)))
(check "alpha5 cluster-name"          "k8s-alpha5"      (state-get alpha5 '(cluster-name)))
(check "alpha5 api endpoint"          "https://api.alpha5.example.com:6443"
                                                    (state-get alpha5 '(kubernetes api-endpoint)))
(check "alpha5 cni cilium"            'cilium         (state-get alpha5 '(network cni)))
(check "alpha5 region-domain"         "alpha5.alpha.example.com"
                                                    (state-get alpha5 '(network region-domain)))
(check "alpha5 timezone (EU)"         "Europe/Paris"  (state-get alpha5 '(locale timezone)))
(check "alpha5 ntp pool (EU)"         "europe.pool.ntp.org" (state-get alpha5 '(ntp pool)))
(check "alpha5 feature-count"         2               (state-get alpha5 '(provisioning feature-count)))
(check "alpha5 loaded k8s resources"  #t              (pair? (state-get alpha5 '(kubernetes_resources))))

;; bravo1: EU / standard / sovereign / strict
(define bravo1 (q 'bravo1))
(check "bravo1 sovereignty strict"    'strict         (state-get bravo1 '(attributes sovereignty)))
(check "bravo1 cni cilium (sovereign)" 'cilium        (state-get bravo1 '(network cni)))
(check "bravo1 egress-default deny"   'deny           (state-get bravo1 '(network egress-default)))
(check "bravo1 encryption mtls"       'mtls-mandatory (state-get bravo1 '(network encryption)))
(check "bravo1 no gpu (standard hw)"  #f              (state-get bravo1 '(hardware gpu count)))
;; sovereign cross-cut: every loaded k8s resource gets the compliance label
(check "bravo1 k8s resource labelled compliant" "strict"
       (state-get (car (state-get bravo1 '(kubernetes_resources)))
                  '(metadata labels compliance)))

;; charlie6: NA / standard / basic / dev
(define charlie6 (q 'charlie6))
(check "charlie6 dc"                    'charlie            (state-get charlie6 '(attributes dc)))
(check "charlie6 tier dev"             'dev            (state-get charlie6 '(attributes tier)))
(check "charlie6 cni flannel (basic)"  'flannel        (state-get charlie6 '(network cni)))
(check "charlie6 timezone (NA)"        "America/Toronto" (state-get charlie6 '(locale timezone)))
(check "charlie6 no features"          #f              (state-get charlie6 '(provisioning feature-count)))

;; Cross-cutting: alpha5 (gpu + advanced) accrues features; charlie6 (standard +
;; basic) accrues none.
(check "alpha5 has more features than charlie6" #t
       (> (or (state-get alpha5 '(provisioning feature-count)) 0)
          (or (state-get charlie6 '(provisioning feature-count)) 0)))

;; Helm repo registry baseline survives all loads.
(check "global helm repo for jetstack"
       "https://charts.jetstack.io"
       (state-get alpha5 '(helm repos jetstack)))

(format #t "~%kernel: op content hashing~%")
(let* ((leaf-a  (make-op 'merge '(set foo) identity "set foo"))
       (leaf-a2 (make-op 'merge '(set foo) identity "set foo"))
       (leaf-b  (make-op 'merge '(set bar) identity "set bar"))
       (parent  (make-op 'group '(group) identity #f (list leaf-a leaf-b)))
       (parent2 (make-op 'group '(group) identity #f (list leaf-a leaf-b)))
       (parent-reordered (make-op 'group '(group) identity #f (list leaf-b leaf-a))))
  (check "op-hash deterministic" (op-content-hash leaf-a) (op-content-hash leaf-a2))
  (check "op-hash is 16 hex chars" 16 (string-length (op-content-hash leaf-a)))
  (check "op-short-hash default width" 8 (string-length (op-short-hash leaf-a)))
  (check "op-short-hash is a prefix of the full hash" #t
         (string-prefix? (op-short-hash leaf-a) (op-content-hash leaf-a)))
  (check "op-hash differs by source/label" #t
         (not (string=? (op-content-hash leaf-a) (op-content-hash leaf-b))))
  (check "op-hash is Merkle: child order changes parent" #t
         (not (string=? (op-content-hash parent) (op-content-hash parent-reordered))))
  (check "op-hash stable across identical trees"
         (op-content-hash parent) (op-content-hash parent2))
  ;; The hash names what an op does, not where it was written: two ops with
  ;; identical content but different source locations hash the same.
  (check "op-hash ignores source location" #t
         (string=?
          (op-content-hash
           (parameterize ((current-author-loc '("a.scm" . 1)))
             (make-op 'merge '(set foo) identity "set foo")))
          (op-content-hash
           (parameterize ((current-author-loc '("b.scm" . 99)))
             (make-op 'merge '(set foo) identity "set foo"))))))

(format #t "~%~a~%"
        (if (zero? failures)
            "all checks passed"
            (format #f "~a failure(s)" failures)))
(exit (if (zero? failures) 0 1))
