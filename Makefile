.PHONY: help test test-examples build image image-guix clean

GUILE ?= guile

help:
	@echo "targets:"
	@echo "  make test          run the smoke tests (kernel, surface, res, k8s, import)"
	@echo "  make test-examples render the standalone examples, check they exit 0"
	@echo "  make build         compile all modules (surfaces any load/compile error)"
	@echo "  make image         build the OCI image from Containerfile (podman or docker)"
	@echo "  make image-guix    same via guix pack (no container build needed)"
	@echo "  make clean         remove this project's Guile compile cache"
	@echo
	@echo "everything else is the CLI — ./bin/hexol --help:"
	@echo "  ./bin/hexol render [-o sexp|json|yaml|terraform|ansible] [--query K=V,…] [--path P] [-i INVENTORY]"
	@echo "  ./bin/hexol apply [--only SPEC] [--dry-run] [--list] [-i INVENTORY]"
	@echo "  ./bin/hexol diff [--only SPEC] [--explain] [-i INVENTORY]"
	@echo "  ./bin/hexol tree [-i INVENTORY]"
	@echo "  ./bin/hexol explain [--query K=V,…] PATH|HASH [-i INVENTORY]"
	@echo "  ./bin/hexol show HASH [-i INVENTORY]"
	@echo "  ./bin/hexol lint [-i INVENTORY]"
	@echo "  ./bin/hexol doc [CONSTRUCT] [-i INVENTORY]"
	@echo "  ./bin/hexol import -f FILE|- [--from yaml|terraform] [--sugar] [--no-clean]"
	@echo "  ./bin/hexol --version"

test:
	$(GUILE) -L . test.scm
	$(GUILE) -L . test/construct.scm
	$(GUILE) -L . test/k8s-res.scm
	$(GUILE) -L . test/import.scm
	$(GUILE) -L . test/apply-mode.scm
	GUILE=$(GUILE) ./test/diff-cli.sh

test-examples:
	GUILE=$(GUILE) ./test/examples.sh

build:
	@$(GUILE) -L . -c '(begin (use-modules (hexol) (hexol k8s) (hexol terraform) (hexol apply) (hexol ansible) (hexol ledger) (hexol sql) (hexol json) (hexol lint) (hexol import)) (display "build ok\n"))'

# Prefer podman, fall back to docker. IMAGE is the tag.
IMAGE ?= hexol
OCI ?= $(shell command -v podman || command -v docker)
image:
	$(OCI) build -f Containerfile -t $(IMAGE) .

# Alternative: let Guix assemble the image from guix.scm (bigger image, but no
# source build of guile-libyaml). Loads the tarball into $(OCI).
image-guix:
	$(OCI) load < "$$(guix pack -f docker -S /bin=bin --entry-point=bin/hexol -e '(load "guix.scm")')"

clean:
	rm -rf ~/.cache/guile/ccache/*$(CURDIR)*
