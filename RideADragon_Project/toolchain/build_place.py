"""Mini-Rojo: builds an .rbxlx place file from a Rojo project (default.project.json)
and can also load the same tree into the simulator."""
import json
import os
import sys
from xml.sax.saxutils import escape
import paths  # noqa: E402

SCRIPT_SUFFIX = [(".server.luau", "Script"), (".client.luau", "LocalScript"), (".luau", "ModuleScript"),
                 (".server.lua", "Script"), (".client.lua", "LocalScript"), (".lua", "ModuleScript")]


class Node:
    def __init__(self, name, cls):
        self.name = name
        self.cls = cls
        self.props = {}
        self.children = []
        self.source = None
        self.path = None


def _script_kind(fname):
    for suf, kind in SCRIPT_SUFFIX:
        if fname.endswith(suf):
            return fname[: -len(suf)], kind
    return None, None


def load_path(path, name=None):
    if os.path.isdir(path):
        # init script?
        init = None
        for suf, kind in SCRIPT_SUFFIX:
            p = os.path.join(path, "init" + suf)
            if os.path.exists(p):
                init = (p, kind)
                break
        node = Node(name or os.path.basename(path), init[1] if init else "Folder")
        if init:
            with open(init[0], encoding="utf-8") as f:
                node.source = f.read()
            node.path = init[0]
        meta = os.path.join(path, "init.meta.json")
        if os.path.exists(meta):
            with open(meta) as f:
                m = json.load(f)
            node.props.update(m.get("properties", {}))
            if "className" in m:
                node.cls = m["className"]
        for fn in sorted(os.listdir(path)):
            fp = os.path.join(path, fn)
            if fn.startswith("init.") or fn.endswith(".meta.json"):
                continue
            if os.path.isdir(fp):
                node.children.append(load_path(fp))
            else:
                base, kind = _script_kind(fn)
                if kind:
                    ch = Node(base, kind)
                    with open(fp, encoding="utf-8") as f:
                        ch.source = f.read()
                    ch.path = fp
                    mp = os.path.join(path, base + ".meta.json")
                    if os.path.exists(mp):
                        with open(mp) as f:
                            ch.props.update(json.load(f).get("properties", {}))
                    node.children.append(ch)
                elif fn.endswith(".model.json"):
                    with open(fp) as f:
                        node.children.append(model_json(json.load(f), fn[: -len(".model.json")]))
        return node
    base, kind = _script_kind(os.path.basename(path))
    node = Node(name or base, kind)
    with open(path, encoding="utf-8") as f:
        node.source = f.read()
    node.path = path
    return node


def model_json(d, name):
    n = Node(d.get("Name", name), d.get("ClassName", "Folder"))
    n.props.update(d.get("Properties", {}))
    for c in d.get("Children", []):
        n.children.append(model_json(c, c.get("Name", "Child")))
    return n


def load_project(project_file):
    root_dir = os.path.dirname(os.path.abspath(project_file))
    with open(project_file) as f:
        proj = json.load(f)

    def walk(name, spec):
        if "$path" in spec:
            node = load_path(os.path.join(root_dir, spec["$path"]), name)
            if "$className" in spec:
                node.cls = spec["$className"]
        else:
            node = Node(name, spec.get("$className", "Folder"))
        node.props.update(spec.get("$properties", {}))
        for k, v in spec.items():
            if k.startswith("$"):
                continue
            node.children.append(walk(k, v))
        return node

    tree = walk("Game", proj["tree"])
    return proj.get("name", "Place"), tree


# ------------------------------------------------------------------ rbxlx writer

def _prop_xml(name, val):
    if isinstance(val, dict) and len(val) == 1:
        t, v = next(iter(val.items()))
        if t == "Bool":
            return f'<bool name="{name}">{"true" if v else "false"}</bool>'
        if t == "Int32":
            return f'<int name="{name}">{int(v)}</int>'
        if t == "Int64":
            return f'<int64 name="{name}">{int(v)}</int64>'
        if t == "Float32":
            return f'<float name="{name}">{float(v)}</float>'
        if t == "Float64":
            return f'<double name="{name}">{float(v)}</double>'
        if t == "String":
            return f'<string name="{name}">{escape(v)}</string>'
        if t == "Enum":
            return f'<token name="{name}">{int(v)}</token>'
        if t == "Vector3":
            return f'<Vector3 name="{name}"><X>{v[0]}</X><Y>{v[1]}</Y><Z>{v[2]}</Z></Vector3>'
        if t == "Color3":
            return f'<Color3 name="{name}"><R>{v[0]}</R><G>{v[1]}</G><B>{v[2]}</B></Color3>'
        raise ValueError(f"unsupported explicit type {t}")
    if isinstance(val, bool):
        return f'<bool name="{name}">{"true" if val else "false"}</bool>'
    if isinstance(val, str):
        return f'<string name="{name}">{escape(val)}</string>'
    raise ValueError(f"property {name}: use explicit typed values ({val!r})")


def _cdata(s):
    return "<![CDATA[" + s.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def write_rbxlx(tree, out_path):
    ref = [0]

    def next_ref():
        ref[0] += 1
        return f"RBX{ref[0]:06d}"

    lines = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
             'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
             'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
             '\t<External>null</External>', '\t<External>nil</External>']

    def emit(node, depth):
        ind = "\t" * depth
        lines.append(f'{ind}<Item class="{node.cls}" referent="{next_ref()}">')
        lines.append(f"{ind}\t<Properties>")
        lines.append(f'{ind}\t\t<string name="Name">{escape(node.name)}</string>')
        if node.source is not None:
            lines.append(f'{ind}\t\t<ProtectedString name="Source">{_cdata(node.source)}</ProtectedString>')
        for k, v in node.props.items():
            lines.append(f"{ind}\t\t" + _prop_xml(k, v))
        lines.append(f"{ind}\t</Properties>")
        for c in node.children:
            emit(c, depth + 1)
        lines.append(f"{ind}</Item>")

    for svc in tree.children:
        emit(svc, 1)
    lines.append("</roblox>")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


# ------------------------------------------------------------------ load into sim

def explicit_value(v):
    from rbx_types import Vector3, Color3, ENUM
    if isinstance(v, dict) and len(v) == 1:
        t, x = next(iter(v.items()))
        if t == "Bool":
            return bool(x)
        if t in ("Int32", "Int64", "Float32", "Float64"):
            return float(x)
        if t == "String":
            return x
        if t == "Enum":
            return ("__enum__", int(x))
        if t == "Vector3":
            return Vector3(*x)
        if t == "Color3":
            return Color3(*x)
    return v


def load_into_sim(sim, tree):
    from rbx_types import EnumItem

    def make(node, parent):
        if node.cls in sim.services:
            inst = sim.services[node.cls]
        elif node.cls == "Terrain" and getattr(sim, "terrain", None) is not None:
            inst = sim.terrain
        elif parent is not None and parent.cls.name == "StarterPlayer" and node.name in ("StarterPlayerScripts", "StarterCharacterScripts"):
            inst = parent.find_child(node.name)
        else:
            inst = sim.new(node.cls)
            inst.props["Name"] = node.name
        if node.source is not None:
            inst.props["Source"] = node.source
            inst.extra["source_path"] = os.path.relpath(node.path, paths.GAME) if node.path else node.name
        for k, v in node.props.items():
            val = explicit_value(v)
            if isinstance(val, tuple) and val and val[0] == "__enum__":
                t = inst.cls.all_props()[k][0]
                en = t.split(":", 1)[1].rstrip("?")
                from rbx_types import ENUM
                val = ENUM.types[en].coerce(val[1])
            inst.set_prop(k, val, internal=True)
        for c in node.children:
            ci = make(c, inst)
            if ci.parent is not inst and not (ci.cls.service):
                ci.set_parent(inst)
        return inst

    for svc in tree.children:
        make(svc, None)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    proj = args[0]
    out = args[1]
    if "--skip-realcheck" not in sys.argv:
        # gate: the real Luau compiler must accept every script (the Python interpreter is more lenient)
        import luau_realcheck
        ok, report = luau_realcheck.check(os.path.join(os.path.dirname(os.path.abspath(proj)), "src"))
        print(report.splitlines()[-1] if report else "")
        if ok is False:
            print(report)
            sys.exit("BUILD ABORTED: Roblox would reject these scripts (real Luau compiler)")
    name, tree = load_project(proj)
    write_rbxlx(tree, out)
    print(f"wrote {out}")
