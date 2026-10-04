"""Server-wide announcements of ultra-rare hatches: everyone sees the banner after the
hatcher's reveal; common results are silent; banners queue up."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402

FAIL = []


def check(cond, label):
    print(("  ok   " if cond else "  FAIL ") + label)
    if not cond:
        FAIL.append(label)


def srv(sim, src):
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    head = '''
local SSS = game:GetService("ServerScriptService")
local ES = require(SSS.Services.EggService)
local HatchConfig = require(game:GetService("ReplicatedStorage").Configs.HatchConfig)
local p1 = game:GetService("Players"):GetPlayers()[1]
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def banner(sim, player):
    res = run_client_lua(sim, player, '''
local pg = game:GetService("Players").LocalPlayer.PlayerGui
local b = pg:FindFirstChild("RareBanner", true)
local out = { shown = b ~= nil }
if b then
	local head = b:FindFirstChild("Headline", true)
	local odds = b:FindFirstChild("Odds", true)
	out.head = head and head.Text or ""
	out.odds = odds and odds.Text or ""
	out.rainbow = b:GetAttribute("Rainbow") == true
end
shared.R = out''')
    return lua_table_to_py(res.get("R"))


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    p1 = sim.add_player("Alice", 1001)
    p2 = sim.add_player("Bob", 1002)
    sim.run_for(5, 1 / 30)

    r = srv(sim, '''
local rec = { SpeciesId = "VoidDragon", Mutation = "Rainbow", Rarity = "Secret" }
local low = ES.announceHatch(p1, rec, 24999)
local at = ES.announceHatch(p1, rec, HatchConfig.Announce.MinOdds)
shared.R = { low = low, at = at, delay = HatchConfig.Announce.Delay }''')
    check(r["low"] is False, "below 1 in 25,000 nothing is announced")
    check(r["at"] is True, "exactly 1 in 25,000 is announced")
    sim.run_for(3, 1 / 30)
    check(not banner(sim, p1)["shown"] and not banner(sim, p2)["shown"], "no spoiler: nobody sees the banner during the reveal")
    sim.run_for(r["delay"] - 3 + 1.2, 1 / 30)
    b1, b2 = banner(sim, p1), banner(sim, p2)
    check(b1["shown"] and b2["shown"], "after the reveal every player sees the banner (hatcher and others)")
    check("Alice" in b2["head"] and "VOID DRAGON" in b2["head"] and "RAINBOW" in b2["head"], f"banner names the player and the dragon ({b2['head']})")
    check("25,000" in b2["odds"], f"banner shows the odds ({b2['odds']})")
    check(b2["rainbow"] is False, "normal banners have no rainbow outline")
    sim.run_for(8.5, 1 / 30)
    check(not banner(sim, p2)["shown"], "the banner leaves again after a few seconds")

    # mega
    srv(sim, '''
ES.announceHatch(p1, { SpeciesId = "GoldenEmperor", Mutation = "Void", Rarity = "Legendary" }, 12500000)
shared.R = {}''')
    sim.run_for(8.5 + 1.2, 1 / 30)
    b = banner(sim, p2)
    check(b["shown"] and b["rainbow"] is True and "MEGA" in b["odds"], f"1 in 12.5M gets the mega banner ({b['odds']})")
    sim.run_for(10.5, 1 / 30)
    check(not banner(sim, p2)["shown"], "mega banner leaves after its longer stay")

    # queue: five at once -> one showing + at most 3 waiting (the oldest waiting one is dropped)
    srv(sim, '''
for i = 1, 5 do
	ES.announceHatch(p1, { SpeciesId = "VoidDragon", Mutation = "None", Rarity = "Secret" }, 30000 + i)
end
shared.R = {}''')
    sim.run_for(8.5 + 0.8, 1 / 30)
    seen = []
    for _ in range(40):
        b = banner(sim, p2)
        if b["shown"] and (not seen or seen[-1] != b["odds"]):
            seen.append(b["odds"])
        sim.run_for(1.0, 1 / 30)
    print("sequence:", seen)
    check(len(seen) == 4, f"banners queue and play one after another ({len(seen)} shown, 1 dropped)")
    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
