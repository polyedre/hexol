# Containerfile — hexol as a small OCI image.
#
# Trade-off: Alpine ships guile 3 + guile-json + jq, but not guile-libyaml
# (nor does Debian), so the first stage builds it from source with nyacc's
# ffi-helper — the same recipe Guix's guile-libyaml package uses. The
# alternative, `guix pack -f docker -m manifest.scm` (see `make image-guix`),
# is a one-liner but needs a Guix install and yields a ~300 MB image; this
# stays plain OCI, builds anywhere podman/docker runs, and lands ~60 MB.
#
#   podman build -t hexol .
#   podman run --rm -v "$PWD:/w" -w /w hexol render -i examples/kubernetes.scm

ARG ALPINE=3.21
ARG NYACC=3.02.0
ARG LIBYAML=3.0.2

FROM alpine:${ALPINE} AS libyaml
ARG NYACC
ARG LIBYAML
RUN apk add --no-cache guile guile-dev gcc musl-dev make pkgconf yaml yaml-dev curl
WORKDIR /src
# nyacc: pure Guile; provides `guild compile-ffi`.
RUN curl -fsSL --retry 5 --retry-all-errors "https://download-mirror.savannah.gnu.org/releases/nyacc/nyacc-${NYACC}.tar.gz" | tar xz \
 && cd "nyacc-${NYACC}" && ./configure --prefix=/usr && make && make install
# guile-libyaml: generate the FFI bindings, compile, install into guile's site dirs.
RUN curl -fsSL --retry 5 --retry-all-errors "https://github.com/mwette/guile-libyaml/archive/refs/tags/V${LIBYAML}.tar.gz" | tar xz \
 && cd "guile-libyaml-${LIBYAML}" \
 && GUILE_AUTO_COMPILE=0 guild compile-ffi --no-exec yaml/libyaml.ffi \
 && sed -i 's| "libyaml"| "/usr/lib/libyaml"|' yaml/libyaml.scm \
 && site=/usr/share/guile/site/3.0 ccache=/usr/lib/guile/3.0/site-ccache \
 && for f in yaml.scm yaml/*.scm; do \
      mkdir -p "$site/$(dirname $f)" "$ccache/$(dirname $f)"; \
      cp "$f" "$site/$f"; \
      guild compile -L . -o "$ccache/${f%.scm}.go" "$f"; \
    done

FROM alpine:${ALPINE}
RUN apk add --no-cache guile guile-json jq yaml make
COPY --from=libyaml /usr/share/guile/site/3.0/ /usr/share/guile/site/3.0/
COPY --from=libyaml /usr/lib/guile/3.0/site-ccache/ /usr/lib/guile/3.0/site-ccache/
COPY . /opt/hexol
WORKDIR /opt/hexol
# Precompile into the image so first run isn't a compile; XDG cache is where
# guile's auto-compiler looks, so point it at a fixed, world-readable dir.
ENV XDG_CACHE_HOME=/opt/hexol/.cache
RUN make build && guile -L . -e main -s bin/hexol --version && chmod -R a+rX /opt/hexol/.cache
# busybox `env` has no -S, so bin/hexol's shebang can't run as-is: invoke guile
# the way the shebang would (same shape as guix.scm's wrapper).
ENTRYPOINT ["guile", "-L", "/opt/hexol", "-e", "main", "-s", "/opt/hexol/bin/hexol"]
CMD ["--help"]
