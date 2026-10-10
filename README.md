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
| `nix run .#desktop`  | MATE desktop in a 1024x768 QEMU window, logged in as `user`; Firefox | 4 GB | 4 |
| `nix run .#sherlock` | `desktop` plus tools for HTB Sherlocks                    | 4 GB | 4     |

`nix run` on its own starts `base`.

- `base` takes over the terminal you launch from and logs in as root automatically.
- `desktop` opens a window and auto-logs in as `user` (passwordless `sudo`). It and the
  profiles built on it are sandboxed (see [The sandbox](#the-sandbox)) and have no serial console.
- Leave any workspace with `poweroff` in the guest. Ctrl-C goes to the guest shell, not QEMU.
  For a desktop, shut down from the MATE menu or close the window.
- Several workspaces, including several of the same profile, can run at once.

## The workspace disk

Every run gets a private disk mounted at `/workspace`, and interactive shells start there.

- It is a 16 GB sparse ext4 image, so it only uses host space for what you write.
- The guest sees it as a block device; nothing of the host filesystem is exposed through it.
- It is owned by the profile's main user (root, or `user` on `desktop`).
- **It is deleted when the VM exits.** Export anything you want to keep while the VM is running.

Everything outside `/workspace` is RAM-backed and also gone on exit.

## The sandbox

Profiles that import `sandbox.nix` treat the guest as hostile; `desktop` does, and so does
anything built on it. Two layers do the work: the VM gives the guest as little as possible, and
QEMU itself runs in a jail in case the guest breaks out of the VM.

| Host resource      | What the guest gets                                                     |
| ------------------ | ----------------------------------------------------------------------- |
| `/nix/store`       | A read-only disk image holding only the VM's own closure                |
| Internet           | Outbound IPv4 to public addresses, or nothing (see below)               |
| LAN, host services | Nothing: private, link-local and multicast ranges are unroutable, and the host's loopback is not reachable through `10.0.2.2` |
| GPU                | Nothing: a 2D virtio display, with rendering done in software in the guest |
| Launching terminal | Nothing: no serial console; QEMU's output goes to `qemu.log` in the instance directory |

The QEMU process runs under [pasta](https://passt.top/) and bubblewrap with:

- its own user, PID, IPC, UTS and network namespaces, and no capabilities;
- a filesystem of the VM's own store closure (read-only), its instance directory, `/dev/kvm`
  and the Wayland socket for its window, with no home directory, D-Bus or other devices;
- QEMU's seccomp filter with process spawning and privilege changes denied.

None of this needs root. Things to know:

- `workspace.network` picks what the guest can reach: `"public"` (the default) is the internet
  but not the LAN or the host; `"none"` gives the guest no network interface at all and QEMU an
  empty network namespace. Use `"none"` when running samples.
- Changing a profile rebuilds its store image (about 3 GB), so rebuilds are slower than `base`.
- DNS goes to 9.9.9.9 rather than the host's resolver, which may be on the LAN.
- No GPU acceleration, so video and WebGL are slow.
- The desktop starts at 1024x768 (4:3). To change it, edit
  `services.xserver.resolutions` in `desktop.nix`.
- There is no shared clipboard. Use `import` and `export` to move things across.
- On an X11 host the jail has to be given the X socket, which lets a compromised QEMU read
  host input; the launcher warns about this. Wayland does not have the problem.

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
| `--overwrite`        |                                            | replace existing host files               |

- With one workspace running, the commands find it on their own. With several, pass
  `-w <name>`; each launcher prints its name at startup, e.g. `workspace: base-rJRIhO`.
- Paths are confined to `/workspace`; something like `../etc/passwd` is refused.
- Imported files are handed to the workspace's owner. Modes and symlinks are preserved both ways.
- Each transfer stages a tar file inside `/workspace`, so it temporarily needs free space equal
  to what is being copied. `export` also spools it in the destination directory.
- `export` does not trust the guest. It refuses the whole archive if any entry would land
  outside the destination (absolute symlinks, `..`, links pointing out) or is a device, strips
  setuid bits, and will not replace an existing host file unless you pass `--overwrite`.

## Adding a profile

A profile is a NixOS module layered on `base.nix`. For a sandboxed desktop scoped to one task,
import `desktop.nix` and add packages:

```nix
# malware.nix
{ pkgs, ... }:
{
  imports = [ ./desktop.nix ];
  workspace.network = "none";
  environment.systemPackages = with pkgs; [ ghidra yara ];
}
```

Then add an entry to `profiles` in `flake.nix`:

```nix
malware = mkWorkspace {
  name = "malware";
  mem = 8192;
  vcpu = 4;
  modules = [ ./malware.nix ];
};
```

`nix run .#malware` then works. Things to remember:

- The jail follows the module: importing `sandbox.nix`, directly or through `desktop.nix`,
  is what sandboxes a profile. A profile that imports neither is a trusted workspace like `base`.
- For a sandboxed profile without a desktop, import `sandbox.nix` alone. It has no console, so
  it is only reachable through `import`/`export`.
- New files must be `git add`ed before the flake can see them.
- Do not set `mem = 2048`: QEMU hangs at kernel boot when a microvm has exactly 2 GB
  ([microvm.nix#171](https://github.com/microvm-nix/microvm.nix/issues/171)). Nix prints an
  evaluation warning about it.

## How it works

- **Launcher.** `nix run .#<profile>` runs a small wrapper (`mkLauncher` in `flake.nix`) that
  creates `~/.cache/disposable-vm/<profile>-XXXXXX/`, starts the VM from there, and removes the
  directory on exit. It also removes directories left by launchers that were killed. That directory holds `workspace.img`, the QMP control socket
  (`<profile>.sock`) and the guest agent socket (`qga.sock`).
- **Nix store.** The host's `/nix/store` is shared into the guest read-only over 9p, with a
  tmpfs overlay so `nix` works inside the guest. No store image is built, which keeps rebuilds
  fast. Sandboxed profiles get a store image instead.
- **Networking.** QEMU user-mode networking: outbound access works, nothing is reachable from
  the host. For sandboxed profiles, QEMU sits in a pasta network namespace that only routes to
  public addresses.
- **Jail** (sandboxed profiles). `mkJail` in `flake.nix` wraps the VM in pasta and bubblewrap.
- **File transfer.** `workspace-xfer.py` talks to the QEMU guest agent over `qga.sock`, so
  import/export need no SSH or network in the guest.
- **Graphics** (desktops only). A 2D virtio GPU shown in a QEMU GTK window.

## Files

| File                | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| `flake.nix`         | Profiles, the per-run launcher, the jail, and the `import`/`export` apps |
| `base.nix`          | Shared VM config: hypervisor, store share, workspace disk, guest agent |
| `sandbox.nix`       | Hostile-guest VM settings; switches on the jail                |
| `desktop.nix`       | Sandboxed MATE desktop profile, the base for task profiles     |
| `sherlock.nix`      | Desktop for HTB Sherlocks                                      |
| `workspace-xfer.py` | Import/export client                                           |

## Limitations

Only profiles that import `sandbox.nix` are sandboxes; `base` is a disposable workspace for
code you trust.

- In `base`, the guest can read the entire host `/nix/store`, reach the LAN and the host's
  loopback services, and QEMU runs unconfined as your user.
- With `workspace.network = "public"`, a sandboxed guest still has unrestricted access to the
  public internet, so nothing stops data it holds from being sent out.
- A guest that escapes QEMU lands in the jail, where it can still talk to the Wayland
  compositor.
- Exported files are only made safe to unpack. Their contents are still whatever the guest put
  there, so treat them as you would any download.
- If a launcher is killed hard (`kill -9`, host crash), its directory stays in
  `~/.cache/disposable-vm/` until the next launch cleans it up. With `"public"` networking the
  VM itself may keep running until you close its window.
- x86_64 Linux hosts only.
