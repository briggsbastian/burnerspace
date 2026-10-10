# disposable_vm

Disposable NixOS workspaces: one command boots a fresh VM, and nothing survives when it exits.

```sh
nix run .#base
```

Built on [microvm.nix](https://github.com/microvm-nix/microvm.nix) with QEMU. Needs Nix with
flakes enabled and access to `/dev/kvm`; no root and no host network setup.

## Profiles

| Command              | What you get                                              | RAM  | vCPUs |
| -------------------- | --------------------------------------------------------- | ---- | ----- |
| `nix run .#base`     | Root shell on the serial console; git, vim, curl, htop    | 3 GB | 2     |
| `nix run .#desktop`  | MATE desktop in a QEMU window, logged in as `user`; Firefox | 4 GB | 4   |

`nix run` on its own starts `base`.

- `base` and `rust` take over the terminal you launch from and log in as root automatically.
- `desktop` opens a window and auto-logs in as `user` (passwordless `sudo`). The launching
  terminal still gets the root serial console.
- Leave any workspace with `poweroff` in the guest. Ctrl-C goes to the guest shell, not QEMU.
- Several workspaces, including several of the same profile, can run at once.

## The workspace disk

Every run gets a private disk mounted at `/workspace`, and interactive shells start there.

- It is a 16 GB sparse ext4 image, so it only uses host space for what you write.
- The guest sees it as a block device; nothing of the host filesystem is exposed through it.
- It is owned by the profile's main user (root, or `user` on `desktop`).
- **It is deleted when the VM exits.** Export anything you want to keep while the VM is running.

Everything outside `/workspace` is RAM-backed and also gone on exit.

## Import and export

These copy files between the host and a *running* workspace.

```sh
nix run .#import -- ./myproject notes.txt      # into /workspace
nix run .#import -- -d deps ./vendor           # into /workspace/deps
nix run .#export                               # all of /workspace into the current directory
nix run .#export -- -d ./out proj/target       # one path, into ./out
```

| Flag                 | `import`                                   | `export`                                  |
| -------------------- | ------------------------------------------ | ----------------------------------------- |
| paths                | host files or directories (required)       | paths inside `/workspace` (default: all)  |
| `-d`, `--dest`       | directory inside `/workspace`              | host directory (default: current)         |
| `-w`, `--workspace`  | which workspace, when several are running  | same                                      |

- With one workspace running, the commands find it on their own. With several, pass
  `-w <name>`; each launcher prints its name at startup, e.g. `workspace: base-rJRIhO`.
- Paths are confined to `/workspace`; something like `../etc/passwd` is refused.
- Imported files are handed to the workspace's owner. Modes and symlinks are preserved both ways.
- Each transfer stages a tar file inside `/workspace`, so it temporarily needs free space equal
  to what is being copied.

## Adding a profile

A profile is a NixOS module layered on `base.nix`. Create the module, then add an entry to
`profiles` in `flake.nix`:

```nix
python = mkWorkspace {
  name = "python";
  mem = 4096;
  vcpu = 4;
  modules = [ ./python.nix ];
};
```

`nix run .#python` then works. Two things to remember:

- New files must be `git add`ed before the flake can see them.
- Do not set `mem = 2048`: QEMU hangs at kernel boot when a microvm has exactly 2 GB
  ([microvm.nix#171](https://github.com/microvm-nix/microvm.nix/issues/171)). Nix prints an
  evaluation warning about it.

## How it works

- **Launcher.** `nix run .#<profile>` runs a small wrapper (`mkLauncher` in `flake.nix`) that
  creates `~/.cache/disposable-vm/<profile>-XXXXXX/`, starts the VM from there, and removes the
  directory on exit. That directory holds `workspace.img`, the QMP control socket
  (`<profile>.sock`) and the guest agent socket (`qga.sock`).
- **Nix store.** The host's `/nix/store` is shared into the guest read-only over 9p, with a
  tmpfs overlay so `nix` works inside the guest. No store image is built, which keeps rebuilds
  fast.
- **Networking.** QEMU user-mode networking: outbound access works, nothing is reachable from
  the host.
- **File transfer.** `workspace-xfer.py` talks to the QEMU guest agent over `qga.sock`, so
  import/export need no SSH or network in the guest.
- **Graphics** (`desktop` only). A virtio GPU shown in a QEMU GTK window.

## Files

| File                | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| `flake.nix`         | Profiles, the per-run launcher, and the `import`/`export` apps |
| `base.nix`          | Shared VM config: hypervisor, store share, workspace disk, guest agent |
| `desktop.nix`       | MATE desktop profile                                           |
| `workspace-xfer.py` | Import/export client                                           |

## Limitations

These are disposable workspaces, not yet hardened sandboxes.

- The guest can read the entire host `/nix/store`, not just what the VM needs.
- The guest has unrestricted outbound network access.
- `export` unpacks a tar produced by the guest onto the host; only export from guests you trust.
- If a launcher is killed hard (`kill -9`, host crash), its directory is left behind in
  `~/.cache/disposable-vm/` and must be deleted by hand.
- x86_64 Linux hosts only.
