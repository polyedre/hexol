{
  description = "hexol — extensible inventory engine (Guile)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      site = "share/guile/site/3.0";
      ccache = "lib/guile/3.0/site-ccache";

      # nixpkgs has neither nyacc nor guile-libyaml, so build both here — the
      # same recipe as the Containerfile and Guix's guile-libyaml package.
      nyacc = pkgs: pkgs.stdenv.mkDerivation rec {
        pname = "nyacc";
        version = "3.02.0";
        src = pkgs.fetchurl {
          url = "https://download.savannah.gnu.org/releases/nyacc/nyacc-${version}.tar.gz";
          hash = "sha256-b6TOVTxg+bV7e0+0WHv5z8XkcW3Z5y/RR4bOWL+kEJE=";
        };
        nativeBuildInputs = [ pkgs.guile_3_0 ];
        configureFlags = [ "--prefix=${placeholder "out"}" ];
      };
      guile-libyaml = pkgs: pkgs.stdenv.mkDerivation rec {
        pname = "guile-libyaml";
        version = "3.0.2";
        src = pkgs.fetchurl {
          url = "https://github.com/mwette/guile-libyaml/archive/refs/tags/V${version}.tar.gz";
          hash = "sha256-RQhh72Ic9xT8JEyvKzIlmvPprk03bh3kBCwsv22aWp0=";
        };
        nativeBuildInputs = [ pkgs.guile_3_0 (nyacc pkgs) pkgs.libyaml.dev ];
        buildInputs = [ pkgs.libyaml ];
        GUILE_AUTO_COMPILE = "0";
        buildPhase = ''
          export GUILE_LOAD_PATH=${nyacc pkgs}/${site}
          export GUILE_LOAD_COMPILED_PATH=${nyacc pkgs}/${ccache}
          guild compile-ffi --no-exec yaml/libyaml.ffi
          sed -i 's| "libyaml"| "${pkgs.libyaml}/lib/libyaml"|' yaml/libyaml.scm
          for f in yaml.scm yaml/*.scm; do
            mkdir -p "$out/${ccache}/$(dirname $f)" "$out/${site}/$(dirname $f)"
            guild compile -L . -o "$out/${ccache}/''${f%.scm}.go" "$f"
            cp "$f" "$out/${site}/$f"
          done
        '';
        dontInstall = true;
      };

      # Runtime deps; mirrors manifest.scm (the source of truth).
      deps = pkgs: [ pkgs.guile_3_0 pkgs.guile-json (guile-libyaml pkgs) (nyacc pkgs) pkgs.jq ];
      guileSite = pkgs: pkgs.lib.makeSearchPath site (deps pkgs);
      guileCcache = pkgs: pkgs.lib.makeSearchPath ccache (deps pkgs);
    in {
      packages = forAll (pkgs: rec {
        hexol = pkgs.stdenv.mkDerivation {
          pname = "hexol";
          # Keep in sync with %hexol-version in hexol/version.scm.
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [ pkgs.makeWrapper ] ++ deps pkgs;
          dontConfigure = true;
          dontPatchShebangs = true;   # bin/hexol is run via the wrapper, not its shebang
          GUILE_AUTO_COMPILE = "0";
          # Precompile the modules into a site-ccache so runs don't hit guile's
          # auto-compiler (whose cache dir would be the read-only store).
          buildPhase = ''
            export GUILE_LOAD_PATH=.:${guileSite pkgs}
            export GUILE_LOAD_COMPILED_PATH=${guileCcache pkgs}
            for f in hexol.scm hexol/*.scm; do
              mkdir -p "ccache/$(dirname $f)"
              guild compile -L . -o "ccache/''${f%.scm}.go" "$f"
            done
          '';
          installPhase = ''
            mkdir -p $out/share/hexol $out/${site} $out/lib/guile/3.0 $out/bin
            cp -r bin $out/share/hexol/
            cp -r hexol hexol.scm $out/${site}/
            cp -r ccache $out/${ccache}
            # bin/hexol's shebang uses `-L .`; run it explicitly instead, with
            # the module paths in the environment. GUILE_AUTO_COMPILE=0 keeps
            # guile from trying to cache the script itself under $HOME.
            makeWrapper ${pkgs.guile_3_0}/bin/guile $out/bin/hexol \
              --add-flags "-e main -s $out/share/hexol/bin/hexol" \
              --set GUILE_AUTO_COMPILE 0 \
              --prefix GUILE_LOAD_PATH : "$out/${site}:${guileSite pkgs}" \
              --prefix GUILE_LOAD_COMPILED_PATH : "$out/${ccache}:${guileCcache pkgs}" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.jq ]}
          '';
          meta = with pkgs.lib; {
            description = "Extensible inventory engine";
            homepage = "https://github.com/Polyedre/hexol";
            license = licenses.gpl3Plus;
            mainProgram = "hexol";
          };
        };
        default = hexol;
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell { packages = deps pkgs ++ [ pkgs.gnumake ]; };
      });
    };
}
