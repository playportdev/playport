#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The file operations on the app's container that pymobiledevice3's CLI lacks.
phonelib runs this under pymobiledevice3's own Python (pmd_python) with
USBMUXD_SOCKET_ADDRESS set.

  afc.py BUNDLE_ID rotate-log     move Documents/s1-host.log to s1-host.prev.log
  afc.py BUNDLE_ID put REMOTE     write stdin to REMOTE, whole (not an append)
  afc.py BUNDLE_ID ls REMOTE      one line per entry: its size (- for a directory) and name, a
                                  directory with a trailing /, a link with -> and its target
  afc.py BUNDLE_ID stat REMOTE    "file SIZE", "dir", "link TARGET" or "absent"
  afc.py BUNDLE_ID pull-bundle REMOTE DEST
                                  a bundle directory (a Metal .gputrace) into DEST/<its name>:
                                  its files and subdirectories, and its links as local links,
                                  never followed; one line per file

rotate-log: the app appends every launch to s1-host.log and never trims it, and
every driver pulls the whole file; this renames it in one AFC call, nothing is
copied. Run it only while the app is not running.
"""
import asyncio
import os
import sys

LOG, PREV = "Documents/s1-host.log", "Documents/s1-host.prev.log"


async def main(bundle_id, op, args):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    afc = await HouseArrestService.create(await create_using_usbmux(), bundle_id)
    async with afc:
        if op == "rotate-log":
            if not await afc.exists(LOG):
                print(f"{LOG}: absent")
                return
            size = int((await afc.stat(LOG)).get("st_size", 0))
            if await afc.exists(PREV):
                await afc.rm(PREV)
            await afc.rename(LOG, PREV)
            print(f"{LOG}: {size} bytes moved to {PREV}")
        elif op == "put" and len(args) == 1:
            await afc.set_file_contents(args[0], sys.stdin.buffer.read())
        elif op == "stat" and len(args) == 1:
            print(await kind(afc, args[0]))
        elif op == "pull-bundle" and len(args) == 2:
            if not (await kind(afc, args[0])).startswith("dir"):
                sys.exit(f"{args[0]}: not a directory")
            await pull_tree(afc, args[0].rstrip("/"), os.path.join(args[1], os.path.basename(args[0].rstrip("/"))))
        elif op == "ls" and len(args) == 1:
            if not await afc.exists(args[0]):
                sys.exit(f"{args[0]}: no such file or directory")
            if not (await kind(afc, args[0])).startswith("dir"):
                sys.exit(f"{args[0]}: not a directory")
            for n in sorted(set(await afc.listdir(args[0])) - {".", ".."}):
                k, _, v = (await kind(afc, args[0].rstrip("/") + "/" + n)).partition(" ")
                print({"dir": f"{'-':>12} {n}/", "link": f"{'-':>12} {n} -> {v}"}.get(k, f"{v:>12} {n}"))
        else:
            sys.exit(__doc__)


async def pull_tree(afc, remote, local):
    os.makedirs(local, exist_ok=True)
    for n in sorted(set(await afc.listdir(remote)) - {".", ".."}):
        src, dst = remote + "/" + n, os.path.join(local, n)
        k, _, v = (await kind(afc, src)).partition(" ")
        if os.path.lexists(dst) and not os.path.isdir(dst):
            os.remove(dst)
        if k == "dir":
            await pull_tree(afc, src, dst)
        elif k == "link":
            os.symlink(v, dst)
        elif k == "file":
            with open(dst, "wb") as f:
                f.write(await afc.get_file_contents(src))
            print(f"{v:>12} {dst}", flush=True)


async def kind(afc, path):
    if not await afc.exists(path):
        return "absent"
    st = await afc.stat(path)
    if st.get("st_ifmt") == "S_IFDIR":
        return "dir"
    if st.get("st_ifmt") == "S_IFLNK":   # the prefix's dosdevices (z: is /) are links
        return f"link {st.get('LinkTarget', '?')}"
    return f"file {int(st.get('st_size', 0))}"


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3:]))
