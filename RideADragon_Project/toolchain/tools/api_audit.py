"""Audits the simulator's Roblox class database against the REAL Roblox API (real_api.json):
every property / event the sim accepts must exist in the real class (or one of its ancestors).

    python3 toolchain/tools/api_audit.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import rbx_classes  # noqa: E402
import rbx_enums  # noqa: E402

REAL = json.load(open(os.path.join(os.path.dirname(HERE), "real_api.json")))
RC = REAL["classes"]


def real_members(cls):
    out = {}
    seen = set()

    def walk(c):
        if c in seen or c not in RC:
            return
        seen.add(c)
        for k, v in RC[c]["members"].items():
            out.setdefault(k, v)
        for s in RC[c]["super"]:
            walk(s)

    walk(cls)
    return out


def main():
    bad = 0
    for name, info in sorted(rbx_classes.CLASSES.items()):
        if name not in RC:
            print(f"CLASS not in real API: {name}")
            bad += 1
            continue
        real = real_members(name)
        for p in info.props:
            if p not in real:
                print(f"{name}.{p}: property does NOT exist in the real API")
                bad += 1
            elif real[p][0] != "prop":
                print(f"{name}.{p}: real member is a {real[p][0]}, sim treats it as a property")
                bad += 1
            elif "S" in real[p][1]:
                print(f"{name}.{p}: NotScriptable in the real API")
                bad += 1
            elif "R" in real[p][1] and not info.is_ro(p):
                print(f"{name}.{p}: READ-ONLY for scripts in the real API (sim lets scripts assign it)")
                bad += 1
        for e in info.events:
            if e not in real:
                print(f"{name}.{e}: event does NOT exist in the real API")
                bad += 1
            elif real[e][0] != "event":
                print(f"{name}.{e}: real member is a {real[e][0]}, sim treats it as an event")
                bad += 1
    # methods / special accessors registered by rbx_api
    from rbx_sim import Sim
    sim = Sim()
    for cname, table in sorted(sim.methods.items()):
        if cname not in RC:
            print(f"methods registered for unknown class {cname}")
            bad += 1
            continue
        real = real_members(cname)
        for m in table:
            if m not in real:
                print(f"{cname}:{m}(): method does NOT exist in the real API")
                bad += 1
            elif real[m][0] != "method":
                print(f"{cname}:{m}(): real member is a {real[m][0]}, sim registers a method")
                bad += 1
    for prop, lst in sorted(sim.special_getters.items()):
        for cname, _fn in lst:
            if cname in RC and prop not in real_members(cname):
                print(f"{cname}.{prop}: special getter for a member that does NOT exist in the real API")
                bad += 1
    for prop, lst in sorted(sim.special_setters.items()):
        for cname, _fn in lst:
            if cname in RC:
                real = real_members(cname)
                if prop not in real:
                    print(f"{cname}.{prop}: special setter for a member that does NOT exist in the real API")
                    bad += 1
                elif "R" in real[prop][1]:
                    print(f"{cname}.{prop}: scripts cannot assign this in the real API, the sim allows it")
                    bad += 1
    # enums
    enums = rbx_enums.ENUMS
    print("enums in the sim:", len(enums))
    if enums:
        for en, items in sorted(enums.items()):
            real = REAL["enums"].get(en)
            if real is None:
                print(f"Enum.{en}: not in the real API")
                bad += 1
                continue
            for nm, val in items.items():
                if nm not in real:
                    print(f"Enum.{en}.{nm}: does NOT exist in the real API")
                    bad += 1
    print("audit:", bad, "problems")
    return bad


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
