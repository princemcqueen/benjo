"""Minimal glTF 2.0 binary (.glb) writer with skinning and PBR textures."""
import io
import json
import struct

import numpy as np


class GLB:
    def __init__(self):
        self.json = {"asset": {"version": "2.0", "generator": "RideADragon meshgen"},
                     "scenes": [{"nodes": []}], "scene": 0, "nodes": [], "meshes": [], "accessors": [],
                     "bufferViews": [], "buffers": [], "materials": [], "textures": [], "images": [],
                     "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
                     "skins": []}
        self.bin = bytearray()

    # ------------------------------------------------------------- buffers
    def _view(self, data: bytes, target=None):
        while len(self.bin) % 4:
            self.bin.append(0)
        off = len(self.bin)
        self.bin.extend(data)
        view = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            view["target"] = target
        self.json["bufferViews"].append(view)
        return len(self.json["bufferViews"]) - 1

    def accessor(self, arr, kind, target=None, minmax=False, normalized=False):
        arr = np.ascontiguousarray(arr)
        ctype = {np.dtype("float32"): 5126, np.dtype("uint32"): 5125, np.dtype("uint16"): 5123,
                 np.dtype("uint8"): 5121}[arr.dtype]
        view = self._view(arr.tobytes(), target)
        count = arr.shape[0]
        acc = {"bufferView": view, "componentType": ctype, "count": int(count), "type": kind}
        if normalized:
            acc["normalized"] = True
        if minmax:
            flat = arr.reshape(count, -1)
            acc["min"] = [float(v) for v in flat.min(axis=0)]
            acc["max"] = [float(v) for v in flat.max(axis=0)]
        self.json["accessors"].append(acc)
        return len(self.json["accessors"]) - 1

    def image_png(self, pil_image, name):
        buf = io.BytesIO()
        pil_image.save(buf, format="PNG")
        view = self._view(buf.getvalue())
        self.json["images"].append({"bufferView": view, "mimeType": "image/png", "name": name})
        self.json["textures"].append({"sampler": 0, "source": len(self.json["images"]) - 1})
        return len(self.json["textures"]) - 1

    # ------------------------------------------------------------- scene
    def node(self, name, translation=None, rotation=None, children=None, mesh=None, skin=None, root=False):
        n = {"name": name}
        if translation is not None:
            n["translation"] = [float(v) for v in translation]
        if rotation is not None:
            n["rotation"] = [float(v) for v in rotation]
        if children:
            n["children"] = list(children)
        if mesh is not None:
            n["mesh"] = mesh
        if skin is not None:
            n["skin"] = skin
        self.json["nodes"].append(n)
        idx = len(self.json["nodes"]) - 1
        if root:
            self.json["scenes"][0]["nodes"].append(idx)
        return idx

    def material(self, name, base_tex=None, normal_tex=None, rough_tex=None, roughness=0.7, metallic=0.0,
                 base_color=(1, 1, 1, 1)):
        pbr = {"baseColorFactor": list(base_color), "metallicFactor": metallic, "roughnessFactor": roughness}
        if base_tex is not None:
            pbr["baseColorTexture"] = {"index": base_tex}
        if rough_tex is not None:
            pbr["metallicRoughnessTexture"] = {"index": rough_tex}
        m = {"name": name, "pbrMetallicRoughness": pbr, "doubleSided": False}
        if normal_tex is not None:
            m["normalTexture"] = {"index": normal_tex}
        self.json["materials"].append(m)
        return len(self.json["materials"]) - 1

    def mesh(self, name, positions, normals, uvs, indices, material=None, joints=None, weights=None):
        attrs = {
            "POSITION": self.accessor(positions.astype(np.float32), "VEC3", 34962, minmax=True),
            "NORMAL": self.accessor(normals.astype(np.float32), "VEC3", 34962),
        }
        if uvs is not None:
            attrs["TEXCOORD_0"] = self.accessor(uvs.astype(np.float32), "VEC2", 34962)
        if joints is not None:
            attrs["JOINTS_0"] = self.accessor(joints.astype(np.uint16), "VEC4", 34962)
            attrs["WEIGHTS_0"] = self.accessor(weights.astype(np.float32), "VEC4", 34962)
        idx_dtype = np.uint32 if positions.shape[0] > 65535 else np.uint16
        prim = {"attributes": attrs, "indices": self.accessor(indices.reshape(-1).astype(idx_dtype), "SCALAR", 34963),
                "mode": 4}
        if material is not None:
            prim["material"] = material
        self.json["meshes"].append({"name": name, "primitives": [prim]})
        return len(self.json["meshes"]) - 1

    def skin(self, name, joint_nodes, inverse_binds, skeleton_root):
        acc = self.accessor(inverse_binds.astype(np.float32).reshape(len(joint_nodes), 16), "MAT4")
        self.json["skins"].append({"name": name, "joints": list(joint_nodes), "inverseBindMatrices": acc,
                                   "skeleton": skeleton_root})
        return len(self.json["skins"]) - 1

    def write(self, path):
        for k in ("materials", "textures", "images", "skins", "samplers"):
            if not self.json[k]:
                del self.json[k]
        while len(self.bin) % 4:
            self.bin.append(0)
        self.json["buffers"] = [{"byteLength": len(self.bin)}]
        js = json.dumps(self.json, separators=(",", ":")).encode("utf-8")
        while len(js) % 4:
            js += b" "
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        with open(path, "wb") as f:
            f.write(struct.pack("<4sII", b"glTF", 2, total))
            f.write(struct.pack("<I4s", len(js), b"JSON"))
            f.write(js)
            f.write(struct.pack("<I4s", len(self.bin), b"BIN\x00"))
            f.write(self.bin)
        return path


def translation_matrix(t):
    m = np.eye(4, dtype=np.float32)
    m[:3, 3] = t
    return m
