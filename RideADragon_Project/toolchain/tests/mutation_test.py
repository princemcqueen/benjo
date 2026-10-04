"""Mutations: config invariants and that every mutation really changes the dragon
(palette, materials, particles, light, wing trails, halo, crystals)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import preview3d  # noqa: E402
import rbx_api  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, lua_table_to_py  # noqa: E402
from paths import OUT  # noqa: E402

FAIL = []


def check(cond, label):
    print(("  ok   " if cond else "  FAIL ") + label)
    if not cond:
        FAIL.append(label)


def srv(sim, src):
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    fn = LI.load(src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


CONFIG = '''
local C = require(game:GetService("ReplicatedStorage").Configs.MutationConfig)
local Odds = require(game:GetService("ReplicatedStorage").Shared.Odds)
local ranksOk, multOk, chanceOk = true, true, true
local lastRank, lastMult, lastChance = -1, 0, 1
local rollable = 0
for i, id in C.Order do
	local m = C.Mutations[id]
	if m.Rank ~= i - 1 then ranksOk = false end
	if m.Multiplier < lastMult then multOk = false end
	lastMult = m.Multiplier
	if i > 2 and id ~= "Omni" then
		if m.HatchChance >= lastChance then chanceOk = false end
		lastChance = m.HatchChance
		rollable += 1
	end
	if i == 2 then lastChance = m.HatchChance rollable += 1 end
end
local weights = {}
for _, e in C.MutateWeights do weights[e.Id] = e.Weight end
local missing = {}
for _, id in C.Order do
	if id ~= "None" and id ~= "Omni" and not weights[id] then table.insert(missing, id) end
end
shared.R = {
	count = #C.Order, ranksOk = ranksOk, multOk = multOk, chanceOk = chanceOk, rollable = rollable,
	maxRank = C.MaxRank, voidRank = C.Mutations.Void.Rank, omniRank = C.Mutations.Omni.Rank,
	missing = missing, improveVoid = C.improveChance("Void"), improveAngelic = C.improveChance("Angelic"),
	improveNone = C.improveChance("None"),
	noneMiss = Odds.mutationChance("None"),
	angelicOdds = Odds.mutationChance("Angelic"),
}
'''

BUILD = '''
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Configs.MutationConfig)
local DV = require(RS.Shared.Dragons.DragonVisual)
local BB = require(RS.Shared.Dragons.BrickBuilder)
local Species = require(RS.Shared.Dragons.Species)
local species = "%s"
local out = {}
local folder = Instance.new("Folder")
folder.Name = "MutationShowcase"
folder.Parent = workspace
local x = 0
for i, id in C.Order do
	local model = DV.build(species, { Mutation = id, Detail = "High", Saddle = false })
	local info = { parts = 0, emitters = 0, lights = 0, trails = 0, halo = 0, crystal = 0, neon = 0, glass = 0, mainColor = "" }
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			info.parts += 1
			if d.Name == "Halo" then info.halo += 1 end
			if d.Name == "Crystal" then info.crystal += 1 end
			if d.Material == Enum.Material.Neon then info.neon += 1 end
			if d.Material == Enum.Material.Glass then info.glass += 1 end
		elseif d:IsA("ParticleEmitter") and d.Name == "MutationFx" then
			info.emitters += 1
		elseif d:IsA("PointLight") and d.Name == "MutationLight" then
			info.lights += 1
		elseif d:IsA("Trail") and d.Name == "MutationTrail" then
			info.trails += 1
		end
	end
	local body = model:FindFirstChild("Body", true)
	info.mainColor = body and body.Color:ToHex() or ""
	info.mutationAttr = model:GetAttribute("Mutation") or ""
	local spec = BB.MutationFx[id]
	info.specParticles = spec and spec.Particles and #spec.Particles or 0
	info.specLight = spec ~= nil and spec.Light ~= nil
	info.specTrail = spec ~= nil and spec.Trail ~= nil
	out[id] = info
	model:PivotTo(CFrame.new(x, 500, 0))
	model.Parent = folder
	x += 60
end
shared.R = out
'''


BREATH = '''
local RS = game:GetService("ReplicatedStorage")
local C = require(RS.Configs.MutationConfig)
local DV = require(RS.Shared.Dragons.DragonVisual)
local BreathFX = require(RS.Shared.Dragons.BreathFX)
local out, mids, ok = {}, {}, true
for _, id in C.Order do
	local model = DV.build("GreenDrake", { Mutation = id, Detail = "High", Saddle = false })
	model.Parent = workspace
	BreathFX.start(model)
	local flame = model:FindFirstChild("Flame", true)
	local theme = BreathFX.Themes[id]
	local matches = flame ~= nil and theme ~= nil and flame.Color.Keypoints[1].Value == theme.Core and flame.Color.Keypoints[2].Value == theme.Mid
	if not matches then ok = false end
	if theme then mids[theme.Mid:ToHex()] = true end
	BreathFX.stop(model)
	model:Destroy()
end
local distinct = 0
for _ in mids do distinct += 1 end
shared.R = { ok = ok, distinct = distinct }
'''


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    sim.add_player()
    sim.run_for(3, 1 / 30)

    r = srv(sim, CONFIG)
    print({k: v for k, v in r.items() if k != "missing"})
    check(r["count"] == 18, f"18 entries in the mutation list ({r['count']})")
    check(r["ranksOk"] is True, "rank = position in the order list")
    check(r["multOk"] is True, "multipliers never go down along the list")
    check(r["chanceOk"] is True, "hatch chances get rarer along the list")
    check(r["maxRank"] == r["voidRank"] and r["omniRank"] == r["voidRank"] + 1, "Void is the best rollable mutation, Omni is beyond it")
    check(not r["missing"], f"every rollable mutation has a MUTATE weight ({r['missing']})")
    check(r["improveNone"] == 1 or abs(r["improveNone"] - 1) < 1e-9, "a normal dragon can always improve")
    check(r["improveVoid"] == 0 and 0 < r["improveAngelic"] < 0.1, "Void cannot improve; Angelic improves rarely")
    check(abs(r["angelicOdds"] - 1 / 70000) < 1e-9, "Angelic is 1 in 70,000 per hatch")

    for species in ("GreenDrake", "PhoenixDrake"):
        print(f"--- {species}")
        info = srv(sim, BUILD % species)
        base = info["None"]
        new = ["Neon", "Infernal", "Corrupted", "Crystal", "Lightning", "Angelic"]
        for mid in new:
            i = info[mid]
            check(i["mutationAttr"] == mid, f"{mid}: model carries the mutation")
            check(i["mainColor"] != base["mainColor"], f"{mid}: body colour differs from the normal dragon ({base['mainColor']} -> {i['mainColor']})")
            check(i["emitters"] == i["specParticles"] and i["emitters"] >= 2, f"{mid}: {i['emitters']} particle emitters")
            check(i["lights"] == 1, f"{mid}: lights up its surroundings")
        for mid in ("Neon", "Infernal", "Lightning", "Angelic"):
            check(info[mid]["trails"] == 2, f"{mid}: ribbons behind both wing tips ({info[mid]['trails']})")
        check(info["Corrupted"]["trails"] == 0 and info["Crystal"]["trails"] == 0, "Corrupted / Crystal have no wing trails")
        check(info["Neon"]["neon"] > base["neon"] + 20, f"Neon: many glowing plates ({info['Neon']['neon']} vs {base['neon']})")
        check(info["Crystal"]["glass"] > base["glass"] + 20, f"Crystal: translucent body ({info['Crystal']['glass']} glass parts)")
        check(info["Crystal"]["crystal"] >= 6, f"Crystal: crystal clusters ({info['Crystal']['crystal']})")
        check(info["Angelic"]["halo"] >= 8, f"Angelic: a halo ring ({info['Angelic']['halo']} segments)")
        check(info["Neon"]["halo"] == 0 and info["Crystal"]["halo"] == 0, "only Angelic wears a halo")
        # ordering of looks: every mutation has its own colour
        colours = {info[m]["mainColor"] for m in info if m not in ("None",)}
        check(len(colours) >= 14, f"mutations look different from each other ({len(colours)} distinct body colours)")
        if species == "GreenDrake":
            # picture of the whole row
            ws = sim.services["Workspace"]
            parts = preview3d.part_records(sim, ws.find_child("MutationShowcase"))
            jobs, outs = [], []
            ids = list(info.keys())
            order = ["None", "Shiny", "Neon", "Golden", "Frost", "Toxic", "Lava", "Infernal", "Shadow", "Corrupted",
                     "Diamond", "Crystal", "Lightning", "Angelic", "Galaxy", "Rainbow", "Void", "Omni"]
            for i, mid in enumerate(order):
                cx = i * 60
                cam = preview3d.orbit_camera([cx, 502, 0], 46, 38, 14, fov=38)
                scene = preview3d.make_scene(parts, cam, fog_density=0.0002, shadow_center=[cx, 500, 0], shadow_extent=40)
                path = f"{OUT}/mut_{mid}.png"
                jobs.append((scene, path, 420, 330))
                outs.append((path, mid))
            preview3d.render_batch(jobs)
            preview3d.contact_sheet([o[0] for o in outs], [o[1] for o in outs], f"{OUT}/mutation_sheet.png", cols=6)
            print("sheet:", f"{OUT}/mutation_sheet.png")
            del ids
        srv(sim, 'local f = workspace:FindFirstChild("MutationShowcase") if f then f:Destroy() end shared.R = {}')

    r = srv(sim, BREATH)
    check(r["ok"] is True, "every mutation breathes in its own theme colours")
    check(r["distinct"] >= 8, f"breath themes are clearly different ({r['distinct']} distinct flame colours)")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
