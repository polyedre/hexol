.PHONY: help test test-examples build clean

GUILE ?= guile

help:
	@echo "targets:"
	@echo "  make test          run the smoke tests (kernel, surface, res, cmdb)"
	@echo "  make test-examples render the standalone examples, check they exit 0"
	@echo "  make build         compile all modules (surfaces any load/compile error)"
	@echo "  make clean   remove this project's Guile compile cache"
	@echo
	@echo "everything else is the CLI — ./bin/hexol --help:"
	@echo "  ./bin/hexol render [-o sexp|json|yaml|terraform|ansible] [--query K=V,…] [--path P] [-i INVENTORY]"
	@echo "  ./bin/hexol tree [-i INVENTORY]"
	@echo "  ./bin/hexol explain [--query K=V,…] PATH|HASH [-i INVENTORY]"
	@echo "  ./bin/hexol show HASH [-i INVENTORY]"

test:
	$(GUILE) -L . test.scm
	$(GUILE) -L . test/construct.scm
	$(GUILE) -L . test/k8s-res.scm
	$(GUILE) -L . test/cmdb-store.scm
	$(GUILE) -L . test/cmdb-server.scm

test-examples:
	GUILE=$(GUILE) ./test/examples.sh

build:
	@$(GUILE) -L . -c '(begin (use-modules (hexol) (hexol k8s) (hexol terraform) (hexol apply) (hexol ansible) (hexol ledger) (hexol sql) (hexol json)) (display "build ok\n"))'

clean:
	rm -rf ~/.cache/guile/ccache/*$(CURDIR)*
