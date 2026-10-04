"""Builds a species with the Lua Builder inside the simulator and dumps its
bones, parts and attachments (build space) to JSON for the mesh generator."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from sim_runner import boot
import luau_interp as LI
from rbx_api import part_cframe

SNIP = r'''
local RS = game:GetService("ReplicatedStorage")
local Builder = require(RS.Shared.Dragons.Builder)
local Species = require(RS.Shared.Dragons.Species)
local m = Builder.build("%s", { Detail = "High", Saddle = %s })
m.Name = "DumpModel"
m.Parent = workspace
local function conv(v)
	local t = typeof(v)
	if t == "Color3" then
		return { math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5) }
	elseif t == "table" then
		local o = {}
		for k, x in v do
			o[k] = conv(x)
		end
		return o
	elseif t == "EnumItem" then
		return v.Name
	end
	return v
end
shared.speciesDef = conv(Species.get("%s"))
'''


def dump(species, saddle=True):
    sim = boot()
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    sim.in_ctx(ctx, LI.load(SNIP % (species, "true" if saddle else "false", species), "dump", env))
    from sim_runner import lua_table_to_py
    sdef = lua_table_to_py(ctx.shared.get("speciesDef"))
    model = sim.services["Workspace"].find_child("DumpModel")
    root = model.find_child("Root")
    parts, bones, atts = [], {}, []
    # bone of each part: follow Weld (deco) / Motor6D (bone) Part0 chain
    def owner(p):
        for c in p.children:
            if c.cls.name == "Motor6D" and c.props.get("Name") != "MemJoint":
                return p.props.get("Name")
            if c.cls.name == "Weld":
                return c.props.get("Part0").props.get("Name")
        return "Root"
    for d in model.descendants():
        if d.is_a("BasePart"):
            cf = part_cframe(sim, d)
            shape = "Block"
            if d.cls.name == "WedgePart":
                shape = "Wedge"
            elif d.props.get("Shape") is not None and d.cls.name == "Part":
                shape = d.props["Shape"].name
            mesh = None
            for c in d.children:
                if c.cls.name == "SpecialMesh":
                    mt = c.get_prop("MeshType").name
                    sc = c.get_prop("Scale")
                    mesh = {"type": mt, "scale": [sc.x, sc.y, sc.z]}
                    shape = {"Sphere": "Ellipsoid", "Wedge": "MeshWedge"}.get(mt, shape)
            size = d.get_prop("Size")
            col = d.get_prop("Color").rgb255()
            parts.append({
                "name": d.props.get("Name"), "shape": shape, "size": [size.x, size.y, size.z],
                "cf": list(cf.p) + list(cf.r), "color": list(col), "material": d.get_prop("Material").name,
                "transparency": d.get_prop("Transparency"), "bone": owner(d) if d is not root else "Root",
                "mesh": mesh, "attrs": dict(d.attrs),
            })
        elif d.cls.name == "Motor6D" and d.props.get("Name") != "MemJoint":
            p0 = d.props.get("Part0")
            c0 = d.props.get("C0")
            piv = part_cframe(sim, p0).mul(c0).p
            bones[d.props.get("Name")] = {"parent": p0.props.get("Name"), "pivot": list(piv)}
        elif d.cls.name == "Attachment":
            par = d.parent
            wcf = part_cframe(sim, par).mul(d.get_prop("CFrame"))
            atts.append({"name": d.props.get("Name"), "bone": par.props.get("Name"), "pos": list(wcf.p)})
    out = {"species": species, "def": sdef, "attrs": dict(model.attrs), "parts": parts, "bones": bones,
           "attachments": atts}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", f"{species}.json")
    with open(path, "w") as f:
        json.dump(out, f)
    return path, out


if __name__ == "__main__":
    sp = sys.argv[1] if len(sys.argv) > 1 else "GreenDrake"
    path, out = dump(sp)
    print(path, len(out["parts"]), "parts", len(out["bones"]), "bones", len(out["attachments"]), "attachments")
    from collections import Counter
    print(Counter(p["shape"] for p in out["parts"]))
    print(sorted(out["bones"].keys()))
