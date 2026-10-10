{ pkgs, ... }:
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
    }];

    # Writes to the store inside the guest land on tmpfs and vanish on exit.
    writableStoreOverlay = "/nix/.rw-store";
  };

  # Drop straight into a root shell on the serial console.
  services.getty.autologinUser = "root";
  users.users.root.initialHashedPassword = "";

  environment.systemPackages = with pkgs; [ git vim curl htop ];

  system.stateVersion = "24.11";
}

