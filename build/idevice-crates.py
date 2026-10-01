#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared idevice target/features and Cargo inventory (no compilation or fetch)."""

import argparse
import json
import os
from pathlib import Path
import subprocess

TARGET = "aarch64-apple-ios"
FEATURES = "ring,tcp,core_device,core_device_proxy,tunnel_tcp_stack,rsd"


def resolve(src, rust, version, cache=None):
    home = rust / "cargo"
    env = dict(os.environ, CARGO_HOME=str(cache or home), RUSTUP_HOME=str(rust / "rustup"),
               RUSTUP_TOOLCHAIN=f"{version}-x86_64-unknown-linux-gnu",
               PATH=str(home / "bin") + os.pathsep + os.environ["PATH"])
    cargo = home / "bin/cargo"

    def run(command):
        result = subprocess.run(command, cwd=src / "ffi", env=env,
                                capture_output=True, text=True)
        if result.returncode:
            raise ValueError("Cargo inventory failed: " + result.stderr.strip())
        return result.stdout

    if not run([str(home / "bin/rustc"), "--version"]).startswith(f"rustc {version} "):
        raise ValueError("Cargo inventory requires the pinned Rust release")
    options = ["--locked", "--offline", "--no-default-features", "--features", FEATURES]
    tree = run([str(cargo), "tree", *options, "--target", TARGET, "-e", "normal",
                "--prefix", "none", "--format", "{p}"])
    wanted = {tuple(line.split()[:2]) for line in tree.splitlines() if line.strip()}
    metadata = json.loads(run([str(cargo), "metadata", *options, "--format-version", "1",
                               "--filter-platform", TARGET]))
    selected = [p for p in metadata["packages"] if (p["name"], "v" + p["version"]) in wanted]
    if len(selected) != len(wanted) or not selected:
        raise ValueError("Cargo tree/metadata identities are missing or ambiguous")
    return metadata["packages"], selected


def rows(packages, rust):
    home = str(rust / "cargo")
    return sorted((p["name"], p["version"], p.get("license") or "-",
                   str(Path(p["manifest_path"]).parent).replace(home, "$CARGO_HOME", 1))
                  for p in packages)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("target", "features", "inventory"))
    parser.add_argument("src", nargs="?", type=Path)
    parser.add_argument("rust", nargs="?", type=Path)
    parser.add_argument("version", nargs="?")
    args = parser.parse_args()
    if args.command != "inventory":
        print(TARGET if args.command == "target" else FEATURES)
        return
    if not all((args.src, args.rust, args.version)):
        parser.error("inventory requires SRC RUST_ROOT VERSION")
    try:
        _, selected = resolve(args.src.resolve(), args.rust.resolve(), args.version)
        for row in rows(selected, args.rust.resolve()):
            print("\t".join(row))
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(1, f"idevice: {exc}\n")


if __name__ == "__main__":
    main()
