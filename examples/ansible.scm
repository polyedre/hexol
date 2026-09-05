;;; examples/ansible.scm — provision a small fleet, in Scheme.
;;;
;;; One consumer of (hexol ansible): an inlined inventory, then one play per
;;; host — a list of task declarations, read top to bottom like the playbook
;;; it renders. Render it:
;;;
;;;   hexol render -o ansible -i examples/ansible.scm   # the playbook (JSON)
;;;   hexol tree              -i examples/ansible.scm   # plays -> their tasks
;;;   hexol apply -i examples/ansible.scm --list-tasks --limit web1.acme.example
;;;     writes deploy/{playbook,inventory}.json and runs ansible-playbook on
;;;     them; flags hexol doesn't own pass through (--dry-run = --check --diff).
;;;
;;; A task is `("Name" (module (arg value) …) #:keyword value …)`. Control flow
;;; is the body forms: `each` fans an entry over data, `only` gates it, `as`
;;; scopes `become:`. Any entry with a symbol head is a Scheme expression
;;; whose tasks splice in — so a helper (`apt`, `user-tasks`) drops in where
;;; repetition earns it. What this buys over role YAML, each shown once:
;;;
;;;   • Loops -> explicit named tasks: `each` emits one greppable task per
;;;     package / sysctl / port; `loop:` hides them behind `item.*`.
;;;   • Decisions at render time: an expired user renders `state: absent`
;;;     (no `when:` string); a missing IP aborts *rendering*, not the run.
;;;   • Templates are Scheme strings over cross-host data (/etc/hosts,
;;;     pg_hba.conf) — no Jinja, no `hostvars[item]`.
;;;   • Honest: host-only facts (binary already there?) keep `register:`+`when:`.

(use-modules (hexol ansible)
             (hexol apply)
             (srfi srfi-1))

;; ---------- the fleet ----------

(define inv
  '((hosts
     (web1.acme.example
      (vars (ip (v4 . "10.0.1.11") (v6 . "fd00:acme:1::11"))
            (app_users ((name . "deploy") (groups . "sudo,www-data"))
                       ((name . "alice")  (groups . "www-data") (expires . 1577836800)))))
     (web2.acme.example
      (vars (ip (v4 . "10.0.1.12") (v6 . "fd00:acme:1::12"))
            (app_users ((name . "deploy") (groups . "sudo,www-data")))))
     (db1.acme.example
      (vars (ip (v4 . "10.0.2.21") (v6 . "fd00:acme:2::21"))
            (backup . #t)
            (app_users ((name . "deploy") (groups . "sudo")))))
     (cache1.acme.example
      (vars (ip (v4 . "10.0.3.31"))
            (app_users ((name . "deploy") (groups . "sudo"))))))
    (groups
     (all   (hosts web1.acme.example web2.acme.example db1.acme.example cache1.acme.example)
            (vars (base_packages "vim" "curl" "htop" "rsync" "ca-certificates" "ufw")
                  (timezone . "Etc/UTC")
                  (locale   . "en_US.UTF-8")
                  (sshd (PermitRootLogin . "no")
                        (PasswordAuthentication . "no")
                        (X11Forwarding . "no"))))
     (web   (hosts web1.acme.example web2.acme.example)
            (vars (service . "nginx") (open_ports 80 443)))
     (db    (hosts db1.acme.example)
            (vars (service . "postgresql") (open_ports 5432)))
     (cache (hosts cache1.acme.example)
            (vars (service . "redis") (open_ports 6379))))))

(define sysctls
  '(("net.core.somaxconn"      . "1024")
    ("net.ipv4.tcp_syncookies" . "1")
    ("vm.swappiness"           . "10")))

;; ---------- sugar ----------

;; `(var h 'service)` — host var, falling back through groups to `all`; a path
;; like `'(ip v4)` reads a nested host var.
(define (var h key)
  (if (pair? key) (host-attr h key inv) (effective-host-var h key inv)))

(define (short h) (car (string-split (str h) #\.)))

(define (apt pkg)
  (task (fmt "apt: ~a (present)" pkg) (apt (name pkg) (state "present"))))

(define (svc name)
  (task (fmt "service: ~a -> started" name) (systemd (name name) (state "started") (enabled #t))))

;; ---------- cross-host templates (computed once, from `inv`) ----------

(define etc-hosts
  (string-append
   "# Managed by hexol — do not edit.\n127.0.0.1 localhost\n\n"
   (string-concatenate
    (map (lambda (h)
           (string-concatenate
            (filter-map (lambda (ip) (and ip (fmt "~16a ~a ~a\n" ip h (short h))))
                        (list (var h '(ip v4)) (var h '(ip v6))))))
         (all-hosts inv)))))

(define pg-hba
  (string-append
   "# Managed by hexol.\nlocal   all   all                      peer\n"
   (string-concatenate
    (map (lambda (h) (fmt "host    all   all   ~a/32   scram-sha-256   # ~a\n" (var h '(ip v4)) h))
         (group-hosts 'web inv)))))

(define web-ips (map (lambda (h) (var h '(ip v4))) (group-hosts 'web inv)))

;; ---------- users: render-time state ----------

(define (user-tasks h u)
  (let* ((name  (assq-ref u 'name))
         (exp   (assq-ref u 'expires))
         (state (if (and exp (< exp 1735689600)) "absent" "present")))  ; expired before 2025-01-01
    (tasks
     ((fmt "user ~a -> ~a" name state)
      (user (name name) (state state) (shell "/bin/bash")
            (groups (assq-ref u 'groups)) (append #t)
            (password (fmt "{{ lookup('password', 'secrets/~a/~a') | password_hash('sha512') }}" h name)))
      #:no_log #t)
     (only (string=? state "present")
       ((fmt "~a: .ssh dir" name)
        (file (path (fmt "/home/~a/.ssh" name)) (state "directory")
              (owner name) (group name) (mode "0700")))
       ((fmt "~a: authorized_key" name)
        (ansible.posix.authorized_key (user name) (state "present")
                                      (key (fmt "{{ lookup('file', 'keys/~a.pub') }}" name))))))))

;; ---------- one play per host ----------

(define (host-play h)
  (let ((service (var h 'service))
        (ports   (or (var h 'open_ports) '()))
        (www     (fmt "/var/www/~a" (short h))))
    ;; Render-time guard: a missing IP fails here, not three hosts into the run.
    (unless (var h '(ip v4)) (error "ansible-fleet: host has no ip.v4:" h))
    (play h
      (tasks
       (as root
         ;; -- base --
         (map apt (var h 'base_packages))
         ((fmt "Set hostname ~a" h)          (hostname (name (str h))))
         ((fmt "timezone ~a" (var h 'timezone)) (community.general.timezone (name (var h 'timezone))))
         ((fmt "locale ~a" (var h 'locale))  (community.general.locale_gen (name (var h 'locale)) (state "present")))
         ("Configure /etc/hosts" (copy (dest "/etc/hosts") (content etc-hosts)
                                       (mode "0644") (owner "root") (group "root")))
         (each (kv sysctls)
           ((fmt "sysctl ~a=~a" (car kv) (cdr kv))
            (ansible.posix.sysctl (name (car kv)) (value (cdr kv)) (sysctl_set #t))))
         (each (d (var h 'sshd))
           ((fmt "sshd: ~a ~a" (car d) (cdr d))
            (lineinfile (path "/etc/ssh/sshd_config")
                        (regexp (fmt "^#?~a" (car d)))
                        (line (fmt "~a ~a" (car d) (cdr d))))
            #:notify "Restart sshd"))

         ;; -- users --
         (each (u (or (var h 'app_users) '())) (user-tasks h u))

         ;; -- service --
         (only (equal? service "nginx")
           (apt "nginx")
           ((str www) (file (path www) (state "directory") (owner "www-data") (group "www-data")))
           (as deploy   ; nested become scope: deploy as the unprivileged user
             ("Deploy app (git)" (git (repo "https://git.acme.example/acme/web.git") (dest www) (version "main"))))
           ("nginx vhost"
            (copy (dest "/etc/nginx/sites-enabled/default")
                  (content (fmt "server {\n    listen 80;\n    server_name ~a;\n    root ~a;\n    location / { try_files $uri $uri/ =404; }\n}\n" h www))
                  (mode "0644") (owner "root") (group "root"))
            #:notify "Reload nginx")
           (svc "nginx"))
         (only (equal? service "postgresql")
           (apt "postgresql")
           ("pg_hba.conf"
            (copy (dest "/etc/postgresql/16/main/pg_hba.conf") (content pg-hba)
                  (mode "0640") (owner "postgres") (group "postgres"))
            #:notify "Restart postgresql")
           (svc "postgresql")
           (only (var h 'backup)
             ("cron: nightly pg_dump"
              (cron (name "nightly-backup") (minute "30") (hour "2")
                    (job "pg_dumpall | gzip > /var/backups/pg-$(date +\\%F).sql.gz")
                    (user "postgres")))))
         (only (equal? service "redis")
           (apt "redis-server")
           ("redis maxmemory"
            (copy (dest "/etc/redis/redis.conf.d/maxmemory.conf")
                  (content "maxmemory 256mb\nmaxmemory-policy allkeys-lru\n")
                  (mode "0644") (owner "root") (group "root"))
            #:notify "Restart redis")
           (svc "redis-server"))

         ;; -- firewall --
         ("ufw: default deny incoming" (community.general.ufw (direction "incoming") (policy "deny")))
         ("ufw: allow OpenSSH"         (community.general.ufw (rule "allow") (name "OpenSSH")))
         (each (p ports)
           (only (eqv? p 5432)   ; cross-host: postgres reachable from each web IP only
             (each (ip web-ips)
               ((fmt "ufw: allow postgres from ~a" ip)
                (community.general.ufw (rule "allow") (port "5432") (proto "tcp") (src ip)))))
           (only (not (eqv? p 5432))
             ((fmt "ufw: allow ~a/tcp" p)
              (community.general.ufw (rule "allow") (port (number->string p)) (proto "tcp")))))
         ("ufw: enable" (community.general.ufw (state "enabled")))

         ;; -- node_exporter: honest apply-time logic --
         ("stat node_exporter" (stat (path "/usr/local/bin/node_exporter")) #:register "ne_bin")
         ("Download node_exporter"
          (get_url (url "https://dl.acme.example/node_exporter-1.8.2.tar.gz")
                   (dest "/tmp/node_exporter.tar.gz")
                   (checksum "sha256:0e0e0e0e"))
          #:when "not ne_bin.stat.exists")
         ("Unpack node_exporter"
          (unarchive (src "/tmp/node_exporter.tar.gz") (dest "/usr/local/bin")
                     (remote_src #t) (extra_opts (list "--strip-components=1")))
          #:when "not ne_bin.stat.exists")
         (svc "node_exporter"))

       ;; -- post-checks (unprivileged) --
       ("Check deploy user" (command (cmd "id deploy"))
        #:register "id_deploy" #:changed_when #f #:failed_when #f)
       ("Assert deploy user present"
        (assert (that (list "id_deploy.rc == 0")) (fail_msg "deploy user is missing")))
       (only (pair? ports)
         ((fmt "Wait for port ~a" (car ports))
          (wait_for (host "127.0.0.1") (port (car ports)) (timeout 30)))))

      (as root
        (handlers
         ("Restart sshd"       (service (name "ssh") (state "restarted")))
         ("Reload nginx"       (service (name "nginx") (state "reloaded")))
         ("Restart postgresql" (service (name "postgresql") (state "restarted")))
         ("Restart redis"      (service (name "redis-server") (state "restarted"))))))))

(appliers
  ("ansible" (ansible-applier #:inventory inv)))

(hx-ops (map host-play (all-hosts inv)))
