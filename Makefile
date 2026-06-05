.PHONY: help test build clean

GUILE ?= guile

help:
	@echo "targets:"
	@echo "  make test    run the smoke tests (kernel, surface, res, cmdb)"
	@echo "  make build   compile all modules (surfaces any load/compile error)"
	@echo "  make clean   remove this project's Guile compile cache"
	@echo
	@echo "everything else is the CLI — ./bin/hexol --help:"
	@echo "  ./bin/hexol render [-o sexp|json|yaml|terraform|ansible] [--query K=V,…] [--path P] INVENTORY"
	@echo "  ./bin/hexol tree|ops INVENTORY"
	@echo "  ./bin/hexol explain [--query K=V,…] PATH INVENTORY"

test:
	$(GUILE) -L . test.scm
	$(GUILE) -L . test/k8s-res.scm
	$(GUILE) -L . test/cmdb-store.scm
	$(GUILE) -L . test/cmdb-server.scm

build:
	@$(GUILE) -L . -c '(begin (use-modules (hexol) (hexol k8s) (hexol terraform) (hexol ansible) (hexol ledger) (hexol sql) (cmdb json)) (display "build ok\n"))'

clean:
	rm -rf ~/.cache/guile/ccache/*$(CURDIR)*
