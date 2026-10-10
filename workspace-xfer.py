"""Copy files between the host and a running workspace's /workspace.

Talks to the QEMU guest agent over the qga.sock in the workspace's instance
directory, so it needs no network or SSH inside the guest.
"""

import argparse
import base64
import json
import os
import secrets
import socket
import subprocess
import sys
import time

ROOT = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "disposable-vm",
)
GUEST_ROOT = "/workspace"
GUEST_BIN = "/run/current-system/sw/bin/"
CHUNK = 2 * 1024 * 1024


class Error(Exception):
    pass


class GuestAgent:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        self.sock.connect(path)
        self.file = self.sock.makefile("rwb")
        self._sync()
        self.sock.settimeout(120)

    def _sync(self):
        # Replies to earlier, abandoned requests may still be queued; read
        # until the one matching our id shows up.
        ident = secrets.randbelow(2**31)
        self._send("guest-sync", {"id": ident})
        try:
            while True:
                line = self.file.readline()
                if not line:
                    raise Error("guest agent closed the connection")
                try:
                    if json.loads(line).get("return") == ident:
                        return
                except ValueError:
                    pass
        except socket.timeout:
            raise Error("guest agent is not responding (is the VM still booting?)")

    def _send(self, execute, arguments):
        self.file.write(json.dumps({"execute": execute, "arguments": arguments}).encode() + b"\n")
        self.file.flush()

    def call(self, execute, **arguments):
        self._send(execute, arguments)
        reply = json.loads(self.file.readline())
        if "error" in reply:
            raise Error(f"{execute}: {reply['error'].get('desc', reply['error'])}")
        return reply["return"]

    def run(self, *argv):
        """Run a command in the guest as root and return its stdout."""
        pid = self.call(
            "guest-exec",
            **{"path": GUEST_BIN + argv[0], "arg": list(argv[1:]), "capture-output": True},
        )["pid"]
        while True:
            status = self.call("guest-exec-status", pid=pid)
            if status["exited"]:
                break
            time.sleep(0.1)
        out = base64.b64decode(status.get("out-data", "")).decode(errors="replace")
        if status.get("exitcode") != 0:
            err = base64.b64decode(status.get("err-data", "")).decode(errors="replace")
            raise Error(f"{argv[0]} failed in the guest: {err.strip() or status}")
        return out

    def write_file(self, path, stream):
        handle = self.call("guest-file-open", path=path, mode="wb")
        try:
            while chunk := stream.read(CHUNK):
                while chunk:
                    done = self.call(
                        "guest-file-write",
                        **{"handle": handle, "buf-b64": base64.b64encode(chunk).decode()},
                    )["count"]
                    chunk = chunk[done:]
        finally:
            self.call("guest-file-close", handle=handle)

    def read_file(self, path, stream):
        handle = self.call("guest-file-open", path=path, mode="rb")
        try:
            while True:
                reply = self.call("guest-file-read", handle=handle, count=CHUNK)
                stream.write(base64.b64decode(reply["buf-b64"]))
                if reply["eof"]:
                    break
        finally:
            self.call("guest-file-close", handle=handle)


def running_workspaces():
    found = {}
    if os.path.isdir(ROOT):
        for name in sorted(os.listdir(ROOT)):
            path = os.path.join(ROOT, name, "qga.sock")
            if os.path.exists(path):
                found[name] = path
    return found


def connect(name):
    found = running_workspaces()
    if name is None:
        if len(found) != 1:
            listing = ", ".join(found) or "none"
            raise Error(f"pick a workspace with -w; running: {listing}")
        name = next(iter(found))
    elif name not in found:
        raise Error(f"no running workspace named {name}; running: {', '.join(found) or 'none'}")
    try:
        return GuestAgent(found[name])
    except OSError as e:
        raise Error(f"cannot reach workspace {name}: {e}")


def guest_path(path):
    """Resolve a path relative to /workspace, refusing to leave it."""
    full = os.path.normpath(os.path.join(GUEST_ROOT, path))
    if full != GUEST_ROOT and not full.startswith(GUEST_ROOT + "/"):
        raise Error(f"{path} is outside {GUEST_ROOT}")
    return full


def do_import(agent, args):
    dest = guest_path(args.dest or ".")
    tar_args = []
    for src in args.paths:
        src = os.path.abspath(src)
        if not os.path.lexists(src):
            raise Error(f"{src} does not exist")
        tar_args += ["-C", os.path.dirname(src), os.path.basename(src)]
    names = [os.path.join(dest, os.path.basename(os.path.abspath(p))) for p in args.paths]

    staged = f"{GUEST_ROOT}/.import-{secrets.token_hex(4)}.tar"
    tar = subprocess.Popen(["tar", "-cf", "-"] + tar_args, stdout=subprocess.PIPE)
    try:
        agent.write_file(staged, tar.stdout)
        if tar.wait() != 0:
            raise Error("tar failed on the host")
        agent.run("mkdir", "-p", dest)
        agent.run("tar", "-xf", staged, "-C", dest, "--no-same-owner")
        # Hand the files to whoever owns the workspace (root, or the desktop user).
        owner = agent.run("stat", "-c", "%u:%g", GUEST_ROOT).strip()
        created = [] if dest == GUEST_ROOT else [dest]
        agent.run("chown", "-R", "-h", owner, *names, *created)
    finally:
        tar.kill()
        agent.run("rm", "-f", staged)


def do_export(agent, args):
    dest = os.path.abspath(args.dest or ".")
    os.makedirs(dest, exist_ok=True)
    paths = [os.path.relpath(guest_path(p), GUEST_ROOT) for p in args.paths or ["."]]

    staged = f"{GUEST_ROOT}/.export-{secrets.token_hex(4)}.tar"
    try:
        agent.run(
            "tar", "-cf", staged, "-C", GUEST_ROOT,
            "--exclude=./lost+found", "--exclude=./.export-*.tar", "--exclude=./.import-*.tar",
            *paths,
        )
        tar = subprocess.Popen(["tar", "-xf", "-", "-C", dest, "--no-same-owner"], stdin=subprocess.PIPE)
        try:
            agent.read_file(staged, tar.stdin)
            tar.stdin.close()
            if tar.wait() != 0:
                raise Error("tar failed on the host")
        finally:
            tar.kill()
    finally:
        agent.run("rm", "-f", staged)


def main():
    parser = argparse.ArgumentParser(prog="workspace")
    sub = parser.add_subparsers(dest="command", required=True)
    for name, func, paths_help, dest_help in [
        ("import", do_import, "host files or directories to copy in",
         "directory inside /workspace to copy into (default: /workspace)"),
        ("export", do_export, "paths inside /workspace to copy out (default: everything)",
         "host directory to copy into (default: current directory)"),
    ]:
        p = sub.add_parser(name)
        p.add_argument("-w", "--workspace", help="workspace name, needed when several are running")
        p.add_argument("-d", "--dest", help=dest_help)
        p.add_argument("paths", nargs="+" if name == "import" else "*", help=paths_help)
        p.set_defaults(func=func)
    args = parser.parse_args()
    try:
        args.func(connect(args.workspace), args)
    except Error as e:
        sys.exit(f"workspace {args.command}: {e}")


main()
