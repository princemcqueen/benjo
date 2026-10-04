"""Central place for every filesystem location the toolchain uses, so nothing is
hard-coded to one machine. Everything is derived from where this file lives:

    <project>/                 ROOT      (folder that holds RideADragon/ and toolchain/)
        RideADragon/           GAME      (Rojo project)
            default.project.json PROJECT
            src/               SRC
        toolchain/             TOOLCHAIN
            out/               OUT       (renders, caches; override with env var RAD_OUT)
"""
import os

TOOLCHAIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLCHAIN)
GAME = os.path.join(ROOT, "RideADragon")
SRC = os.path.join(GAME, "src")
PROJECT = os.path.join(GAME, "default.project.json")
WORLD_SRC = os.path.join(SRC, "ServerScriptService", "World")
MESHGEN_OUT = os.path.join(TOOLCHAIN, "meshgen", "out")
OUT = os.environ.get("RAD_OUT") or os.path.join(TOOLCHAIN, "out")

os.makedirs(OUT, exist_ok=True)


def out(name):
    """Path of a file inside the output folder."""
    return os.path.join(OUT, name)
