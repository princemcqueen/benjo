"""Compiles every .luau file with the REAL Luau compiler (the one Roblox uses), so syntax the
Python-hosted interpreter happens to accept but Roblox rejects can never reach a test build.

  python3 toolchain/luau_realcheck.py [src_dir]      exit 1 on any syntax error

The checker is a tiny Rust program (toolchain/realcheck, mlua + the vendored Luau sources); it is
built once with cargo and cached in toolchain/realcheck/target. Without cargo the check is skipped
with a loud warning (exit 0) - install Rust (https://rustup.rs) to get the gate.
"""
import os
import shutil
import subprocess
import sys

import paths

CRATE = os.path.join(paths.TOOLCHAIN, "realcheck")
BIN = os.path.join(CRATE, "target", "release", "realcheck")


def ensure_binary(verbose=True):
    if os.path.exists(BIN):
        return BIN
    cargo = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")
    if not os.path.exists(cargo):
        return None
    if verbose:
        print("realcheck: building the real-Luau checker (first run only, a few minutes)...", flush=True)
    r = subprocess.run([cargo, "build", "--release", "--quiet"], cwd=CRATE, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(BIN):
        print("realcheck: build failed:\n" + (r.stderr or r.stdout)[-1500:])
        return None
    return BIN


def check(src_dir=None, verbose=True):
    """Returns (ok, output). ok is None when the checker is unavailable."""
    binary = ensure_binary(verbose)
    if not binary:
        return None, "realcheck: SKIPPED - no cargo / checker binary (install Rust to enable the real Luau gate)"
    r = subprocess.run([binary, src_dir or paths.SRC], capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def main():
    ok, out = check(sys.argv[1] if len(sys.argv) > 1 else None)
    print(out)
    sys.exit(1 if ok is False else 0)


if __name__ == "__main__":
    main()
