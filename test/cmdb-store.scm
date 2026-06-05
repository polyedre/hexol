;;; test/cmdb-store.scm — unit tests for the CMDB store + library.

(add-to-load-path (dirname (dirname (current-filename))))

(use-modules (cmdb store)
             (hexol kernel)
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

(define tmp-log
  (string-append "/tmp/cmdb-store-test-"
                 (number->string (getpid)) ".log"))

(when (file-exists? tmp-log) (delete-file tmp-log))

(format #t "~%cmdb/store: append + get~%")
(define c (make-cmdb tmp-log))
(check "fresh state is empty" '() (cmdb-state c))
(check "get on empty"         #f  (cmdb-get c '(regions alpha5)))

(cmdb-append-fact! c '(merge ((regions (alpha5 (attributes (dc . alpha) (geo . eu)))))))
(check "merge writes nested attrs"
       '((dc . alpha) (geo . eu))
       (cmdb-get c '(regions alpha5 attributes)))

(cmdb-append-fact! c '(merge ((apps (api (image (tag . "v1.0.0")))))))
(check "merge writes default app tag"
       "v1.0.0"
       (cmdb-get c '(apps api image tag)))

(cmdb-append-fact! c '(merge ((regions (alpha5 (apps (api (image (tag . "v2.0.0")))))))))
(check "per-region merge overrides at the leaf"
       "v2.0.0"
       (cmdb-get c '(regions alpha5 apps api image tag)))
(check "default unchanged after per-region merge"
       "v1.0.0"
       (cmdb-get c '(apps api image tag)))
(check "sibling attrs survive per-region merge"
       'alpha
       (cmdb-get c '(regions alpha5 attributes dc)))

(format #t "~%cmdb/store: fact log persistence + refold~%")
(check "fact log has 3 entries" 3 (length (cmdb-facts c)))

(define c2 (make-cmdb tmp-log))
(check "refold reproduces region attrs"
       '((dc . alpha) (geo . eu))
       (cmdb-get c2 '(regions alpha5 attributes)))
(check "refold reproduces overridden tag"
       "v2.0.0"
       (cmdb-get c2 '(regions alpha5 apps api image tag)))

(format #t "~%cmdb/store: high-level region + promote ops~%")
(define tmp-log2
  (string-append "/tmp/cmdb-store-test2-" (number->string (getpid)) ".log"))
(when (file-exists? tmp-log2) (delete-file tmp-log2))
(define c3 (make-cmdb tmp-log2))

(cmdb-append-fact!
  c3 '(region alpha5
        ((region . alpha5) (dc . alpha) (geo . eu)
         (hw-profile . gpu-dense) (network-profile . advanced)
         (tier . prod) (sovereignty . none))))

(check "region op renders network from advanced profile"
       'cilium  (cmdb-get c3 '(regions alpha5 network cni)))
(check "region op renders hw from gpu-dense profile"
       8        (cmdb-get c3 '(regions alpha5 hardware gpu count)))
(check "region op renders apps (k8s 1.33 > 1.32.4)"
       "4.11.2" (cmdb-get c3 '(regions alpha5 apps ingress-nginx chart version)))
(check "region op renders geo defaults"
       "Europe/Paris" (cmdb-get c3 '(regions alpha5 locale timezone)))

(cmdb-append-fact!
  c3 '(promote alpha5 (apps ingress-nginx chart version) "4.12.0"))
(check "promote overrides at the leaf"
       "4.12.0" (cmdb-get c3 '(regions alpha5 apps ingress-nginx chart version)))
(check "promote leaves siblings intact"
       'cilium  (cmdb-get c3 '(regions alpha5 network cni)))

;; refold: facts replay should reproduce the same end state
(define c4 (make-cmdb tmp-log2))
(check "refold reproduces region body + promotion"
       "4.12.0" (cmdb-get c4 '(regions alpha5 apps ingress-nginx chart version)))
(check "refold reproduces gpu count"
       8        (cmdb-get c4 '(regions alpha5 hardware gpu count)))
(when (file-exists? tmp-log2) (delete-file tmp-log2))

(format #t "~%cmdb/store: bump-lib (library versioning via fact)~%")
(define tmp-log3
  (string-append "/tmp/cmdb-store-test3-" (number->string (getpid)) ".log"))
(when (file-exists? tmp-log3) (delete-file tmp-log3))
(define c5 (make-cmdb tmp-log3 #:initial-library "v1"))

;; Region added under v1: EU NTP pool is the legacy europe pool.
(cmdb-append-fact!
  c5 '(region alpha5
        ((region . alpha5) (dc . alpha) (geo . eu)
         (hw-profile . standard) (network-profile . basic)
         (tier . prod) (sovereignty . none))))
(check "v1 region: EU ntp pool is europe.pool.ntp.org"
       "europe.pool.ntp.org"
       (cmdb-get c5 '(regions alpha5 ntp pool)))

;; Bump the library mid-log.
(cmdb-append-fact! c5 '(bump-lib "v2"))

;; New region added after the bump: NTP pool is the v2-patched one.
(cmdb-append-fact!
  c5 '(region delta1
        ((region . delta1) (dc . delta) (geo . eu)
         (hw-profile . standard) (network-profile . basic)
         (tier . prod) (sovereignty . none))))
(check "v2 region: EU ntp pool is paris.pool.ntp.org"
       "paris.pool.ntp.org"
       (cmdb-get c5 '(regions delta1 ntp pool)))
(check "v1 region untouched by later library bump"
       "europe.pool.ntp.org"
       (cmdb-get c5 '(regions alpha5 ntp pool)))

;; Refold from scratch: same contemporaneous interpretation.
(define c6 (make-cmdb tmp-log3 #:initial-library "v1"))
(check "refold preserves v1-rendered alpha5"
       "europe.pool.ntp.org"
       (cmdb-get c6 '(regions alpha5 ntp pool)))
(check "refold preserves v2-rendered delta1"
       "paris.pool.ntp.org"
       (cmdb-get c6 '(regions delta1 ntp pool)))

;; NA region rendered under v2 stays unaffected (v2 only patches EU).
(cmdb-append-fact!
  c6 '(region charlie1
        ((region . charlie1) (dc . charlie) (geo . na)
         (hw-profile . standard) (network-profile . basic)
         (tier . prod) (sovereignty . none))))
(check "v2 NA region unaffected by EU patch"
       "north-america.pool.ntp.org"
       (cmdb-get c6 '(regions charlie1 ntp pool)))

(when (file-exists? tmp-log3) (delete-file tmp-log3))

(format #t "~%cmdb/store: error paths~%")
(check "unknown op raises"
       #t
       (catch #t
         (lambda () (cmdb-append-fact! c '(no-such-op 1 2)) #f)
         (lambda _ #t)))

(when (file-exists? tmp-log) (delete-file tmp-log))

(format #t "~%~a~%"
        (if (zero? failures)
            "all cmdb-store checks passed"
            (format #f "~a cmdb-store failure(s)" failures)))
(exit (if (zero? failures) 0 1))
