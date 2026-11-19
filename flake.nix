{
  description = "tis-clone: mirror the Toyota/Lexus/Scion factory service manual from TIS for offline use";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # What the scripts run, besides each other (setup.sh checks the same list)
      runtimeDeps =
        pkgs:
        let
          # Only the prebuilt "with patched qt" wkhtmltopdf makes PDFs whose links work, and nixpkgs has it
          # for x86_64-darwin but not aarch64-darwin, where the x86_64 one runs under Rosetta 2.
          wkhtmltopdf =
            if pkgs.stdenv.hostPlatform.system == "aarch64-darwin" then
              pkgs.pkgsx86_64Darwin.wkhtmltopdf
            else
              pkgs.wkhtmltopdf;
        in
        {
          python = pkgs.python3.withPackages (ps: [
            ps.requests
            ps.pikepdf
          ]);
          tools = with pkgs; [
            bash
            coreutils
            curl
            findutils
            gawk
            gnugrep
            gnused
            gzip
            which
            wkhtmltopdf
            # Optional: repdf, tis-merge.sh, make-iso.sh and the legacy Ghostscript PDF scripts
            poppler-utils
            pdftk
            rsync
            xorriso
            ghostscript
          ];
        };

      tisClone =
        pkgs:
        let
          deps = runtimeDeps pkgs;
        in
        pkgs.stdenv.mkDerivation {
          pname = "tis-clone";
          version = "0-unstable-" + builtins.substring 0 8 (self.lastModifiedDate or "19700101");

          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./tis-clone
              ./setup.sh
              ./tis-clone.cfg
              ./scripts
              ./website-framework
              ./HOWTO.md
              ./README.md
              ./LICENSE
            ];
          };

          nativeBuildInputs = [ pkgs.makeBinaryWrapper ];

          # Shebangs are set below, to interpreters that also put the tools on PATH
          dontPatchShebangs = true;

          installPhase = ''
            runHook preInstall

            share=$out/share/tis-clone
            mkdir -p $share $out/bin $out/libexec/tis-clone $out/share/doc/tis-clone
            cp -R tis-clone setup.sh tis-clone.cfg scripts website-framework $share/
            cp HOWTO.md README.md LICENSE $out/share/doc/tis-clone/

            # Interpreters for the scripts' shebangs.  Each puts python (with requests and pikepdf), curl,
            # wkhtmltopdf, ... first on PATH, so a script works however it's started: from bin/, from
            # another script, or by the store path tis-clone prints in its messages.  They're compiled
            # wrappers because macOS won't run a script whose #! interpreter is itself a script.
            for i in ${pkgs.bash}/bin/sh ${pkgs.bash}/bin/bash ${deps.python}/bin/python3; do
              makeWrapper $i $out/libexec/tis-clone/$(basename $i) \
                --prefix PATH : ${lib.makeBinPath ([ deps.python ] ++ deps.tools)}
            done
            for f in $share/tis-clone $share/setup.sh $share/scripts/*; do
              sed -i \
                -e "1s|^#!/bin/sh\$|#!$out/libexec/tis-clone/sh|" \
                -e "1s|^#!/bin/bash\$|#!$out/libexec/tis-clone/bash|" \
                -e "1s|^#!/usr/bin/env python3\$|#!$out/libexec/tis-clone/python3|" \
                "$f"
              if head -n1 "$f" | grep -q '^#!' && ! head -n1 "$f" | grep -q "^#!$out/"; then
                echo "$f: no interpreter for $(head -n1 "$f")" >&2
                exit 1
              fi
            done

            # The scripts find each other through BASE and SCRIPT_BASE in ~/.tis/tis-clone.cfg, which points
            # at a checkout (setup.sh writes it).  Here they're this package, whatever the config says, so
            # they're set again right after each place the config is read.
            ${deps.python}/bin/python3 ${./nix/set-base.py} $share $share/tis-clone $share/setup.sh $share/scripts/*

            # setup.sh finds the config template next to itself, so it's a wrapper rather than a link
            makeWrapper $share/setup.sh $out/bin/tis-clone-setup
            # The rest are links, so they name themselves by the name you ran in their messages
            ln -s $share/tis-clone $out/bin/tis-clone
            for f in $share/scripts/*; do
              case "$(basename $f)" in tis-log.sh | tislog.py) continue ;; esac
              [ -x "$f" ] && ln -s "$f" $out/bin/
            done

            runHook postInstall
          '';

          meta = {
            description = "Mirror the Toyota/Lexus/Scion factory service manual from TIS for offline use";
            homepage = "https://github.com/rootflags/tis-clone";
            license = lib.licenses.gpl3Plus;
            mainProgram = "tis-clone";
            platforms = systems;
          };
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        tis-clone = tisClone pkgs;
        default = tis-clone;
      });

      apps = forAllSystems (
        pkgs:
        let
          pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.tis-clone;
          app = bin: description: {
            type = "app";
            program = "${pkg}/bin/${bin}";
            meta.description = description;
          };
        in
        rec {
          tis-clone = app "tis-clone" "Download a vehicle's whole FSM and make it a local website and PDFs";
          default = tis-clone;
          setup = app "tis-clone-setup" "Create or review ~/.tis/tis-clone.cfg";
          login = app "tis-login.sh" "Log in to TIS (with 2FA) and save the session cookies";
          lookup = app "tis-lookup.py" "Find a vehicle's manual codes from its make, model and year";
          serve = app "tis-serve.py" "Serve the downloaded FSM over HTTP for browsing";
          report = app "tis-report.py" "What failed in a download, and the commands that fix it";
          verify = app "tis-verify.py" "Find downloaded files that aren't what they should be";
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          deps = runtimeDeps pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [ deps.python ] ++ deps.tools;
          };
        }
      );

      checks = forAllSystems (
        pkgs:
        let
          deps = runtimeDeps pkgs;
        in
        {
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.tis-clone;
          # There's no test suite; this is the "sh -n / py_compile" check CLAUDE.md describes
          syntax =
            pkgs.runCommand "tis-clone-syntax"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  deps.python
                ];
              }
              ''
                cd ${./.}
                for f in tis-clone setup.sh scripts/*; do
                  case "$(head -n1 "$f")" in
                    "#!/bin/sh") sh -n "$f" ;;
                    "#!/bin/bash") bash -n "$f" ;;
                  esac || exit 1
                done
                python3 -c 'import ast, sys
                for f in sys.argv[1:]:
                    ast.parse(open(f).read(), f)' scripts/*.py
                touch $out
              '';
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
