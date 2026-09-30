#!/usr/bin/env python3
"""Brings Gravity up on the tailnet after a login or restart.

Runs at login and every few minutes (a launchd agent installed by
`install.sh --with-autostart`):

1. waits for Tailscale to have this Mac's address;
2. makes `bind` in ~/.gravity/gravityd.toml loopback plus that address,
   replacing an old Tailscale address if it changed;
3. restarts gravityd (and with it the bots) only if it is not answering on
   that address, and Gravity Lens only if it is not;
4. logs what it did to ~/.gravity-lens/autostart.log.

When everything already answers it changes nothing, so running it often is
harmless. Standard library only.
"""
from __future__ import annotations

import argparse
import ipaddress
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from typing import List, Optional

HOME = os.path.expanduser("~")
TAILNET = ipaddress.ip_network("100.64.0.0/10")
GRAVITYD_LABEL = os.environ.get("GRAVITYD_LABEL", "in.mikolajczuk.gravityd")
LENS_LABEL = os.environ.get("GRAVITY_LENS_LABEL", "gravitios.gravity-lens")


def log(message: str) -> None:
    sys.stderr.write(time.strftime("%Y-%m-%d %H:%M:%S ") + message + "\n")
    sys.stderr.flush()


def tailscale_ip() -> Optional[str]:
    """This Mac's Tailscale IPv4 address, read from its tunnel interface.

    Tailscale's app only acts as a command-line tool in a terminal; under
    launchd it tries to open its window instead, so the interfaces are read
    directly: a utun interface holding an address in 100.64.0.0/10.
    """
    try:
        out = subprocess.run(["/sbin/ifconfig"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    interface = ""
    for line in out.splitlines():
        if line and not line[0].isspace():
            interface = line.split(":", 1)[0]
            continue
        match = re.match(r"\s+inet (\S+)", line)
        if match and interface.startswith("utun"):
            try:
                if ipaddress.ip_address(match.group(1)) in TAILNET:
                    return match.group(1)
            except ValueError:
                continue
    return None


def desired_binds(current: List[str], address: str) -> List[str]:
    """Keeps every non-tailnet address, drops old tailnet ones, adds the current one."""
    keep = []
    for entry in current:
        try:
            if ipaddress.ip_address(entry) in TAILNET:
                continue
        except ValueError:
            pass
        if entry not in keep and entry not in ("0.0.0.0", "::"):
            keep.append(entry)
    if "127.0.0.1" not in keep:
        keep.insert(0, "127.0.0.1")
    return keep + [address]


def update_bind(toml_path: str, address: str) -> bool:
    """Rewrites only the `bind` line. Returns True when the file changed."""
    with open(toml_path) as handle:
        text = handle.read()
    match = re.search(r"^(\s*)bind\s*=\s*\[([^\]]*)\]", text, re.M)
    current = re.findall(r'"([^"]+)"', match.group(2)) if match else ["127.0.0.1"]
    wanted = desired_binds(current, address)
    if wanted == current:
        return False
    line = "bind = [" + ", ".join(f'"{entry}"' for entry in wanted) + "]"
    if match:
        text = text[:match.start()] + match.group(1) + line + text[match.end():]
    else:
        text = line + "\n" + text
    shutil.copy(toml_path, toml_path + ".bak-autostart")
    with open(toml_path + ".tmp", "w") as handle:
        handle.write(text)
    os.replace(toml_path + ".tmp", toml_path)
    log(f"bind: {current} -> {wanted}")
    return True


def trim_log(path: str, limit: int = 256_000) -> None:
    """Keeps the log small: it gets a line every five minutes."""
    try:
        if os.path.getsize(path) > limit:
            with open(path, "rb") as handle:
                handle.seek(-limit // 2, os.SEEK_END)
                tail = handle.read()
            with open(path, "wb") as handle:
                handle.write(tail[tail.find(b"\n") + 1:])
    except OSError:
        pass


def healthy(address: str, port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://{address}:{port}/health", timeout=3) as response:
            return response.status == 200
    except OSError:
        return False


def daemon_port(gravity_home: str) -> int:
    try:
        with open(os.path.join(gravity_home, "gravityd.toml")) as handle:
            match = re.search(r"^\s*port\s*=\s*(\d+)", handle.read(), re.M)
        return int(match.group(1)) if match else 49777
    except OSError:
        return 49777


def kickstart(label: str, restart: bool) -> bool:
    target = f"gui/{os.getuid()}/{label}"
    if subprocess.run(["launchctl", "print", target], capture_output=True).returncode != 0:
        log(f"{label} is not installed as a login agent; skipping")
        return False
    args = ["launchctl", "kickstart"] + (["-k"] if restart else []) + [target]
    result = subprocess.run(args, capture_output=True, text=True)
    log(f"{'restarted' if restart else 'started'} {label}" + (f" ({result.stderr.strip()})" if result.returncode else ""))
    return result.returncode == 0


def wait_until(check, seconds: int) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if check():
            return True
        time.sleep(2)
    return check()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gravity-home", default=os.path.join(HOME, ".gravity"))
    parser.add_argument("--wait", type=int, default=600, help="seconds to wait for Tailscale")
    parser.add_argument("--lens-port", type=int, default=49778)
    parser.add_argument("--dry-run", action="store_true", help="report what would change, change nothing")
    args = parser.parse_args()

    address = None
    deadline = time.time() + args.wait
    while address is None and time.time() < deadline:
        address = tailscale_ip()
        if address is None:
            time.sleep(5)
    if address is None:
        log("Tailscale has no address yet; will try again on the next run")
        return 0

    toml_path = os.path.join(args.gravity_home, "gravityd.toml")
    port = daemon_port(args.gravity_home)
    if args.dry_run:
        with open(toml_path) as handle:
            match = re.search(r"^\s*bind\s*=\s*\[([^\]]*)\]", handle.read(), re.M)
        current = re.findall(r'"([^"]+)"', match.group(1)) if match else []
        log(f"dry run: tailscale {address}; bind {current} -> {desired_binds(current, address)}; "
            f"gravityd on tailnet {'up' if healthy(address, port) else 'DOWN'}; "
            f"lens {'up' if healthy(address, args.lens_port) else 'DOWN'}")
        return 0

    trim_log(os.path.join(HOME, ".gravity-lens", "autostart.log"))
    changed = update_bind(toml_path, address)
    if not changed and healthy(address, port) and healthy(address, args.lens_port):
        log(f"all up on {address}")
        return 0
    if changed or not healthy(address, port):
        # Restarting stops every bot mid-turn, so only when the daemon is not
        # reachable where the phone looks for it.
        running = healthy("127.0.0.1", port)
        kickstart(GRAVITYD_LABEL, restart=running or changed)
        up = wait_until(lambda: healthy(address, port), 60)
        log(f"gravityd on {address}:{port}: {'up' if up else 'still down, see ~/.gravity/logs/gravityd.err.log'}")
    if changed or not healthy(address, args.lens_port):
        kickstart(LENS_LABEL, restart=True)
        up = wait_until(lambda: healthy(address, args.lens_port), 30)
        log(f"Gravity Lens on {address}:{args.lens_port}: {'up' if up else 'still down, see ~/.gravity-lens/lens.log'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
