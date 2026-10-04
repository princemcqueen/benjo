"""Rig + part lookup helpers over a species dump (build space, facing -Z)."""
import json

import numpy as np


class Rig:
    def __init__(self, dump):
        self.dump = dump
        self.S = float(dump["attrs"].get("Scale", 1.0))
        self.defn = dump["def"]
        self.bones = {}
        for name, b in dump["bones"].items():
            self.bones[name] = {"parent": b["parent"], "pivot": np.array(b["pivot"], float)}
        self.bones["Root"] = {"parent": None, "pivot": np.zeros(3)}
        self.atts = {a["name"]: {"bone": a["bone"], "pos": np.array(a["pos"], float)} for a in dump["attachments"]}
        self.parts = dump["parts"]

    @classmethod
    def load(cls, path):
        with open(path) as f:
            return cls(json.load(f))

    def pivot(self, name):
        return self.bones[name]["pivot"]

    def att(self, name):
        return self.atts[name]["pos"]

    def find(self, name, bone=None):
        out = [p for p in self.parts if p["name"] == name and (bone is None or p["bone"] == bone)]
        return out

    def one(self, name, bone=None):
        f = self.find(name, bone)
        return f[0] if f else None

    @staticmethod
    def frame(part):
        cf = part["cf"]
        c = np.array(cf[:3], float)
        R = np.array(cf[3:12], float).reshape(3, 3)
        return c, R

    def color(self, key):
        c = self.defn["Palette"].get(key)
        return np.array(c, float) / 255.0 if c else np.array([0.5, 0.5, 0.5])

    def bone_order(self):
        """Parents before children (Root first)."""
        order, seen = [], set()

        def visit(n):
            if n in seen:
                return
            p = self.bones[n]["parent"]
            if p is not None and p in self.bones:
                visit(p)
            seen.add(n)
            order.append(n)

        for n in self.bones:
            visit(n)
        return order


def ellipsoid_axis_endpoints(part):
    """For an ellipsoid built with EB(a, b): its long axis is local Z."""
    c, R = Rig.frame(part)
    half = part["size"][2] / 2
    z = R[:, 2]
    return c - z * half, c + z * half
