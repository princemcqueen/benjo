"""Minimal physics step for the simulator: drives unanchored assemblies with
LinearVelocity (Vector mode, world-relative) and AlignOrientation (one
attachment). Enough to run client-side movement controllers offline.

Install with: sim.physics = rbx_physics.make_physics()
"""
from rbx_types import CFrame, Vector3
from rbx_api import assembly_root, part_cframe

CONSTRAINT_CLASSES = ("LinearVelocity", "AlignOrientation")


def make_physics(rescan_every=20):
    state = {"frame": 0, "constraints": [], "log": []}

    def rescan(sim):
        out = []
        for d in sim.services["Workspace"].descendants():
            if d.cls.name in CONSTRAINT_CLASSES:
                out.append(d)
        state["constraints"] = out

    def physics(sim, dt):
        if state["frame"] % rescan_every == 0 or sim.weld_cache is None:
            rescan(sim)
        state["frame"] += 1
        per_root = {}
        for c in state["constraints"]:
            if c.destroyed or not c.props.get("Enabled", True) or not c.in_game():
                continue
            a0 = c.props.get("Attachment0")
            if a0 is None or a0.parent is None or not a0.parent.is_a("BasePart"):
                continue
            root = assembly_root(sim, a0.parent)
            if root.props.get("Anchored"):
                continue
            per_root.setdefault(root, []).append(c)
        for root, cons in per_root.items():
            cf = part_cframe(sim, root)
            vel = root.props.get("AssemblyLinearVelocity") or Vector3()
            rot = cf.r
            for c in cons:
                if c.cls.name == "LinearVelocity":
                    vel = c.get_prop("VectorVelocity")
                elif c.cls.name == "AlignOrientation":
                    target = c.get_prop("CFrame")
                    if c.get_prop("RigidityEnabled"):
                        rot = target.r
                    else:
                        resp = max(0.0, c.get_prop("Responsiveness"))
                        alpha = min(1.0, resp * dt)
                        cur = CFrame((0, 0, 0), rot)
                        rot = cur.lerp(CFrame((0, 0, 0), target.r), alpha).r
            p = cf.p
            np_ = (p[0] + vel.x * dt, p[1] + vel.y * dt, p[2] + vel.z * dt)
            root.props["CFrame"] = CFrame(np_, rot)
            root.props["AssemblyLinearVelocity"] = vel

    physics.state = state
    return physics
