#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The file operations on the app's container that pymobiledevice3's CLI lacks.
phonelib runs this under pymobiledevice3's own Python (pmd_python) with
USBMUXD_SOCKET_ADDRESS set.

  afc.py BUNDLE_ID rotate-log     move Documents/s1-host.log to s1-host.prev.log
  afc.py BUNDLE_ID put REMOTE     write stdin to REMOTE, whole (not an append)
  afc.py BUNDLE_ID put-import REMOTE
                                  write stdin to Documents/Import/NAME/FILE, the app's import
                                  inbox (what a person fills with Files), making NAME if it is
                                  missing; nothing else (import_refusal)
  afc.py BUNDLE_ID ls REMOTE      one line per entry: its size (- for a directory) and name, a
                                  directory with a trailing /, a link with -> and its target
  afc.py BUNDLE_ID rm REMOTE      delete one .zip file directly in Documents/ (what import: takes; a
                                  file a person or a probe put there). Nothing else: no directory, no
                                  other name, none of the app's own files
  afc.py BUNDLE_ID stat REMOTE    "file SIZE", "dir", "link TARGET" or "absent"
  afc.py BUNDLE_ID pull REMOTE LOCAL
                                  one plain file to the path LOCAL, in PULL_CHUNK reads: a
                                  dropped connection is reopened and the read resumes at its
                                  offset (pull_file); LOCAL appears only whole. Prints its size
  afc.py BUNDLE_ID pull-bundle REMOTE DEST
                                  a bundle directory (a Metal .gputrace) into DEST/<its name>:
                                  its files and subdirectories, and its links as local links,
                                  never followed; one line per file. PULL_CONNECTIONS AFC
                                  connections at once (pull_tree), each file in PULL_CHUNK
                                  reads; a file already in DEST at its size is kept, so a
                                  stopped pull resumes where it was
  afc.py BUNDLE_ID rm-bundle REMOTE FILES BYTES LINKS
                                  delete one Metal capture bundle, Documents/.../NAME.gputrace
                                  (what GPU capture writes into a game's folder), once its tree
                                  holds exactly FILES files of BYTES bytes in all and LINKS links,
                                  as the local copy pp gpu capture pulled does; its links are
                                  removed, never followed. Nothing else (bundle_refusal)

rotate-log: the app appends every launch to s1-host.log (moving it aside itself only
past 256 MiB, WINE_HOST_DEV_LOG_CAP), and every driver pulls the whole file; this renames it in one AFC call, nothing is
copied. Run it only while the app is not running.
"""
import asyncio
import os
import re
import sys

LOG, PREV = "Documents/s1-host.log", "Documents/s1-host.prev.log"


async def connect(bundle_id):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    return await HouseArrestService.create(await create_using_usbmux(), bundle_id)


async def main(bundle_id, op, args):
    if op == "pull" and len(args) == 2:
        size = await pull_file(lambda: connect(bundle_id), args[0], args[1])
        print(f"{size} {args[1]}")
        return
    afc = await connect(bundle_id)
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
        elif op == "put-import" and len(args) == 1:
            why = import_refusal(args[0])
            if why:
                sys.exit(f"{args[0]}: {why}")
            folder = os.path.dirname(args[0])
            for d in (os.path.dirname(folder), folder):   # Documents/Import, then its NAME
                k = await kind(afc, d)
                if k == "absent":
                    await afc.makedirs(d)
                elif k != "dir":
                    sys.exit(f"{d}: not a directory ({k.split()[0]})")
            k = await kind(afc, args[0])
            if k != "absent" and not k.startswith("file"):
                sys.exit(f"{args[0]}: not a plain file ({k.split()[0]})")
            data = sys.stdin.buffer.read()
            await afc.set_file_contents(args[0], data)
            print(f"{args[0]}: {len(data)} bytes" + (f" (replaced {k.split()[1]} bytes)" if k != "absent" else ""))
        elif op == "rm" and len(args) == 1:
            why = rm_refusal(args[0])
            if why:
                sys.exit(f"{args[0]}: {why}")
            k = await kind(afc, args[0])
            if not k.startswith("file"):
                sys.exit(f"{args[0]}: " + ("no such file" if k == "absent" else "not a plain file"))
            await afc.rm(args[0])
            print(f"{args[0]}: removed ({k.split()[1]} bytes)")
        elif op == "stat" and len(args) == 1:
            print(await kind(afc, args[0]))
        elif op == "pull-bundle" and len(args) == 2:
            if not (await kind(afc, args[0])).startswith("dir"):
                sys.exit(f"{args[0]}: not a directory")
            remote = args[0].rstrip("/")
            n = await pull_tree(lambda: connect(bundle_id), remote, os.path.join(args[1], os.path.basename(remote)))
            print(f"pulled {n[0]} files ({n[1]} bytes, {n[3]} kept from before), {n[2]} links", flush=True)
        elif op == "rm-bundle" and len(args) == 4:
            why = bundle_refusal(args[0])
            if why:
                sys.exit(f"{args[0]}: {why}")
            try:
                expect = tuple(int(x) for x in args[1:])
            except ValueError:
                sys.exit(f"rm-bundle: FILES BYTES LINKS are counts, not {args[1:]}")
            print(await rm_bundle(afc, args[0].rstrip("/"), expect))
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


def rm_refusal(path):
    """Why rm will not delete this path, or None: only Documents/NAME.zip, NAME a plain file
    name (the container also holds the Wine prefix and the Steam session)."""
    name = path[len("Documents/"):] if path.startswith("Documents/") else ""
    if not name or "/" in name or name in (".", "..") or not name.endswith(".zip") or name == ".zip":
        return "rm deletes only Documents/NAME.zip (a file put there for import:)"
    return None


BUNDLE_NAME = re.compile(r"[A-Za-z0-9._()+-]+\.gputrace")


def bundle_refusal(path):
    """Why rm-bundle will not delete this path, or None: only a directory named NAME.gputrace
    under Documents/, by a path of plain names (no ., .. or empty part)."""
    parts = path.rstrip("/").split("/")
    if (len(parts) < 2 or parts[0] != "Documents" or any(p in ("", ".", "..") for p in parts)
            or not BUNDLE_NAME.fullmatch(parts[-1]) or parts[-1] == ".gputrace"):
        return "rm-bundle deletes only a Documents/.../NAME.gputrace capture bundle"
    return None


async def tree(afc, remote):
    """Every entry under REMOTE, parents before their children: (path, kind, size), kind
    "dir", "file" or "link" (a link is listed, never followed), size a file's bytes."""
    out = []
    for n in sorted(set(await afc.listdir(remote)) - {".", ".."}):
        path = remote + "/" + n
        k, _, v = (await kind(afc, path)).partition(" ")
        out.append((path, k, int(v) if k == "file" else 0))
        if k == "dir":
            out += await tree(afc, path)
    return out


def counts(entries):
    """(files, bytes, links) of tree()'s entries."""
    files = [s for _, k, s in entries if k == "file"]
    return len(files), sum(files), sum(1 for _, k, _ in entries if k == "link")


async def rm_bundle(afc, remote, expect):
    """Delete the bundle at REMOTE when its tree counts as EXPECT (files, bytes, links); what
    was removed. Exits, deleting nothing, when it is not a directory or the counts differ."""
    k = await kind(afc, remote)
    if k != "dir":
        sys.exit(f"{remote}: " + ("no such bundle" if k == "absent" else "not a directory"))
    entries = await tree(afc, remote)
    found = counts(entries)
    if found != tuple(expect):
        sys.exit(f"{remote}: holds {found[0]} files, {found[1]} bytes, {found[2]} links, not the "
                 f"{expect[0]}, {expect[1]}, {expect[2]} pulled: left in place")
    for path, _, _ in reversed(entries):   # children before their directory
        await afc.rm_single(path)
    await afc.rm_single(remote)
    return f"{remote}: removed ({found[0]} files, {found[1]} bytes, {found[2]} links)"


IMPORT_PART = re.compile(r"[A-Za-z0-9 ._()'+-]+")   # pp ui's import:PATH characters


def import_refusal(path):
    """Why put-import will not write this path, or None: only Documents/Import/NAME/FILE, NAME
    and FILE plain names (the import inbox; the container also holds the Wine prefix and the
    Steam session)."""
    parts = path.split("/")
    if (len(parts) != 4 or parts[:2] != ["Documents", "Import"]
            or any(p in (".", "..") or not IMPORT_PART.fullmatch(p) for p in parts[2:])):
        return ("put writes only Documents/Import/NAME/FILE (the import inbox), NAME and FILE "
                "plain names of letters, digits, space and ._()'+-")
    return None


# One AFC connection answers one request at a time, and over the network link (netmuxd)
# every request is a round trip: a bundle of ~1,000 entries pulled one by one, two
# requests to stat each and a whole read per file, took over 20 minutes for 2.5 GB
# (2026-10-21). So the tree is walked and pulled by this many connections at once.
PULL_CONNECTIONS = 8


async def pull_tree(connect, remote, local, workers=None, chunk=None, tries=None):
    """The directory REMOTE into LOCAL: its subdirectories, its files and its links (as local
    links, never followed), by `workers` connections from connect(). Each entry is a task in
    one queue: a directory is listed and its entries queued; an entry is stat'ed, then made,
    linked or pulled (in `chunk` reads, to LOCAL.part, renamed once whole). A file already
    in LOCAL at the size the phone has is kept, so a stopped pull resumes. A dropped
    connection is reopened and its task retried; `tries` connections in a row that fail one
    task, with no read bringing bytes in between, end the pull; a file's pull resumes at the
    bytes its LOCAL.part already holds. (files, bytes, links, files kept)."""
    workers, chunk, tries = workers or PULL_CONNECTIONS, chunk or PULL_CHUNK, tries or PULL_TRIES
    queue = asyncio.Queue()
    queue.put_nowait(("dir", remote, local))
    done = [0, 0, 0, 0]
    failed = []
    progress = [0]   # reads that brought bytes: a retry after progress starts its count again

    async def task(afc, what, src, dst):
        if what == "dir":
            os.makedirs(dst, exist_ok=True)
            for n in sorted(set(await afc.listdir(src)) - {".", ".."}):
                queue.put_nowait(("entry", src + "/" + n, os.path.join(dst, n)))
            return
        st = await afc.stat(src)
        fmt = st.get("st_ifmt")
        if fmt == "S_IFDIR":
            if os.path.lexists(dst) and not os.path.isdir(dst):
                os.remove(dst)
            queue.put_nowait(("dir", src, dst))
        elif fmt == "S_IFLNK":
            target = st.get("LinkTarget", "?")
            if os.path.islink(dst) and os.readlink(dst) == target:
                pass
            else:
                if os.path.lexists(dst):
                    os.remove(dst)
                os.symlink(target, dst)
            done[2] += 1
        else:
            size = int(st.get("st_size", 0))
            if os.path.isfile(dst) and not os.path.islink(dst) and os.path.getsize(dst) == size:
                done[3] += 1
            else:
                if os.path.lexists(dst):
                    os.remove(dst)
                part = dst + ".part"
                got = os.path.getsize(part) if os.path.isfile(part) else 0
                if got > size:
                    got = 0
                with open(part, "r+b" if got else "wb") as f:
                    f.truncate(got)
                    f.seek(got)
                    h = await afc.fopen(src)
                    if got:
                        await afc.fseek(h, got)
                    while got < size:
                        data = await afc.fread(h, min(chunk, size - got))
                        if not data:
                            break
                        f.write(data)
                        f.flush()
                        got += len(data)
                        progress[0] += 1
                    await afc.fclose(h)
                if got != size:
                    raise ConnectionError(f"{src}: {got} of {size} bytes")
                os.replace(part, dst)
                print(f"{size:>12} {dst}", flush=True)
            done[0] += 1
            done[1] += size

    async def worker():
        afc = None
        while True:
            item = await queue.get()
            try:
                if failed:
                    continue
                last, idle, seen = None, 0, progress[0]
                while idle < tries:
                    idle += 1
                    try:
                        if afc is None:
                            afc = await connect()
                            await afc.__aenter__()
                        await task(afc, *item)
                        break
                    except Exception as e:   # the connection dropped: reopen, retry the task
                        last = f"{type(e).__name__}: {e}"[:200]
                        if afc is not None:
                            try:
                                await afc.__aexit__(None, None, None)
                            except Exception:
                                pass
                        afc = None
                        if progress[0] != seen:
                            idle, seen = 0, progress[0]
                else:
                    failed.append(f"{item[1]}: {tries} connections in a row failed: {last}")
            finally:
                queue.task_done()

    pool = [asyncio.create_task(worker()) for _ in range(workers)]
    await queue.join()
    for p in pool:
        p.cancel()
    await asyncio.gather(*pool, return_exceptions=True)
    if failed:
        raise SystemExit(failed[0])
    return tuple(done)


# pymobiledevice3's own pull reads 4 MB at a time; over the network link (netmuxd) the phone
# dropped the connection on the first such read of an 18 MB s1-host.log, every time, leaving a
# 0-byte file. Smaller reads came through.
PULL_CHUNK = 512 * 1024
PULL_TRIES = 6   # connections opened in a row without a byte of progress


async def pull_file(connect, remote, local, chunk=PULL_CHUNK, tries=PULL_TRIES):
    """REMOTE (a plain file) into the file LOCAL; its size. connect() opens a new AFC service.
    A read that fails (the connection dropped) reopens one and seeks back to the bytes already
    written; it gives up after `tries` connections in a row that add nothing. The bytes go to
    LOCAL.part, renamed to LOCAL once all `size` (stat'ed at the start) are in, so a failed pull
    leaves no LOCAL. A file still growing is pulled up to its starting size."""
    part = local + ".part"
    done, size, idle, last = 0, None, 0, None
    with open(part, "wb") as f:
        while size is None or done < size:
            if idle >= tries:
                os.remove(part)
                raise SystemExit(f"{remote}: {done} of {size} bytes after {tries} connections "
                                 f"without progress: {last}")
            idle += 1
            try:
                afc = await connect()
                async with afc:
                    if size is None:
                        k, _, v = (await kind(afc, remote)).partition(" ")
                        if k != "file":
                            os.remove(part)
                            raise SystemExit(f"{remote}: " + ("no such file" if k == "absent" else "not a plain file"))
                        size = int(v)
                    h = await afc.fopen(remote)
                    if done:
                        await afc.fseek(h, done)
                    while done < size:
                        data = await afc.fread(h, min(chunk, size - done))
                        if not data:
                            break
                        f.write(data)
                        done += len(data)
                        idle = 0
                    await afc.fclose(h)
            except SystemExit:
                raise
            except Exception as e:   # the connection dropped: reopen and resume
                last = f"{type(e).__name__}: {e}"[:200]
                f.flush()
    os.replace(part, local)
    return size


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
