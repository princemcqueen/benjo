"""End-to-end riding test in the simulator: starter dragon grant, companion
spawn, client visual build, follow AI, mount, ground run, jump, takeoff,
flight, landing, dismount. Prints a timeline and checks for runtime errors.
Optionally renders a frame from the riding camera."""
import sys, os, math
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from sim_runner import boot, client_of
import rbx_physics
import rbx_api
import luau_interp as LI
from rbx_types import CFrame, Vector3

WORLD = r'''
local base = Instance.new("Part")
base.Name = "Baseplate"
base.Anchored = true
base.Size = Vector3.new(2048, 2, 2048)
base.CFrame = CFrame.new(0, -1, 0)
base.Color = Color3.fromRGB(98, 130, 78)
base.Parent = workspace
local wall = Instance.new("Part")
wall.Name = "Wall"
wall.Anchored = true
wall.Size = Vector3.new(4, 80, 400)
wall.CFrame = CFrame.new(140, 40, -200)
wall.Parent = workspace
local spawn = Instance.new("SpawnLocation")
spawn.Anchored = true
spawn.Size = Vector3.new(6, 1, 6)
spawn.CFrame = CFrame.new(0, 0.5, 0)
spawn.Parent = workspace
'''


def server_lua(sim, src):
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    fn = LI.load(src, "srv", env)
    return sim.in_ctx(ctx, fn)


def key(sim, player, code, down):
    client = client_of(player)
    if down:
        client.keys_down.add(code)
    else:
        client.keys_down.discard(code)
    io = rbx_api.input_object(sim, "Keyboard", code, "Begin" if down else "End")
    rbx_api.dispatch_input(sim, client, io, began=down)


RENDER_AT = set()
RENDER_SIM = {}


def snapshot(sim, label):
    SMOOTH.label = label
    if label in RENDER_AT and RENDER_SIM.get("player") is not None:
        render_frame(sim, RENDER_SIM["player"], "/tmp/claude-0/out/ride_" + label.replace(" ", "_").replace("(", "").replace(")", "") + ".png")
    ws = sim.services["Workspace"]
    folder = ws.find_child("Dragons")
    model = folder.find_child("Dragon_1001") if folder else None
    if not model:
        print(f"{label}: no dragon model")
        return None
    root = model.find_child("Root")
    cf = rbx_api.part_cframe(sim, root)
    v = root.props.get("AssemblyLinearVelocity") or Vector3()
    attrs = model.attrs
    print(f"{label:28s} pos=({cf.p[0]:7.1f},{cf.p[1]:6.1f},{cf.p[2]:7.1f}) v={v.mag():6.1f} "
          f"mode={attrs.get('Mode')} rider={attrs.get('RiderUserId')} visual={'yes' if model.find_child('Visual') else 'no'}")
    return model, root, cf, v


def run(seconds, sim, dt=1 / 60):
    sim.run_for(seconds, dt)


class Smoothness:
    """Tracks per-frame rotation deltas of every dragon joint + the root."""
    def __init__(self):
        self.prev = {}
        self.worst = {}
        self.label = ""

    @staticmethod
    def angle(r0, r1):
        # angle of R0^T R1 from the trace
        tr = sum(r0[i] * r1[i] for i in range(9))
        c = max(-1.0, min(1.0, (tr - 1) / 2))
        return math.acos(c)

    def sample(self, sim):
        folder = sim.services["Workspace"].find_child("Dragons")
        model = folder.find_child("Dragon_1001") if folder else None
        if not model:
            return
        vis = model.find_child("Visual")
        items = []
        root = model.find_child("Root")
        if root is not None:
            items.append(("ROOT", root.props.get("CFrame").r))
        if vis is not None:
            for d in vis.descendants():
                if d.cls.name == "Motor6D" and d.props.get("Name") != "MemJoint":
                    tr = d.props.get("Transform")
                    if tr is not None:
                        items.append((d.props.get("Name"), tr.r))
        for name, r in items:
            p = self.prev.get(name)
            if p is not None:
                a = self.angle(p, r)
                w = self.worst.get(name)
                if w is None or a > w[0]:
                    self.worst[name] = (a, self.label)
            self.prev[name] = r

    def report(self, dt, limit_dps=1500.0):
        rows = sorted(self.worst.items(), key=lambda kv: -kv[1][0])
        print(f"smoothness (max rotation per frame at {1/dt:.0f} fps; spike = faster than {limit_dps:.0f} deg/s):")
        bad = 0
        for name, (a, label) in rows[:8]:
            deg = math.degrees(a)
            flag = "  <-- SPIKE" if deg / dt > limit_dps else ""
            if flag:
                bad += 1
            print(f"   {name:12s} {deg:6.2f} deg/frame ({deg/dt:6.0f} deg/s)  during '{label}'{flag}")
        return bad


SMOOTH = Smoothness()


def main(render=False, fps=60):
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    base_physics = sim.physics

    def physics_and_monitor(s, dt):
        base_physics(s, dt)
        SMOOTH.sample(s)
    sim.physics = physics_and_monitor
    dt = 1 / fps
    player = sim.add_player()
    RENDER_SIM["player"] = player
    run(3, sim, dt)
    snap = snapshot(sim, "spawned")
    assert snap, "companion not spawned"
    model, root, cf, v = snap
    char = player.props.get("Character")
    hrp = char.find_child("HumanoidRootPart")
    print("character at", rbx_api.part_cframe(sim, hrp).p)

    # walk the character away: the dragon should follow on foot
    gy = sim.haven.height_at(70, 120) if getattr(sim, "haven", None) else 0
    hrp.props["CFrame"] = CFrame((70, gy + 4.5, 120))
    run(5, sim, dt)
    model, root, cf, v = snapshot(sim, "after follow (char 70,-40)")
    d = math.hypot(cf.p[0] - 70, cf.p[2] - 120)
    print(f"   follow distance {d:.1f}")
    print("   plot:", player.attrs.get("PlotId"))

    # mount with R
    key(sim, player, "R", True)
    run(0.1, sim, dt)
    key(sim, player, "R", False)
    run(1.0, sim, dt)
    model, root, cf, v = snapshot(sim, "mounted")
    assert model.attrs.get("RiderUserId") == 1001, "mount failed"
    joint = root.find_child("RiderJoint")
    print("   rider joint:", joint is not None, " platformstand:", char.find_child("Humanoid").props.get("PlatformStand"))

    # run forward (camera faces dragon heading after mount)
    start = cf.p
    key(sim, player, "W", True)
    run(3, sim, dt)
    model, root, cf, v = snapshot(sim, "ran 3s")
    print(f"   ran {math.dist(start, cf.p):.1f} studs")
    key(sim, player, "LeftShift", True)
    run(1.5, sim, dt)
    snapshot(sim, "sprint 1.5s")
    key(sim, player, "LeftShift", False)

    # jump + hold to take off
    key(sim, player, "Space", True)
    for i in range(6):
        run(0.15, sim, dt)
        snapshot(sim, f"  space held {0.15*(i+1):.2f}s")
    run(1.0, sim, dt)
    snapshot(sim, "climbing (space)")
    key(sim, player, "Space", False)
    run(3, sim, dt)
    snapshot(sim, "flying W 3s")
    key(sim, player, "LeftShift", True)
    run(2, sim, dt)
    snapshot(sim, "boost 2s")
    key(sim, player, "LeftShift", False)
    key(sim, player, "W", False)
    run(2, sim, dt)
    snapshot(sim, "released (hover)")
    key(sim, player, "LeftControl", True)
    for i in range(8):
        run(0.75, sim, dt)
        snapshot(sim, f"  descending {0.75*(i+1):.2f}s")
    key(sim, player, "LeftControl", False)
    run(1, sim, dt)
    snapshot(sim, "landed?")
    if render:
        render_frame(sim, player, "/tmp/claude-0/out/ride_ground.png")
    # dismount
    key(sim, player, "R", True)
    run(0.1, sim, dt)
    key(sim, player, "R", False)
    run(1.5, sim, dt)
    model, root, cf, v = snapshot(sim, "dismounted")
    print("   rider joint after:", root.find_child("RiderJoint") is not None,
          " platformstand:", char.find_child("Humanoid").props.get("PlatformStand"))
    spikes = SMOOTH.report(dt)
    print("animation spikes:", spikes)
    errs = sim.errors
    print("ERRORS:", len(errs))
    for e in errs[:10]:
        print("  ", e)
    return sim, player


def render_frame(sim, player, out, size=(1280, 720)):
    import preview3d
    client = client_of(player)
    cam = None
    for d in sim.services["Workspace"].children:
        if d.cls.name == "Camera":
            cam = d
    ccf = client.__dict__.get("camera_cf")
    parts = preview3d.part_records(sim)
    cam_inst = getattr(client, "camera", None) or cam
    _cf = cam_inst.props.get("CFrame") if cam_inst is not None else None
    terrain = None
    if _cf is not None:
        cx, cz = _cf.p[0], _cf.p[2]
        terrain = preview3d.terrain_heightfield(sim, cx - 900, cz - 900, cx + 900, cz + 900, step=6)
    cf = cam_inst.props.get("CFrame") if cam_inst is not None else CFrame((0, 30, 60))
    fov = cam_inst.props.get("FieldOfView", 70) if cam_inst is not None else 70
    look = cf.vector_to_world(Vector3(0, 0, -1))
    camd = {"pos": list(cf.p), "target": [cf.p[0] + look.x * 30, cf.p[1] + look.y * 30, cf.p[2] + look.z * 30],
            "fov": fov}
    preview3d.render(parts, camd, out, w=size[0], h=size[1], fog_density=0.0015, terrain=terrain,
                     shadow_center=[cf.p[0] + look.x * 30, 0, cf.p[2] + look.z * 30], shadow_extent=60)
    print("rendered", out)


if __name__ == "__main__":
    for a in sys.argv[1:]:
        if a.startswith("--at="):
            RENDER_AT.update(a[5:].split(","))
    main(render="--render" in sys.argv, fps=int(os.environ.get("FPS", "60")))
