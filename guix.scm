(use-modules (guix packages)
             (guix build-system guile)
             (guix licenses)
             (guix gexp)
             (gnu packages guile)
             (gnu packages guile-xyz))

(package
  (name "hexol")
  (version "0.1")
  (source (local-file "." "hexol-source"
                      #:recursive? #t
                      #:select? (lambda (f s)
                                  (and (not (or (string-suffix? ".go" f)
                                               (string-suffix? "~" f)
                                               (string-contains f "/.git/")
                                               (string-contains f "/.venv/")
                                               (string-contains f "/deploy/")
                                               (string-contains f "/examples/")
                                               (string-contains f "/test/")
                                               (string-contains f "/docs/")
                                               (string-contains f "/openrc/")))
                                       (not (member (basename f) '("test.scm" "guix.scm" "Makefile" "README.md" "PONYTAIL-AUDIT.md" "CONTEXT.md")))))))
  (build-system guile-build-system)
  (arguments
   (list
    #:source-directory "."
    #:phases
    #~(modify-phases %standard-phases
        (add-after 'install-documentation 'install-bin
          (lambda* (#:key outputs #:allow-other-keys)
            (let* ((out   (assoc-ref outputs "out"))
                   (bin   (string-append out "/bin"))
                   (site  (string-append out "/share/guile/site/3.0"))
                   (store-script (string-append out "/share/hexol/hexol")))
              ;; keep the real guile script outside bin so the shebang -L . doesn't matter
              (mkdir-p (string-append out "/share/hexol"))
              (copy-file "bin/hexol" store-script)
              (mkdir-p bin)
              (let ((wrapper (string-append bin "/hexol")))
                (call-with-output-file wrapper
                  (lambda (port)
                    (format port "#!/bin/sh\nexec guile -L ~a -e main -s ~a \"$@\"\n"
                            site store-script)))
                (chmod wrapper #o755))))))))
  (propagated-inputs
   (list guile-3.0 guile-json-4 guile-libyaml))
  (home-page "https://github.com/polyedre/hexol")
  (synopsis "Extensible inventory engine")
  (description "Hexol resolves layered inventories into concrete configurations.")
  (license gpl3+))
