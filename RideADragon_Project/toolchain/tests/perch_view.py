"""Renders skinned mesh dragons resting on sanctuary perches (Rest / Sleep /
standing moods) from a visitor's point of view."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "meshgen"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "worldgen"))
import build_place  # noqa: E402
import rbx_physics  # noqa: E402
import rbx_api  # noqa: E402
import preview3d  # noqa: E402
import luau_interp as LI  # noqa: E402
from rbx_sim import Sim  # noqa: E402
from sim_runner import PROJECT, run_client_lua, lua_table_to_py  # noqa: E402
import skin_render  # noqa: E402
from PIL import Image  # noqa: E402
import paths  # noqa: E402

from paths import OUT  # noqa: E402


def main(moods=("Rest", "Sleep", "Ground")):
    sim = Sim(instant_tweens=True, signal_behavior="Deferred")
    name, tree = build_place.load_project(PROJECT)
    build_place.load_into_sim(sim, tree)
    import sim_runner as _SR
    import terrain_data as _TD
    _TD.inject_into_sim(sim, _SR._haven_cache())
    skin_render.make_template(sim, "GreenDrake", parent=sim.services["Workspace"])
    sim.start()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player()
    sim.run_for(3, 1 / 30)
    ctx = sim.server_ctx
    src = '''
local SSS = game:GetService("ServerScriptService")
local PDS = require(SSS.Services.PlayerDataService)
local DS = require(SSS.Services.DragonService)
local p = game:GetService("Players"):GetPlayers()[1]
PDS.Set(p, { "Cash" }, 10000000)
PDS.Set(p, { "Nests", "Unlocked" }, 3)
local ids = {}
for i, m in { "None", "Golden", "Shadow", "None" } do
	local r = DS.Add(p, "GreenDrake", m, "Test")
	table.insert(ids, r.UniqueId)
end
shared.IDS = ids
'''
    fn = LI.load(src, "grant", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn)
    ids = lua_table_to_py(ctx.shared.get("IDS"))
    for i in range(3):
        run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Dragon", "Place", {{ Id = "{ids[i]}", Slot = {i + 1} }})
shared.PL = r.ok
''')
    sim.run_for(3, 1 / 30)
    ws = sim.services["Workspace"]
    pd = ws.find_child("PerchDragons")
    plot = player.attrs.get("PlotId")
    perch_models = sorted([m for m in pd.children if m.attrs.get("PlotId") == plot], key=lambda m: m.attrs.get("Slot"))
    print("perch dragons:", [(m.props.get("Name"), m.find_child("Visual") is not None) for m in perch_models])
    skin = skin_render.Skinner()
    imgs = [Image.open(f"{paths.MESHGEN_OUT}/GreenDrake_{k}.png").convert("RGB") for k in ("color", "normal", "mr")]
    paths = []
    for mood in moods:
        run_client_lua(sim, player, f'''
local AC = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.AnimationController)
for _, m in workspace.PerchDragons:GetChildren() do
	local e = AC.get(m)
	if e and e.Anim then
		e.Anim.Params.Mode = "{mood}"
		e.Anim:Snap("{mood}" == "Ground" and "Idle" or "{mood}")
		e.MoodTime = 1000
		e.NextShot = 1000
	end
end
''')
        sim.run_for(0.6, 1 / 30)
        ents = []
        for m in perch_models:
            vis = m.find_child("Visual")
            meshes = [d for d in vis.descendants() if d.cls.name == "MeshPart"] if vis else []
            if not meshes:
                continue
            V, N, T4 = skin.pose(sim, meshes[0], scale=0.62)
            ents.append(preview3d.texmesh_entry(V, skin.F, N, skin.UV, imgs[0], imgs[1], imgs[2], T4))
        parts = preview3d.part_records(sim)
        # camera: from the nest looking at perches 1-3 (back of the horseshoe)
        res = run_client_lua(sim, player, f'''
local WC = require(game:GetService("ReplicatedStorage").Configs.WorldConfig)
local f = WC.plotFrame({int(plot)})
local eye = f * CFrame.new(-6, 13, -14)
local at = f * CFrame.new(-8, 3, 26)
shared.CAM = {{ eye.X, eye.Y, eye.Z, at.X, at.Y, at.Z }}
''')
        c = lua_table_to_py(res.get("CAM"))
        cam = {"pos": c[:3], "target": c[3:], "fov": 55}
        sc = preview3d.make_scene(parts, cam, fog_density=0.0008, shadow_center=c[3:], shadow_extent=60)
        sc["texMeshes"] = ents
        out = f"{OUT}/perch_{mood}.png"
        preview3d.render_batch([(sc, out, 900, 560)])
        paths.append(out)
    preview3d.contact_sheet(paths, list(moods), f"{OUT}/perch_sheet.png", cols=2)
    print("errors", len(sim.errors), sim.errors[:5])


if __name__ == "__main__":
    main()
