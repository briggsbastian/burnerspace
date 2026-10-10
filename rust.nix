{ pkgs, ... }:
{
  # A profile is just a NixOS module: add what the task needs.
  environment.systemPackages = with pkgs; [
    rustc
    cargo
    rust-analyzer
    clippy
    gcc
  ];
}

