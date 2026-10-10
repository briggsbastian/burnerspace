{

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm = { url = "github:astro/microvm.nix"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      mkWorkspace = { name, modules ? [ ], mem ? 3072, vcpu ? 2 }:
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            microvm.nixosModules.microvm
            ./base.nix
            {
              networking.hostName = name;
              microvm.mem = mem;
              microvm.vcpu = vcpu;
            }
          ] ++ modules;
        }).config.microvm.declaredRunner;

      profiles = {
        base = mkWorkspace { name = "base"; };
        rust = mkWorkspace {
          name = "rust";
          mem = 4096;
          vcpu = 4;
          modules = [ ./rust.nix ];
        };
        desktop = mkWorkspace {
          name = "desktop";
          mem = 4096;
          vcpu = 4;
          modules = [ ./desktop.nix ];
        };
      };

      # Run each VM from a private instance directory that holds its
      # workspace image and control socket, and remove it on exit.
      mkLauncher = name: runner:
        pkgs.writeShellApplication {
          name = "workspace-${name}";
          text = ''
            root="''${XDG_CACHE_HOME:-$HOME/.cache}/disposable-vm"
            mkdir -p "$root"
            dir=$(mktemp -d "$root/${name}-XXXXXX")
            trap 'rm -rf "$dir"' EXIT
            cd "$dir"
            echo "workspace: $(basename "$dir")" >&2
            ${runner}/bin/microvm-run "$@"
          '';
        };

      launchers = nixpkgs.lib.mapAttrs mkLauncher profiles;

      # `import` / `export`: copy files to and from a running workspace.
      mkXfer = command:
        pkgs.writeShellApplication {
          name = "workspace-${command}";
          runtimeInputs = [ pkgs.python3 pkgs.gnutar ];
          text = ''
            exec python3 ${./workspace-xfer.py} ${command} "$@"
          '';
        };

      commands = nixpkgs.lib.genAttrs [ "import" "export" ] mkXfer;

      mkApp = launcher: {
        type = "app";
        program = nixpkgs.lib.getExe launcher;
      };
    in
    {
      packages.${system} = launchers // commands // { default = launchers.base; };

      apps.${system} = (nixpkgs.lib.mapAttrs (_: mkApp) (launchers // commands)) // {
        default = mkApp launchers.base;
      };
    };
}

