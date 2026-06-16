;;; examples/ansible.scm — provision a small fleet, in Scheme.
;;;
;;; One self-contained consumer of (hexol ansible): inlined inventory, one
;;; role, fanned over the fleet (one play per host in `all`) into the
;;; `(ansible_plays)` sink. Render it:
;;;
;;;   hexol render -o ansible examples/ansible.scm   # the playbook (JSON)
;;;   hexol tree              examples/ansible.scm   # plays -> their tasks
;;;
;;; The point: what inventory-as-a-program buys over role YAML. Each item is
;;; plain Scheme here, but a dedicated Ansible feature (or no equivalent) there:
;;;
;;;   • Loops -> explicit named tasks. `(map …)` emits one greppable task per
;;;     package / user / port / peer; `loop:` hides them behind `item.*`.
;;;   • Decisions at render time. Expired user -> state=absent via `cond`, not
;;;     a `when:` string; a missing IP aborts *rendering*, not the run.
;;;   • Templates are Scheme. /etc/hosts, pg_hba.conf built by string fns over
;;;     cross-host data — no Jinja, no `.j2`.
;;;   • Cross-host facts are data. DB firewall opens 5432 per web IP via
;;;     `(group-hosts 'web …)` — no `hostvars[item]`.
;;;   • Sub-roles are functions; `include_tasks:` -> a call. `become:` scope
;;;     is `(as 'user …)`, which nests.
;;;   • Honest: host-only facts (binary already there?) keep `register:`+`when:`.
;;;
;;; Modules: apt, copy, file, lineinfile, cron, systemd, command, stat,
;;; get_url, unarchive, wait_for, assert, git, hostname,
;;; ansible.posix.{sysctl,authorized_key}, community.general.{timezone,
;;; locale_gen,ufw}.

(use-modules (hexol ansible)
             (srfi srfi-1))

;; Alias for joining task lists. (`append` works — surface ops are hx-prefixed
;; and don't shadow it — but `cat` keeps these joins terse.)
(define (cat . lists) (concatenate lists))

;; ---------- the fleet (inlined inventory) ----------
;;
;; Shape the helpers read: hosts carry vars, groups carry membership + group
;; vars, `all` lists every host.

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

;; ---------- thin task sugar ----------

(define* (apt-install pkg #:key (state "present"))
  (task
    (name (fmt "apt: ~a (~a)" pkg state))
    (block ansible.builtin.apt (name pkg) (state state))))

(define* (copy-content name dest content #:key (mode "0644")
                       (owner "root") (group "root") (notify #f))
  (let ((t (task
             (name name)
             (block ansible.builtin.copy
               (dest dest) (content content)
               (mode mode) (owner owner) (group group)))))
    (if notify (cat t (list (cons 'notify notify))) t)))

(define* (svc name #:key (state "started") (enabled #t))
  (task
    (name (fmt "service: ~a -> ~a" name state))
    (block ansible.builtin.systemd
      (name name) (state state) (enabled enabled))))

(define (short-name host-name)
  (car (string-split (str host-name) #\.)))

;; ---------- base: every host ----------

(define sysctls
  '(("net.core.somaxconn"      . "1024")
    ("net.ipv4.tcp_syncookies" . "1")
    ("vm.swappiness"           . "10")))

(define (etc-hosts-content state)
  ;; One map over every host's IPs — Jinja's {% for h in groups['all'] %}
  ;; with nested {% if hostvars[h]... %}.
  (string-append
   "# Managed by hexol — do not edit.\n127.0.0.1 localhost\n\n"
   (string-concatenate
    (map (lambda (h)
           (let ((v4 (host-attr h '(ip v4) state))
                 (v6 (host-attr h '(ip v6) state)))
             ;; ~a coerces the host symbol — no symbol->string needed.
             (string-append
              (if v4 (fmt "~16a ~a ~a\n" v4 h (short-name h)) "")
              (if v6 (fmt "~16a ~a ~a\n" v6 h (short-name h)) ""))))
         (all-hosts state)))))

(define (sshd-directive key val)
  (task
    (name (fmt "sshd: ~a ~a" key val))
    (block ansible.builtin.lineinfile
      (path   "/etc/ssh/sshd_config")
      (regexp (fmt "^#?~a" key))
      (line   (fmt "~a ~a" key val)))
    (notify "Restart sshd")))

(define (base-tasks host-name state)
  (let ((packages (group-var-of 'all 'base_packages state))
        (tz       (group-var-of 'all 'timezone state))
        (locale   (group-var-of 'all 'locale state))
        (sshd     (group-var-of 'all 'sshd state)))
    (as 'root
     (cat
      ;; one named task per base package
      (map apt-install packages)
      (list
       (task (name (fmt "Set hostname ~a" host-name))
             (block ansible.builtin.hostname (name (str host-name))))
       (task (name (fmt "timezone ~a" tz))
             (block community.general.timezone (name tz)))
       (task (name (fmt "locale ~a" locale))
             (block community.general.locale_gen (name locale) (state "present")))
       (copy-content "Configure /etc/hosts" "/etc/hosts" (etc-hosts-content state)))
      ;; one sysctl task per tunable
      (map (lambda (kv)
             (task (name (fmt "sysctl ~a=~a" (car kv) (cdr kv)))
                   (block ansible.posix.sysctl
                     (name (car kv)) (value (cdr kv)) (sysctl_set #t))))
           sysctls)
      ;; sshd hardening: one lineinfile per directive
      (map (lambda (d) (sshd-directive (car d) (cdr d))) sshd)))))

;; ---------- users: loop + render-time-state win ----------

(define epoch-2025 1735689600)  ; 2025-01-01; expiring before this -> removed

(define (user-state u)
  (let ((exp (assq-ref u 'expires)))
    (if (and exp (< exp epoch-2025)) "absent" "present")))

(define (user-account-task host-name u)
  (let ((name   (assq-ref u 'name))
        (groups (assq-ref u 'groups))
        (target (user-state u)))
    (task
      (name (fmt "user ~a -> ~a" name target))
      (block ansible.builtin.user
        (name name) (state target) (shell "/bin/bash")
        (groups groups) (append #t)
        (password (fmt "{{ lookup('password', 'secrets/~a/~a') | password_hash('sha512') }}"
                          host-name name)))
      (no_log #t))))

(define (ssh-dir-task name)
  (task (name (fmt "~a: .ssh dir" name))
        (block ansible.builtin.file
          (path (fmt "/home/~a/.ssh" name)) (state "directory")
          (owner name) (group name) (mode "0700"))))

(define (authkey-task name)
  (task (name (fmt "~a: authorized_key" name))
        (block ansible.posix.authorized_key
          (user name) (state "present")
          (key (fmt "{{ lookup('file', 'keys/~a.pub') }}" name)))))

(define (user-tasks host-name state)
  (let ((users (or (host-attr host-name 'app_users state) '())))
    (as 'root
     (append-map
      (lambda (u)
        (let ((name   (assq-ref u 'name))
              (target (user-state u)))
          ;; present users get .ssh dir + authorized_key
          (cons (user-account-task host-name u)
                (if (string=? target "present")
                    (list (ssh-dir-task name) (authkey-task name))
                    '()))))
      users))))

;; ---------- role-specific tasks (dispatch on service) ----------

(define (nginx-vhost host-name)
  (fmt (string-append "server {\n    listen 80;\n    server_name ~a;\n"
                      "    root /var/www/~a;\n"
                      "    location / { try_files $uri $uri/ =404; }\n}\n")
       host-name (short-name host-name)))

(define (pg-hba-content state)
  ;; Each web node's IPv4 reaches Postgres — cross-host data, one line per
  ;; peer, at render time.
  (string-append
   "# Managed by hexol.\nlocal   all   all                      peer\n"
   (string-concatenate
    (map (lambda (h)
           (let ((ip (host-attr h '(ip v4) state)))
             (if ip (fmt "host    all   all   ~a/32   scram-sha-256   # ~a\n" ip h) "")))
         (group-hosts 'web state)))))

(define (web-tasks host-name state)
  (as 'root
   (cat
    (list
     (apt-install "nginx")
     (task (name (fmt "/var/www/~a" (short-name host-name)))
           (block ansible.builtin.file
             (path (fmt "/var/www/~a" (short-name host-name)))
             (state "directory") (owner "www-data") (group "www-data"))))
    ;; deploy as the unprivileged deploy user — nested become scope (inner
    ;; `as` stamps become_user; outer `as 'root` restores it).
    (as 'deploy
     (list (task (name "Deploy app (git)")
                 (block ansible.builtin.git
                   (repo "https://git.acme.example/acme/web.git")
                   (dest (fmt "/var/www/~a" (short-name host-name)))
                   (version "main")))))
    (list
     (copy-content "nginx vhost" "/etc/nginx/sites-enabled/default"
                   (nginx-vhost host-name) #:notify "Reload nginx")
     (svc "nginx")))))

(define (db-tasks host-name state)
  (as 'root
   (cat
    (list
     (apt-install "postgresql")
     (copy-content "pg_hba.conf" "/etc/postgresql/16/main/pg_hba.conf"
                   (pg-hba-content state) #:mode "0640"
                   #:owner "postgres" #:group "postgres"
                   #:notify "Restart postgresql")
     (svc "postgresql"))
    ;; nightly backup cron only where backup: true
    (if (host-attr host-name 'backup state)
        (list (task (name "cron: nightly pg_dump")
                    (block ansible.builtin.cron
                      (name "nightly-backup") (minute "30") (hour "2")
                      (job  "pg_dumpall | gzip > /var/backups/pg-$(date +\\%F).sql.gz")
                      (user "postgres"))))
        '()))))

(define (cache-tasks host-name state)
  (as 'root
   (list
    (apt-install "redis-server")
    (copy-content "redis maxmemory" "/etc/redis/redis.conf.d/maxmemory.conf"
                  "maxmemory 256mb\nmaxmemory-policy allkeys-lru\n"
                  #:notify "Restart redis")
    (svc "redis-server"))))

(define (service-tasks host-name state)
  (let ((service (effective-host-var host-name 'service state)))
    (cond
      ((equal? service "nginx")      (web-tasks host-name state))
      ((equal? service "postgresql") (db-tasks host-name state))
      ((equal? service "redis")      (cache-tasks host-name state))
      (else '()))))

;; ---------- firewall: one ufw task per exposed port ----------

(define (firewall-tasks host-name state)
  (let ((ports   (or (effective-host-var host-name 'open_ports state) '()))
        (service (effective-host-var host-name 'service state)))
    (as 'root
     (cat
      (list
       (task (name "ufw: default deny incoming")
             (block community.general.ufw (direction "incoming") (policy "deny")))
       (task (name "ufw: allow OpenSSH")
             (block community.general.ufw (rule "allow") (name "OpenSSH"))))
      (append-map
       (lambda (p)
         (if (and (equal? service "postgresql") (eqv? p 5432))
             ;; cross-host: one rule per web IP
             (map (lambda (ip)
                    (task (name (fmt "ufw: allow postgres from ~a" ip))
                          (block community.general.ufw
                            (rule "allow") (port "5432") (proto "tcp") (src ip))))
                  (filter-map (lambda (h) (host-attr h '(ip v4) state))
                              (group-hosts 'web state)))
             (list (task (name (fmt "ufw: allow ~a/tcp" p))
                         (block community.general.ufw
                           (rule "allow") (port (number->string p)) (proto "tcp"))))))
       ports)
      (list
       (task (name "ufw: enable")
             (block community.general.ufw (state "enabled"))))))))

;; ---------- node_exporter: honest apply-time logic ----------

(define (metrics-tasks)
  (as 'root
   (list
    (task (name "stat node_exporter")
          (block ansible.builtin.stat (path "/usr/local/bin/node_exporter"))
          (register "ne_bin"))
    (task (name "Download node_exporter")
          (when "not ne_bin.stat.exists")
          (block ansible.builtin.get_url
            (url "https://dl.acme.example/node_exporter-1.8.2.tar.gz")
            (dest "/tmp/node_exporter.tar.gz")
            (checksum "sha256:0e0e0e0e")))
    (task (name "Unpack node_exporter")
          (when "not ne_bin.stat.exists")
          (block ansible.builtin.unarchive
            (src "/tmp/node_exporter.tar.gz") (dest "/usr/local/bin")
            (remote_src #t) (extra_opts (list "--strip-components=1"))))
    (svc "node_exporter"))))

;; ---------- post-checks: register + assert + wait_for ----------

(define (check-tasks host-name state)
  (let* ((ports (or (effective-host-var host-name 'open_ports state) '()))
         (first-port (and (pair? ports) (car ports))))
    (cat
     (list
      (task (name "Check deploy user")
            (block ansible.builtin.command (cmd "id deploy"))
            (register "id_deploy") (changed_when #f) (failed_when #f))
      (task (name "Assert deploy user present")
            (block ansible.builtin.assert
              (that (list "id_deploy.rc == 0"))
              (fail_msg "deploy user is missing"))))
     (if first-port
         (list (task (name (fmt "Wait for port ~a" first-port))
                     (block ansible.builtin.wait_for
                       (host "127.0.0.1") (port first-port) (timeout 30))))
         '()))))

;; ---------- handlers ----------

(define handlers
  (as 'root
   (list
    (handler (name "Restart sshd")
             (block ansible.builtin.service (name "ssh") (state "restarted")))
    (handler (name "Reload nginx")
             (block ansible.builtin.service (name "nginx") (state "reloaded")))
    (handler (name "Restart postgresql")
             (block ansible.builtin.service (name "postgresql") (state "restarted")))
    (handler (name "Restart redis")
             (block ansible.builtin.service (name "redis-server") (state "restarted"))))))

;; ---------- role entrypoint ----------

(define (role-impl host-name state)
  ;; Render-time guard: catch a missing IP *here*, not three hosts into the run.
  (unless (host-attr host-name '(ip v4) state)
    (error "ansible-fleet: host has no ip.v4:" host-name))
  (cons
   (cat
    (base-tasks     host-name state)
    (user-tasks     host-name state)
    (service-tasks  host-name state)
    (firewall-tasks host-name state)
    (metrics-tasks)
    (check-tasks    host-name state))
   handlers))

;; ---------- assemble: one play per host in `all` ----------
;;
;; Fanning the role over a group is this example's structure, not a library
;; primitive — each `play` keys itself by host, so no isolation needed: just
;; `compose-ops` + `map`, one `play` op per host.

(define (fleet group)
  (compose-ops 'fleet `(fleet ,group)
    (map (lambda (h)
           (let ((rendered (role-impl h inv)))
             (play h (car rendered) (cdr rendered))))
         (group-hosts group inv))))

(hx-ops (fleet 'all))
