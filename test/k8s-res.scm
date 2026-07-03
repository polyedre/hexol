;;; test/k8s-res.scm — unit tests for the (hexol k8s) `res` parser.
;;; Run: guile -L . test/k8s-res.scm   (or `make test`)
;;;
;;; `res` parses the compact resources spec
;;;   "<cpu-req>-<cpu-lim>/<mem-req>-<mem-lim>"
;;; into a k8s `resources` alist. Conventions under test:
;;;   *          omit that bound entirely
;;;   single mem value   => request == limit (memory clamps by default)
;;;   single cpu value   => request only, NO limit (cpu is left unbounded)
;;;   missing mem side   => treated as "*" (no memory at all)

(add-to-load-path (dirname (dirname (current-filename))))

(use-modules (hexol k8s)
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

(format #t "~%k8s: res — both bounds on both axes~%")
(check "cpu+mem, req+lim each"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (cpu . "500m") (memory . "256Mi")))
       (res "100m-500m/128Mi-256Mi"))

(format #t "~%k8s: res — memory single value clamps (request == limit)~%")
(check "cpu req+lim, mem single -> mem limit mirrors request"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (cpu . "500m") (memory . "128Mi")))
       (res "100m-500m/128Mi"))
(check "cpu req only, mem single"
       '((requests (cpu . "200m") (memory . "256Mi"))
         (limits   (memory . "256Mi")))
       (res "200m/256Mi"))

(format #t "~%k8s: res — single cpu value is a request with NO limit~%")
(check "cpu single -> request only, no cpu limit; mem clamps"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (memory . "128Mi")))
       (res "100m/128Mi"))

(format #t "~%k8s: res — `*` omits a bound~%")
(check "cpu limit omitted with *"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (memory . "256Mi")))
       (res "100m-*/128Mi-256Mi"))
(check "cpu request omitted, only cpu limit"
       '((requests (memory . "128Mi"))
         (limits   (cpu . "500m") (memory . "128Mi")))
       (res "*-500m/128Mi"))
(check "no cpu at all (*/...) -> memory only"
       '((requests (memory . "256Mi"))
         (limits   (memory . "256Mi")))
       (res "*/256Mi"))
(check "cpu only, memory starred -> requests cpu, no limits"
       '((requests (cpu . "100m")))
       (res "100m/*"))
(check "everything starred -> empty resources"
       '()
       (res "*/*"))

(format #t "~%k8s: res — missing memory side defaults to none~%")
(check "no slash -> cpu request only, no memory"
       '((requests (cpu . "100m")))
       (res "100m"))
(check "no slash, cpu req+lim, no memory"
       '((requests (cpu . "100m")) (limits (cpu . "500m")))
       (res "100m-500m"))

(format #t "~%k8s: res — empty token behaves like `*`~%")
(check "empty cpu limit (trailing -) omits cpu limit"
       '((requests (cpu . "100m") (memory . "128Mi"))
         (limits   (memory . "128Mi")))
       (res "100m-/128Mi"))

;; ---------------------------------------------------------------------------
;; resource sugar — render an op and inspect the produced alist
;; ---------------------------------------------------------------------------

(define (render op)
  "Resolve OP alone and return the first resource alist it appends."
  (car (state-get (resolve (list op) '()) '(kubernetes_resources))))

(format #t "~%k8s: deployment — probes / ports / strategy / annotations / emptyDir / grace~%")
(define dep
  (render (deployment "api" (image "i") (port 8080)
            (ports (port "grpc" 9090) (port "metrics" 9797))
            (liveness  (probe 8080 (http "/healthz") (initial-delay 5)))
            (readiness (probe 8080 (tcp)))
            (startup   (probe 0 (exec "sh" "-c" "true")))
            (strategy  (strategy "RollingUpdate" (max-surge "25%") (max-unavailable 0)))
            (annotations (prometheus.io/scrape "true"))
            (termination-grace-period 30)
            (volumes (mount (empty-dir "cache") "/cache")))))
(define c0 (path-get dep '(spec template spec containers 0)))
(check "container ports: single + multi merged"
       '(((containerPort . 8080))
         ((name . "grpc") (containerPort . 9090))
         ((name . "metrics") (containerPort . 9797)))
       (assq-ref c0 'ports))
(check "livenessProbe httpGet + timing"
       '((httpGet (path . "/healthz") (port . 8080)) (initialDelaySeconds . 5))
       (assq-ref c0 'livenessProbe))
(check "readinessProbe tcpSocket" '((tcpSocket (port . 8080))) (assq-ref c0 'readinessProbe))
(check "startupProbe exec" '((exec (command "sh" "-c" "true"))) (assq-ref c0 'startupProbe))
(check "strategy RollingUpdate + rollingUpdate block"
       '((type . "RollingUpdate") (rollingUpdate (maxSurge . "25%") (maxUnavailable . 0)))
       (path-get dep '(spec strategy)))
(check "pod template annotations"
       '((prometheus.io/scrape . "true"))
       (path-get dep '(spec template metadata annotations)))
(check "terminationGracePeriodSeconds" 30
       (path-get dep '(spec template spec terminationGracePeriodSeconds)))
(check "emptyDir volume" '((name . "cache") (emptyDir))
       (path-get dep '(spec template spec volumes 0)))

(format #t "~%k8s: service — multi-port and single-port back-compat~%")
(check "multi-port service"
       '(((name . "http") (port . 80) (targetPort . 8080))
         ((name . "grpc") (port . 9090) (targetPort . 9090)))
       (path-get (render (service "api" (ports (port "http" 80 #:target-port 8080)
                                               (port "grpc" 9090))))
                 '(spec ports)))
(check "single-port service unchanged"
       '(((name . "http") (port . 80) (targetPort . 80)))
       (path-get (render (service "web" (port 80))) '(spec ports)))

(format #t "~%k8s: hpa — autoscaling/v2 with cpu/memory targets~%")
(define h (render (hpa "api" (target "api") (max-replicas 10) (cpu 80) (memory 75))))
(check "hpa apiVersion+kind"
       '("autoscaling/v2" . "HorizontalPodAutoscaler")
       (cons (assq-ref h 'apiVersion) (assq-ref h 'kind)))
(check "hpa spec"
       '((scaleTargetRef (apiVersion . "apps/v1") (kind . "Deployment") (name . "api"))
         (minReplicas . 1) (maxReplicas . 10)
         (metrics ((type . "Resource")
                   (resource (name . "cpu")
                             (target (type . "Utilization") (averageUtilization . 80))))
                  ((type . "Resource")
                   (resource (name . "memory")
                             (target (type . "Utilization") (averageUtilization . 75))))))
       (assq-ref h 'spec))

(format #t "~%k8s: pdb — policy/v1~%")
(define pd (render (pdb "api" (min-available 1))))
(check "pdb apiVersion" "policy/v1" (assq-ref pd 'apiVersion))
(check "pdb spec" '((minAvailable . 1) (selector (matchLabels (app . "api"))))
       (assq-ref pd 'spec))

(format #t "~%k8s: ingress — class + multiple hosts/paths, single back-compat~%")
(define ing (render (ingress "web" (class "nginx")
                      (host-rule "a.com" (service "web") (port 80))
                      (host-rule "b.com" (service "api") (port 8080) (path "/api")))))
(check "ingressClassName" "nginx" (path-get ing '(spec ingressClassName)))
(check "hosts a.com / b.com"
       '("a.com" "b.com")
       (list (path-get ing '(spec rules 0 host)) (path-get ing '(spec rules 1 host))))
(check "second rule path" "/api" (path-get ing '(spec rules 1 http paths 0 path)))
(check "single-host ingress unchanged"
       "web.io"
       (path-get (render (ingress "web" (port 80) (host "web.io"))) '(spec rules 0 host)))

(format #t "~%k8s: label scheme — default app, overridable key~%")
(check "default label key is app"
       '((app . "api"))
       (path-get (render (deployment "api" (image "i"))) '(spec selector matchLabels)))
(check "with-label-key overrides selector + labels"
       '((app.kubernetes.io/name . "api"))
       (path-get (render (with-label-key 'app.kubernetes.io/name (deployment "api" (image "i"))))
                 '(spec selector matchLabels)))

(format #t "~%~a~%"
        (if (zero? failures)
            "all checks passed"
            (format #f "~a failure(s)" failures)))
(exit (if (zero? failures) 0 1))
