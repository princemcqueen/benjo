"""Egg luck + new egg types + dragon fetch: world eggs carry luck (label),
pickup keeps it, nest keeps it, hatch applies it; companion fetches eggs."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py, render as ui_render  # noqa: E402

OUT = "/tmp/claude-0/out"
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
local PDS = require(SSS.Services.PlayerDataService)
local ES = require(SSS.Services.EggService)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, domain, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("{domain}", "{action}", {payload})
shared.RQ = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", data = r.data }}
''')
    return lua_table_to_py(res.get("RQ"))


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    p1 = sim.add_player("Player1", 1001)
    sim.run_for(6, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))
    act = srv(sim, '''
local n, lucky, types = 0, 0, {}
for _, e in ES.GetActive(p) do
	n += 1
	if (e.Luck or 1) > 1 then lucky += 1 end
	types[e.Type] = (types[e.Type] or 0) + 1
end
shared.R = { n = n, lucky = lucky, types = types }
''')
    print("active", act)
    check(act["n"] >= 12, "more eggs spawn (%s active)" % act["n"])
    # client labels
    lab = run_client_lua(sim, p1, '''
local f = workspace:FindFirstChild("MyEggs")
local n, labels, sample = 0, 0, ""
for _, m in f and f:GetChildren() or {} do
	n += 1
	local bb = m.PrimaryPart and m.PrimaryPart:FindFirstChild("LuckLabel")
	if bb then labels += 1; sample = bb.Luck.Text .. " / " .. bb.EggName.Text end
end
shared.L = { n = n, labels = labels, sample = sample }
''')
    L = lua_table_to_py(lab.get("L"))
    print("labels", L)
    check(L["labels"] == L["n"] and L["n"] > 0, "every world egg shows its luck label (%s)" % L["sample"])
    # inject a x50 Golden egg right next to the player and let the companion fetch it
    inj = srv(sim, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local hrp = p.Character.HumanoidRootPart
local st = nil
for k, v in ES.GetActive(p) do st = v break end
local pos = hrp.Position + hrp.CFrame.LookVector * 30 + Vector3.new(0, -1, 0)
local egg = { Key = "kTEST", Type = "GoldenEgg", Position = pos, Area = "Test", Luck = 50 }
ES.GetActive(p)["kTEST"] = egg
Net.signal(p, "EggAdded", { Key = egg.Key, Type = egg.Type, Position = egg.Position, Area = egg.Area, Luck = egg.Luck })
shared.R = { pos = tostring(pos), bag = #d.Eggs }
''')
    print("inject", inj)
    sim.run_for(14, 1 / 30)
    bag = srv(sim, '''
local found = nil
for _, e in d.Eggs do if e.Type == "GoldenEgg" then found = e end end
shared.R = { bag = #d.Eggs, golden = found ~= nil, luck = found and found.Luck or 0, active = ES.GetActive(p)["kTEST"] ~= nil }
''')
    print("after fetch", bag)
    check(bag["golden"] and bag["luck"] == 50, "companion fetched the x50 Golden egg into the bag")
    # place + hatch with luck
    r = req(sim, p1, "Egg", "Place", '{}')
    print("place", r)
    slot = srv(sim, '''
local s = d.Incubator.Slots["1"]
shared.R = { type = s and s.Type or "", luck = s and s.Luck or 0 }
''')
    print("slot", slot)
    check(slot["type"] == "GoldenEgg" and slot["luck"] == 50, "best egg (Golden x50) placed in the nest with its luck")
    srv(sim, 'local s = table.clone(d.Incubator.Slots["1"]); s.Ready = os.time() - 1; PDS.Set(p, { "Incubator", "Slots", "1" }, s); shared.R = {}')
    h = req(sim, p1, "Egg", "Hatch", '{ Slot = 1 }')
    rec = (h.get("data") or {}).get("Dragon") or {}
    print("hatch", h.get("ok"), rec.get("SpeciesId"), rec.get("Mutation"), rec.get("Odds"), (h.get("data") or {}).get("Luck"))
    check(h["ok"] and (h["data"] or {}).get("Luck") == 50, "hatch used the egg's x50 luck")
    ui_render(sim, p1, f"{OUT}/eggluck_hud.png", debug=False)
    print("ERRORS:", len(sim.errors), sim.errors[:4])
    print("FAILED:", FAIL)
    print("done in %ds" % (time.time() - t0))


if __name__ == "__main__":
    main()
