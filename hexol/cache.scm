;;; hexol/cache.scm — a render-time cache for expensive fold-time shell-outs.
;;;
;;; Folding is fast except where an op shells out: `helm template` and
;;; `remote-manifest`'s `curl` dominate a render. Their output is a pure
;;; function of pinned inputs (chart+version+values; a versioned URL), so it is
;;; safe to cache the JSON and skip the process on a hit.
;;;
;;; Two levels:
;;;   1. in-process table — templating the same chart twice, or a `tree -v`
;;;      then `render` in one process, pays once;
;;;   2. on-disk bucket under $XDG_CACHE_HOME/hexol — persists across runs, the
;;;      real win (a re-render is instant).
;;;
;;; Invalidation is coarse by design: ONE cache per inventory file, keyed by a
;;; hash of the file's *content*. Edit it and the prefix changes — the render
;;; misses, recomputes, and stale files (same path, old content) are pruned, so
;;; an inventory never keeps more than its current cache. So an unrelated edit
;;; (a replica bump) also invalidates the chart cache — the accepted trade for
;;; not reasoning about which edits touch which chart.
;;;
;;; `current-render-cache' is #f unless the CLI opened one, so a bare library
;;; use (or no writable cache dir) just shells out — caching never changes
;;; results.

(define-module (hexol cache)
  #:use-module (hexol kernel)            ; fnv1a-64 — the op addresser's hash
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 textual-ports)
  #:export (current-render-cache open-render-cache render-cache?
            cached-json))

;; ---------- key hashing ----------
;; A cache key only needs to avoid accidental collisions, not resist attack, so
;; it shares the kernel's FNV-1a/64 op addresser (no crypto/deps).

(define (hex16 str)
  (let ((s (number->string (fnv1a-64 str) 16)))
    (string-append (make-string (max 0 (- 16 (string-length s))) #\0) s)))

;; ---------- the cache handle ----------

;; A render cache: a flat directory, a per-inventory filename PREFIX
;; ("<pathhash>-<contenthash>-"), and an in-process MEM table. Each entry is
;; "<root>/<prefix><keyhash>.json"; the prefix scopes entries to one
;; inventory's current content.
(define-record-type <render-cache>
  (make-render-cache root prefix mem)
  render-cache?
  (root   rc-root)
  (prefix rc-prefix)
  (mem    rc-mem))

(define current-render-cache (make-parameter #f))

(define (cache-root)
  (let ((xdg (getenv "XDG_CACHE_HOME"))
        (home (or (getenv "HOME") ".")))
    (string-append (if (and xdg (not (string-null? xdg))) xdg
                       (string-append home "/.cache"))
                   "/hexol")))

(define (ensure-directory dir)
  ;; mkdir -p: DIR plus missing parents.
  (unless (file-exists? dir)
    (ensure-directory (dirname dir))
    (catch #t (lambda () (mkdir dir)) (lambda _ #t))))   ; tolerate a race

;; Drop files for the same inventory PATH-PREFIX ("<pathhash>-") whose content
;; prefix differs from the live one — so an inventory keeps only its current
;; cache. Best-effort: any IO error leaves files in place.
(define (prune-stale root path-prefix live-prefix)
  (catch #t
    (lambda ()
      (when (file-exists? root)
        (let ((dir (opendir root)))
          (let loop ()
            (let ((name (readdir dir)))
              (unless (eof-object? name)
                (when (and (string-prefix? path-prefix name)
                           (not (string-prefix? live-prefix name)))
                  (catch #t (lambda () (delete-file (string-append root "/" name)))
                         (lambda _ #t)))
                (loop))))
          (closedir dir))))
    (lambda _ #t)))

;; Open (and prune to) the one cache bucket for INV-PATH; reads its content for
;; the invalidation key. Returns a <render-cache>, or #f if the cache dir is
;; unusable — then callers shell out uncached.
(define (open-render-cache inv-path)
  (catch #t
    (lambda ()
      (let* ((content (call-with-input-file inv-path get-string-all))
             (phash   (hex16 inv-path))
             (chash   (hex16 content))
             (root    (cache-root))
             (prefix  (string-append phash "-" chash "-")))
        (ensure-directory root)
        (prune-stale root (string-append phash "-") prefix)
        (make-render-cache root prefix (make-hash-table))))
    (lambda _ #f)))

;; ---------- the lookup ----------

(define (cached-json key thunk)
  "Return the JSON string for KEY, computing it via THUNK only on a miss.
THUNK is the expensive shell-out (it must return a string). With no cache
bound, just calls THUNK. Level 1 is the in-process table; level 2 is the
on-disk bucket. Cache IO failures degrade to recomputation, never an error."
  (let ((c (current-render-cache)))
    (if (not c)
        (thunk)
        (let* ((kh  (hex16 key))
               (mem (rc-mem c))
               (hit (hash-ref mem kh #f)))
          (or hit
              (let ((file (string-append (rc-root c) "/" (rc-prefix c) kh ".json")))
                (cond
                  ;; level 2 hit: read file back into level 1.
                  ((and (file-exists? file)
                        (catch #t (lambda () (call-with-input-file file get-string-all))
                               (lambda _ #f)))
                   => (lambda (s) (hash-set! mem kh s) s))
                  ;; miss: compute, write through both levels (best effort).
                  (else
                   (let ((s (thunk)))
                     (catch #t
                       (lambda () (call-with-output-file file (lambda (p) (put-string p s))))
                       (lambda _ #t))
                     (hash-set! mem kh s)
                     s)))))))))
