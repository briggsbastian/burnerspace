{ lib, pkgs, ... }:
{
  microvm = {
    hypervisor = "qemu";

    # User-mode networking: no root, no tap devices, outbound access works.
    interfaces = [{
      type = "user";
      id = "vm-user";
      mac = "02:00:00:00:00:01";
    }];

    # Share the host store read-only instead of copying it into an image.
    # 9p works unprivileged; switch proto to "virtiofs" later for speed.
    shares = [{
      tag = "ro-store";
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      proto = "9p";
      readOnly = true;
    }];

    # Per-run scratch disk: the guest only sees a block device, and the
    # launcher deletes the image when the VM exits. Sparse, so size is a cap.
    volumes = [{
      image = "workspace.img";
      mountPoint = "/workspace";
      size = 16384;
      label = "workspace";
    }];

    # Guest agent channel used by the import/export commands. The socket
    # lives in the per-run instance directory, so no network is involved.
    qemu.extraArgs = [
      "-chardev" "socket,id=qga0,path=qga.sock,server=on,wait=off"
      "-device" "virtio-serial-pci"
      "-device" "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"
    ];

    # Writes to the store inside the guest land on tmpfs and vanish on exit.
    writableStoreOverlay = "/nix/.rw-store";
  };

  # Drop straight into a root shell on the serial console.
  services.getty.autologinUser = "root";
  users.users.root.initialHashedPassword = "";

  services.qemuGuest.enable = true;

  # /workspace is the place to work: owned by the profile's main user, and
  # where interactive shells start.
  systemd.tmpfiles.settings."10-workspace"."/workspace".d = {
    mode = "0755";
    user = lib.mkDefault "root";
    group = "root";
  };
  programs.bash.interactiveShellInit = ''
    [ "$PWD" = "$HOME" ] && cd /workspace
  '';

  environment.systemPackages = with pkgs; [ git vim curl htop ];

  system.stateVersion = "24.11";
}

