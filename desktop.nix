{ pkgs, ... }:
{
  # Opens a QEMU GTK window on the host with a virtio GPU (virgl).
  microvm.graphics.enable = true;

  services.xserver = {
    enable = true;
    desktopManager.mate.enable = true;
    displayManager.lightdm.enable = true;
  };

  # Skip the greeter and land directly in the MATE session.
  services.displayManager.autoLogin = {
    enable = true;
    user = "user";
  };

  users.users.user = {
    isNormalUser = true;
    initialHashedPassword = "";
    extraGroups = [ "wheel" "video" ];
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [ firefox ];
}
