{

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm = { url = "github:astro/microvm.nix"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";

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

      mkApp = runner: {
        type = "app";
        program = "${runner}/bin/microvm-run";
      };
    in
    {
      packages.${system} = profiles // { default = profiles.base; };

      apps.${system} = (nixpkgs.lib.mapAttrs (_: mkApp) profiles) // {
        default = mkApp profiles.base;
      };
    };
}

