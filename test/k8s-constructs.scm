;;; test/k8s-constructs.scm — unit tests for the (hexol k8s) resource constructs.
;;; Run: guile -L . test/k8s-constructs.scm   (or `make test`)

(add-to-load-path (dirname (dirname (current-filename))))

(use-modules (hexol)
             (hexol k8s)
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

;; Fold OP and return the kubernetes resources it produced.
(define (rs op) (or (state-get (resolve (list op) '()) '(kubernetes_resources)) '()))
(define (r1 op) (car (rs op)))
(define (at r . path) (fold (lambda (k acc) (and acc (assq-ref acc k))) r path))
(define (pod-spec r) (at r 'spec 'template 'spec))
(define (container r) (car (at r 'spec 'template 'spec 'containers)))

;; ---------------------------------------------------------------------------
(format #t "~%k8s: stateful-set~%")
(define ss (r1 (stateful-set "db" (image "pg:16") (port 5432) (replicas 3)
                             (storage "10Gi") (storage-class "fast")
                             (mount-path "/var/lib/pg"))))
(check "kind"          "StatefulSet" (at ss 'kind))
(check "serviceName defaults to name" "db" (at ss 'spec 'serviceName))
(check "replicas"      3 (at ss 'spec 'replicas))
(check "volumeClaimTemplate generated from (storage …)"
       '(((metadata (name . "data"))
          (spec (accessModes "ReadWriteOnce")
                (storageClassName . "fast")
                (resources (requests (storage . "10Gi"))))))
       (at ss 'spec 'volumeClaimTemplates))
(check "claim is mounted, and is not a pod volume"
       (list '(((name . "data") (mountPath . "/var/lib/pg"))) #f)
       (list (assq-ref (container ss) 'volumeMounts)
             (assq-ref (pod-spec ss) 'volumes)))

(format #t "~%k8s: job / cron-job~%")
(define jb (r1 (job "migrate" (image "t:1") (command "migrate")
                    (ttl-seconds-after-finished 60))))
(check "Job kind/apiVersion" '("batch/v1" "Job") (list (at jb 'apiVersion) (at jb 'kind)))
(check "restartPolicy OnFailure" "OnFailure" (at jb 'spec 'template 'spec 'restartPolicy))
(check "ttlSecondsAfterFinished" 60 (at jb 'spec 'ttlSecondsAfterFinished))

(define cj (r1 (cron-job "rotate" (schedule "0 3 * * *") (image "t:1")
                         (successful-jobs-history 5))))
(check "CronJob schedule" "0 3 * * *" (at cj 'spec 'schedule))
(check "concurrencyPolicy defaults to Forbid" "Forbid" (at cj 'spec 'concurrencyPolicy))
(check "history limits" '(5 1) (list (at cj 'spec 'successfulJobsHistoryLimit)
                                     (at cj 'spec 'failedJobsHistoryLimit)))
(check "jobTemplate carries the pod template" "t:1"
       (assq-ref (car (at cj 'spec 'jobTemplate 'spec 'template 'spec 'containers)) 'image))

(format #t "~%k8s: hpa / pdb~%")
(define hpa (r1 (horizontal-pod-autoscaler "api" (max-replicas 10) (min-replicas 2)
                                           (cpu-utilization 70))))
(check "scaleTargetRef defaults to Deployment NAME"
       '((apiVersion . "apps/v1") (kind . "Deployment") (name . "api"))
       (at hpa 'spec 'scaleTargetRef))
(check "one metric when only cpu is set" 1 (length (at hpa 'spec 'metrics)))
(check "no metrics block when neither utilization is set" #f
       (at (r1 (horizontal-pod-autoscaler "api" (max-replicas 3))) 'spec 'metrics))

(check "pdb minAvailable defaults to 1" 1
       (at (r1 (pod-disruption-budget "api")) 'spec 'minAvailable))
(check "pdb maxUnavailable, and no minAvailable"
       (list "50%" #f)
       (let ((p (r1 (pod-disruption-budget "api" (max-unavailable "50%")))))
         (list (at p 'spec 'maxUnavailable) (at p 'spec 'minAvailable))))

(format #t "~%k8s: network-policy / quota / limit-range~%")
(define np (r1 (network-policy "default-deny" (default-deny))))
(check "default-deny: both policyTypes, no rules"
       (list '("Ingress" "Egress") '() #f #f)
       (list (at np 'spec 'policyTypes) (at np 'spec 'podSelector)
             (at np 'spec 'ingress) (at np 'spec 'egress)))
(check "policyTypes inferred from the rules given"
       '("Egress")
       (at (r1 (network-policy "dns" (egress '((ports . (((port . 53)))))))) 'spec 'policyTypes))
(check "resource-quota hard map"
       '((requests.cpu . "8") (pods . "50"))
       (at (r1 (resource-quota "q" (hard (requests.cpu "8") (pods "50")))) 'spec 'hard))
(check "limit-range limits list"
       '(((type . "Container") (default (cpu . "500m"))))
       (at (r1 (limit-range "lr" (limits '((type . "Container") (default (cpu . "500m"))))))
           'spec 'limits))

(format #t "~%~a~%"
        (if (zero? failures) "all checks passed" (format #f "~a failure(s)" failures)))
(exit (if (zero? failures) 0 1))
