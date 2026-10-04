"""Resolution matrix QA for the dragon collection: Inventory + Details on all
devices, every player owning a full collection (virtualized grid exercised)."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import ui_qa  # noqa: E402

GRANT = r'''
local SSS = game:GetService("ServerScriptService")
local PDS = require(SSS.Services.PlayerDataService)
local DS = require(SSS.Services.DragonService)
for _, p in game:GetService("Players"):GetPlayers() do
	PDS.Set(p, { "Upgrades", "DragonStorage" }, 2)
	PDS.Set(p, { "Cash" }, 2500000)
	local species = { "InfernoDragon", "FrostDragon", "ThunderDragon", "AquaSerpent", "CrystalWyvern", "ForestWyvern", "GreenDrake" }
	local muts = { "Golden", "None", "Shadow", "Shiny", "None", "Rainbow", "None" }
	for i = 1, 38 do
		DS.Add(p, species[i % 7 + 1], muts[(i * 3) % 7 + 1], "Test")
	end
	-- a placed + a locked dragon so every tag shows somewhere
	local first
	for uid, rec in PDS.Get(p).Dragons do
		if rec.SpeciesId == "FrostDragon" and not first then
			first = uid
		end
	end
	if first then
		PDS.Set(p, { "Dragons", first, "Locked" }, true)
	end
end
'''


def setup(sim, players):
    ctx = sim.server_ctx
    fn = LI.load(GRANT, "grant", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn)
    sim.step(1 / 60, 30)


if __name__ == "__main__":
    screens = sys.argv[1].split(",") if len(sys.argv) > 1 else ["Inventory", "Details"]
    devs = sys.argv[2].split(",") if len(sys.argv) > 2 else None
    t0 = time.time()
    summary, errs, sim, players = ui_qa.run(screens, devs, setup=setup)
    for screen, dev, status, issues in summary:
        print(f"{screen:14s} {dev:16s} {status}")
        for i in issues[:8]:
            print("     -", i.get("Kind"), i.get("Message"))
    print("runtime errors:", len(errs))
    for e in errs[:10]:
        print("  ", e)
    print(f"done in {time.time() - t0:.1f}s")
