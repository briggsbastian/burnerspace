{

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm = { url = "github:astro/microvm.nix"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      inherit (nixpkgs) lib;

      mkWorkspace = { name, modules ? [ ], mem ? 3072, vcpu ? 2 }:
        lib.nixosSystem {
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
        };

      profiles = {
        base = mkWorkspace { name = "base"; };
        desktop = mkWorkspace {
          name = "desktop";
          mem = 4096;
          vcpu = 4;
          modules = [ ./desktop.nix ];
        };
        sherlock = mkWorkspace {
          name = "sherlock";
          mem = 4096;
          vcpu = 4;
          modules = [ ./sherlock.nix ];
        };
      };

      # Host half of the sandbox: run the VM so that even a guest that takes
      # over QEMU gets no host files, LAN or host services. Applied to every
      # profile with `workspace.sandbox` set (see sandbox.nix).
      #
      # With network = "public", pasta provides a network namespace whose
      # traffic leaves through the host's sockets; the inner script routes
      # private ranges nowhere and drops into bubblewrap, where nothing has
      # the privileges to undo that. With "none", bubblewrap's own empty
      # network namespace is all there is.
      mkJail = { runner, network }:
        let
          # The host's font setup is not visible inside, so bring one font
          # for the QEMU window's own menus.
          fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };

          # Only the VM's own closure is visible inside, not the host store.
          storeBinds = pkgs.runCommand "jail-store-binds" { } ''
            while read -r path; do
              printf -- '--ro-bind\0%s\0%s\0' "$path" "$path"
            done < ${pkgs.closureInfo { rootPaths = [ runner fontsConf ]; }}/store-paths > $out
          '';

          inner = pkgs.writeShellApplication {
            name = "workspace-jail-inner";
            runtimeInputs = [ pkgs.iproute2 pkgs.bubblewrap pkgs.util-linux ];
            text = ''
              ${lib.optionalString (network == "public") ''
                # Only public addresses are routable; the namespace's own
                # loopback is empty, so QEMU's 10.0.2.2 host alias leads
                # nowhere either.
                for net in 10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 \
                           192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
                  ip route add unreachable "$net"
                done
                ip -6 route add unreachable default 2>/dev/null || true
              ''}
              args=(
                --unshare-user --uid "$JAIL_UID" --gid "$JAIL_GID"
                --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
                ${lib.optionalString (network == "none") "--unshare-net"}
                --die-with-parent --new-session --clearenv
                --args 3
                --proc /proc
                --dev /dev --dev-bind /dev/kvm /dev/kvm
                --tmpfs /tmp
                --bind "$PWD" "$PWD" --chdir "$PWD"
                # The host's resolver may sit on the LAN, which is unreachable.
                --ro-bind ${pkgs.writeText "resolv.conf" "nameserver 9.9.9.9\nnameserver 1.1.1.1\n"} /etc/resolv.conf
                --setenv HOME /tmp
                --setenv PATH ${pkgs.coreutils}/bin
                --setenv FONTCONFIG_FILE ${fontsConf}
              )

              # The QEMU window is the one host resource a graphical VM needs.
              runtime="''${XDG_RUNTIME_DIR:-/run/user/$JAIL_UID}"
              if [ -n "''${WAYLAND_DISPLAY:-}" ] && [ -S "$runtime/$WAYLAND_DISPLAY" ]; then
                args+=(
                  --bind "$runtime/$WAYLAND_DISPLAY" "$runtime/$WAYLAND_DISPLAY"
                  --setenv XDG_RUNTIME_DIR "$runtime"
                  --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
                  --setenv GDK_BACKEND wayland
                )
              elif [ -n "''${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
                echo "warning: no Wayland session; X11 lets a compromised QEMU read host input" >&2
                args+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix --setenv DISPLAY "$DISPLAY")
                if [ -n "''${XAUTHORITY:-}" ]; then
                  args+=(--ro-bind "$XAUTHORITY" /tmp/.Xauthority --setenv XAUTHORITY /tmp/.Xauthority)
                fi
              fi

              # pasta closes inherited descriptors, so take the instance
              # directory's lock again for the VM's lifetime.
              exec 9>>.lock
              flock -s 9

              # No terminal for the jail: stdin is empty, output goes to a
              # log, and the session is new.
              exec bwrap "''${args[@]}" -- ${runner}/bin/microvm-run "$@" \
                3< ${storeBinds} </dev/null >qemu.log 2>&1
            '';
          };
        in
        pkgs.writeShellApplication {
          name = "workspace-jail";
          runtimeInputs = [ pkgs.passt ];
          text = ''
            JAIL_UID=$(id -u) JAIL_GID=$(id -g)
            export JAIL_UID JAIL_GID
            ${if network == "public" then ''
              # Made-up addressing inside the namespace, IPv4 only, no gateway
              # alias for the host and no port forwarding in either direction.
              exec pasta --quiet --config-net -4 -a 10.0.3.2 -n 30 -g 10.0.3.1 \
                --no-map-gw -t none -u none -T none -U none \
                -- ${lib.getExe inner} "$@"
            '' else ''
              exec ${lib.getExe inner} "$@"
            ''}
          '';
        };

      # Run each VM from a private instance directory that holds its
      # workspace image and control socket, and remove it on exit.
      mkLauncher = name: nixos:
        let
          runner = nixos.config.microvm.declaredRunner;
          inherit (nixos.config.workspace) sandbox network;
        in
        pkgs.writeShellApplication {
          name = "workspace-${name}";
          runtimeInputs = [ pkgs.util-linux ];
          text = ''
            root="''${XDG_CACHE_HOME:-$HOME/.cache}/disposable-vm"
            mkdir -p "$root"

            # Every launcher and its VM hold a shared lock in their directory;
            # a lock nobody holds marks a directory left behind by a launcher
            # that was killed.
            for lock in "$root"/*/.lock; do
              [ -e "$lock" ] || continue
              if flock -n -x "$lock" true; then
                rm -rf "$(dirname "$lock")"
              fi
            done

            dir=$(mktemp -d "$root/${name}-XXXXXX")
            trap 'rm -rf "$dir"' EXIT
            cd "$dir"
            exec 9>.lock
            flock -s 9
            echo "workspace: $(basename "$dir")" >&2
            ${if sandbox then ''
              if ! ${lib.getExe (mkJail { inherit runner network; })} "$@"; then
                echo "the VM exited with an error; end of its log:" >&2
                tail -n 20 qemu.log | cat -v >&2
                exit 1
              fi
            '' else ''
              ${runner}/bin/microvm-run "$@"
            ''}
          '';
        };

      launchers = lib.mapAttrs mkLauncher profiles;

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

