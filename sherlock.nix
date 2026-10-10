{ pkgs, ... }:
{
  # HTB Sherlocks: the sandboxed desktop plus investigation tools.
  imports = [ ./desktop.nix ];

  # Uncomment to cut the workspace off from the network entirely.
  # workspace.network = "none";

  environment.systemPackages = with pkgs; [ ];
}
