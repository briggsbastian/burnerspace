{ config, lib, ... }:
{
  # Sandbox: the guest is treated as hostile. Import this (or a profile built
  # on it, like desktop.nix) and the launcher in flake.nix adds the host half,
  # a network and filesystem jail around QEMU.
  workspace.sandbox = true;

  # No host store share. microvm.nix then builds a read-only store disk that
  # holds only this system's closure, so the guest cannot browse the host's
  # /nix/store and QEMU runs no 9p file server.
  microvm.shares = lib.mkForce [ ];

  microvm.interfaces = lib.mkIf (config.workspace.network == "none") (lib.mkForce [ ]);

  # microvm.nix only gives the machine a PCI bus when it sees a share or
  # `microvm.graphics`; a sandbox has neither, so restate its machine options
  # with pcie=on for the guest agent and any display devices. mem-merge is
  # off so the guest's pages are never deduplicated against other VMs'.
  microvm.qemu.machineOpts = {
    accel = "kvm:tcg";
    acpi = "on";
    mem-merge = "off";
    pcie = "on";
    pic = "off";
    pit = "off";
    rtc = "on";
    usb = "off";
  };

  # Tighten the seccomp filter beyond microvm.nix's plain `-sandbox on`.
  microvm.qemu.extraArgs = [
    "-sandbox" "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"
  ];

  # Nothing the guest prints reaches the launching terminal.
  microvm.qemu.serialConsole = false;
}
