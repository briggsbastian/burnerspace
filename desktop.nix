{ pkgs, ... }:
{
  # Sandboxed graphical workspace; task profiles import this and add packages.
  imports = [ ./sandbox.nix ];

  # 2D only: `microvm.graphics` would enable virgl.
  boot.kernelModules = [ "drm" "virtio_gpu" ];
  microvm.qemu.extraArgs = [
    "-display" "gtk,gl=off"
    "-device" "virtio-vga"
    "-device" "qemu-xhci"
    "-device" "usb-tablet"
    "-device" "usb-kbd"
  ];

  services.xserver = {
    enable = true;
    desktopManager.mate.enable = true;
    displayManager.lightdm.enable = true;
    resolutions = [{ x = 1024; y = 768; }];
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
  systemd.tmpfiles.settings."10-workspace"."/workspace".d.user = "user";

  environment.systemPackages = with pkgs; [ firefox ];
}
