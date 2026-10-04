"""Builds toolchain/real_api.json - the real Roblox class/member/enum lists - from the generated
declarations of the npm package @rbxts/types (the same API dump Roblox Studio uses).

    python3 toolchain/tools/make_real_api.py [path/to/package/include/generated]

Without an argument the package is fetched with `npm pack @rbxts/types`.
Only members a game script can touch are kept (the "None" security context).
"""
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "real_api.json")


def fetch():
    tmp = tempfile.mkdtemp()
    subprocess.run(["npm", "pack", "@rbxts/types"], cwd=tmp, check=True, capture_output=True)
    tgz = [f for f in os.listdir(tmp) if f.endswith(".tgz")][0]
    with tarfile.open(os.path.join(tmp, tgz)) as t:
        t.extractall(tmp)
    return os.path.join(tmp, "package", "include", "generated")


def parse_classes(text):
    classes = {}
    lines = text.split("\n")
    i = 0
    n = len(lines)
    head = re.compile(r"^interface (\w+)(?:<.*?>)?(?: extends (.+?))? \{$")
    member = re.compile(r"^    (readonly |get |set )?(\w+)(\??)(?:<[^>]*>)?\s*([:(])\s*(.*)$")
    while i < n:
        m = head.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        sup = [re.sub(r"<.*", "", s).strip() for s in re.split(r",\s*(?![^<]*>)", m.group(2) or "") if s.strip()]
        members = {}
        i += 1
        doc = []
        in_doc = False
        while i < n and lines[i] != "}":
            ln = lines[i]
            if ln.startswith("    /**"):
                in_doc = True
                doc = []
            if in_doc:
                doc.append(ln)
                if "*/" in ln:
                    in_doc = False
                i += 1
                continue
            mm = member.match(ln)
            if mm and not mm.group(2).startswith("_nominal_"):
                mname, sep, rest = mm.group(2), mm.group(4), mm.group(5)
                accessor = (mm.group(1) or "").strip()
                if sep == "(" and not accessor:
                    kind = "method"
                elif rest.startswith("RBXScriptSignal"):
                    kind = "event"
                else:
                    kind = "prop"
                tags = " ".join(doc)
                flags = ""
                if "NotScriptable" in tags:
                    flags += "S"  # not scriptable
                if "@deprecated" in tags:
                    flags += "D"
                if "ReadOnly" in tags and kind == "prop":
                    flags += "R"
                if accessor in ("readonly", "get") and kind == "prop":
                    flags += "R"  # scripts can read it but not assign it
                if accessor == "get":
                    # `get X(): T;`  -> type after "):"
                    rest = rest.split(":", 1)[1] if ":" in rest else rest
                    rest = rest.lstrip(") :").strip() or rest
                ptype = rest.rstrip(";").strip() if kind == "prop" else ""
                if accessor == "set" and mname in members:
                    members[mname][1] = members[mname][1].replace("R", "")
                    i += 1
                    continue
                members[mname] = [kind, flags, ptype]
            doc = [] if not in_doc else doc
            i += 1
        classes[name] = {"super": sup, "members": members}
        i += 1
    return classes


def parse_enums(text):
    enums = {}
    cur = None
    for ln in text.split("\n"):
        m = re.match(r"^    export namespace (\w+) \{$", ln)
        if m:
            cur = m.group(1)
            enums[cur] = []
            continue
        m = re.match(r"^        export interface (\w+) extends globalThis\.EnumItem \{$", ln)
        if m and cur:
            enums[cur].append(m.group(1))
    return enums


def main():
    gen = sys.argv[1] if len(sys.argv) > 1 else fetch()
    classes = parse_classes(open(os.path.join(gen, "None.d.ts"), encoding="utf-8").read())
    enums = parse_enums(open(os.path.join(gen, "enums.d.ts"), encoding="utf-8").read())
    data = {"source": "@rbxts/types generated declarations", "classes": classes, "enums": enums}
    with open(OUT, "w") as f:
        json.dump(data, f, separators=(",", ":"), sort_keys=True)
    print("classes", len(classes), "enums", len(enums), "->", OUT, os.path.getsize(OUT) // 1024, "KB")


if __name__ == "__main__":
    main()
