"""Top-down debug map of the Haven layout."""
import math
import pickle
import sys

from PIL import Image, ImageDraw

import haven as HV


def draw(hv, lay, path, scale=2):
    hv.topdown(path, scale=scale)
    im = Image.open(path).convert("RGB")
    dr = ImageDraw.Draw(im)
    k = scale / HV.GRID

    def P(x, z):
        return ((x + HV.EXTENT) * k, (z + HV.EXTENT) * k)

    for kind, x, y, z, yaw, s in lay.trees:
        c = {"Oak": (30, 70, 30), "Pine": (20, 50, 40), "Birch": (120, 150, 70)}[kind]
        px, pz = P(x, z)
        dr.ellipse([px - 1.5, pz - 1.5, px + 1.5, pz + 1.5], fill=c)
    for x, y, z, yaw, s, v in lay.rocks:
        px, pz = P(x, z)
        dr.rectangle([px - 1, pz - 1, px + 1, pz + 1], fill=(150, 150, 150))
    for b in lay.buildings:
        px, pz = P(b["x"], b["z"])
        r = 4 if b["kind"] == "cottage" else 7
        col = (220, 120, 60) if b["kind"] == "cottage" else (255, 220, 60)
        dr.rectangle([px - r, pz - r, px + r, pz + r], outline=col, width=2)
    for x, z, yaw in lay.lamps:
        px, pz = P(x, z)
        dr.point((px, pz), fill=(255, 255, 120))
    for b in lay.bridges:
        px, pz = P(b["x"], b["z"])
        dr.ellipse([px - 6, pz - 6, px + 6, pz + 6], outline=(255, 80, 200), width=2)
    for name, x, y, z in lay.eggs:
        px, pz = P(x, z)
        dr.ellipse([px - 4, pz - 4, px + 4, pz + 4], outline=(255, 255, 255), width=2)
    for p in HV.PLOTS:
        px, pz = P(*p["c"])
        dr.ellipse([px - 10, pz - 10, px + 10, pz + 10], outline=(80, 200, 255), width=2)
    im.save(path)
    return path


if __name__ == "__main__":
    import layout as LY
    hv, lay = LY.build_all()
    with open("/tmp/claude-0/out/haven_layout.pkl", "wb") as f:
        pickle.dump((hv, lay), f)
    print(draw(hv, lay, "/tmp/claude-0/out/haven_layout.png"))
