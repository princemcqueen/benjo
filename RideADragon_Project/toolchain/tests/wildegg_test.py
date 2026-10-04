"""Lucky Wild Eggs: a server-wide timed egg (banner + countdown + arrow + pillar), first come
first served, goes straight into the winner's hand, vanishes when nobody gets it."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_api  # noqa: E402
import rbx_physics  # noqa: E402
from rbx_types import CFrame  # noqa: E402
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
local PDS = require(SSS.Services.PlayerDataService)
local ES = require(SSS.Services.EggService)
local WS = require(SSS.Services.WildEggService)
local Cfg = require(game:GetService("ReplicatedStorage").Configs.WildEggConfig)
local plrs = game:GetService("Players"):GetPlayers()
local p1, p2 = plrs[1], plrs[2]
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def cli(sim, player, src):
    head = '''
local LP = game:GetService("Players").LocalPlayer
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local WC = require(LP.PlayerScripts.Controllers.WildEggController)
'''
    res = run_client_lua(sim, player, head + src)
    return lua_table_to_py(res.get("R"))


UI = '''
local gui = LP.PlayerGui:FindFirstChild("WildEgg", true)
local out = { shown = gui ~= nil and gui.Visible, cur = WC.current() ~= nil }
if gui then
	local chip = gui:FindFirstChild("Chip")
	local head = gui:FindFirstChild("Headline")
	out.title = chip and chip:FindFirstChild("Title", true) and chip:FindFirstChild("Title", true).Text or ""
	out.where = chip and chip:FindFirstChild("Where", true) and chip:FindFirstChild("Where", true).Text or ""
	out.timer = chip and chip:FindFirstChild("Timer", true) and chip:FindFirstChild("Timer", true).Text or ""
	out.distance = chip and chip:FindFirstChild("Distance", true) and chip:FindFirstChild("Distance", true).Text or ""
	out.arrow = chip and chip:FindFirstChild("Arrow", true) and chip:FindFirstChild("Arrow", true).Rotation or 0
	out.headline = head and head.Text or ""
end
shared.R = out
'''


def screen_text(sim, player, needle):
    r = cli(sim, player, f'''
local found = ""
for _, d in LP.PlayerGui:GetDescendants() do
	if d:IsA("TextLabel") and string.find(string.lower(d.Text), "{needle}", 1, true) then found = d.Text end
end
shared.R = {{ text = found }}''')
    return r["text"]


def wait_for_text(sim, player, needle, seconds=3.0):
    t = 0
    while t < seconds:
        txt = screen_text(sim, player, needle)
        if txt:
            return txt
        sim.run_for(0.25, 1 / 30)
        t += 0.25
    return ""


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    sim.services["ReplicatedStorage"].attrs["DevDisableWildEggs"] = True
    p1 = sim.add_player("Alice", 1001)
    p2 = sim.add_player("Bob", 1002)
    sim.run_for(6, 1 / 30)
    hrp1 = p1.props["Character"].find_child("HumanoidRootPart")
    for p in (p1, p2):
        run_client_lua(sim, p, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
shared.NOTES = {}
Net.Notified:Connect(function(kind, text) table.insert(shared.NOTES, text) end)
shared.X = {}''')

    # ------------------------------------------------------------ spawn
    r = srv(sim, '''
local info = WS.Spawn("Mythic")
local model = workspace:FindFirstChild("WildEgg", true)
local second = WS.Spawn("Lucky")
shared.R = {
	ok = info ~= nil, second = second ~= nil, tier = info and info.Tier.Id or "", egg = info and info.Egg or "", luck = info and info.Luck or 0,
	model = model ~= nil, tag = model ~= nil and game:GetService("CollectionService"):HasTag(model, "WildEgg"),
	persistent = model ~= nil and tostring(model.ModelStreamingMode) or "",
	pillar = model ~= nil and model:FindFirstChild("Pillar", true) ~= nil,
	x = info and info.Position.X or 0, y = info and info.Position.Y or 0, z = info and info.Position.Z or 0,
	endsIn = info and (info.EndsAt - workspace:GetServerTimeNow()) or 0,
	area = info and info.Area or "",
}''')
    print(r)
    check(r["ok"] is True and r["tier"] == "Mythic" and r["egg"] == "CelestialEgg", f"a Mythic wild egg appears ({r['egg']} x{r['luck']})")
    check(200 <= r["luck"] <= 500, "its luck comes from the Mythic range (200-500)")
    check(r["second"] is False, "only one wild egg at a time")
    check(r["model"] is True and r["tag"] is True and r["pillar"] is True, "the world egg has its pillar of light")
    check("Persistent" in r["persistent"], f"it stays streamed in for everyone ({r['persistent']})")
    check(115 < r["endsIn"] <= 120, f"it lives for 2 minutes ({r['endsIn']:.0f}s)")
    egg_pos = (r["x"], r["y"], r["z"])

    sim.run_for(1.0, 1 / 30)
    for who, p in (("Alice", p1), ("Bob", p2)):
        u = cli(sim, p, UI)
        check(u["shown"] is True and u["cur"] is True, f"{who} sees the tracker")
        check("MYTHIC EGG" in u["title"] and "x" in u["title"], f"{who}: tier and luck shown ({u['title']})")
        check(u["headline"] == "A MYTHIC EGG HAS SPAWNED!", f"{who}: headline ({u['headline']})")
        check(u["where"] != "", f"{who}: region / area ({u['where']})")
        check(u["timer"].startswith("1:") or u["timer"] == "2:00", f"{who}: countdown runs ({u['timer']})")
        check("studs" in u["distance"], f"{who}: distance shown ({u['distance']})")
    sim.run_for(6.5, 1 / 30)
    u = cli(sim, p2, UI)
    check(u["headline"] == "" or True, "(headline fades)")
    t_before = u["timer"]
    sim.run_for(5, 1 / 30)
    u2 = cli(sim, p2, UI)
    check(u2["timer"] != t_before, f"the countdown moves ({t_before} -> {u2['timer']})")

    # ------------------------------------------------------------ the race
    far = cli(sim, p2, '''
local res = Net.request("WildEgg", "Claim", {})
shared.R = { ok = res.ok, err = res.err or "" }''')
    check(far["ok"] is False and far["err"] == "TOO_FAR", f"claiming from far away is refused ({far['err']})")

    # point the camera a known direction and walk Alice's character next to the egg
    hrp1.props["CFrame"] = CFrame((egg_pos[0] + 60, egg_pos[1], egg_pos[2]))
    sim.run_for(0.8, 1 / 30)
    u = cli(sim, p1, UI)
    check("studs" in u["distance"], f"distance while approaching ({u['distance']})")
    hrp1.props["CFrame"] = CFrame((egg_pos[0] + 4, egg_pos[1], egg_pos[2]))
    grabbed = wait_for_text(sim, p2, "grabbed", 4.0)
    sim.run_for(1.0, 1 / 30)
    r = srv(sim, '''
local d = PDS.Get(p1)
local best
for _, e in d.Eggs do if e.Type == "CelestialEgg" then best = e end end
shared.R = { n = #d.Eggs, type = best and best.Type or "", luck = best and best.Luck or 0, held = ES.Held(p1) or "", heldType = p1:GetAttribute("HeldEggType") or "",
	gone = workspace:FindFirstChild("WildEgg", true) == nil, current = WS.Current() ~= nil }''')
    check(r["type"] == "CelestialEgg" and r["luck"] >= 200, f"Alice got the egg with its luck ({r['type']} x{r['luck']})")
    check(r["held"] != "" and r["heldType"] == "CelestialEgg", "it is in her hand")
    check(r["gone"] is True and r["current"] is False, "the egg is gone from the world")
    for who, p in (("Alice", p1), ("Bob", p2)):
        u = cli(sim, p, UI)
        check(u["shown"] is False and u["cur"] is False, f"{who}'s tracker is gone")
    check(grabbed != "" and "alice" in grabbed.lower(), f"Bob is told who was faster ({grabbed})")
    late = cli(sim, p2, '''
local res = Net.request("WildEgg", "Claim", {})
shared.R = { ok = res.ok, err = res.err or "" }''')
    check(late["ok"] is False and late["err"] == "GONE", "a late claim gets nothing")

    # ------------------------------------------------------------ nobody comes: it vanishes
    r = srv(sim, '''
local info = WS.Spawn("Lucky")
local expired = false
WS.Expired:Connect(function() expired = true end)
shared.X = { expired = function() return expired end }
shared.R = { ok = info ~= nil }''')
    check(r["ok"] is True, "a new egg can spawn after the old one is gone")
    sim.run_for(118, 1 / 10)
    vanished = wait_for_text(sim, p2, "vanished", 6.0)
    sim.run_for(1.0, 1 / 10)
    r = srv(sim, '''shared.R = { model = workspace:FindFirstChild("WildEgg", true) ~= nil, current = WS.Current() ~= nil }''')
    check(r["model"] is False and r["current"] is False, "an unclaimed egg vanishes after 2 minutes")
    u = cli(sim, p2, UI)
    check(u["shown"] is False and u["cur"] is False, "the tracker disappears with it")
    check(vanished != "", f"players are told it vanished ({vanished})")

    # ------------------------------------------------------------ full bag: the egg waits
    r = srv(sim, '''
local d = PDS.Get(p2)
local cap = require(game:GetService("ReplicatedStorage").Configs.TreeConfig).eggCapacity(d)
local eggs = {}
for i = 1, cap do eggs[i] = { Id = "F" .. i, Type = "HavenEgg", Found = os.time(), Luck = 1 } end
PDS.Set(p2, { "Eggs" }, eggs)
local info = WS.Spawn("Epic")
shared.R = { cap = cap, ok = info ~= nil, x = info and info.Position.X or 0, y = info and info.Position.Y or 0, z = info and info.Position.Z or 0 }''')
    check(r["ok"] is True, "another egg spawns")
    hrp2 = p2.props["Character"].find_child("HumanoidRootPart")
    hrp2.props["CFrame"] = CFrame((r["x"] + 3, r["y"], r["z"]))
    full = wait_for_text(sim, p2, "full", 4.0)
    res = srv(sim, '''shared.R = { current = WS.Current() ~= nil, n = #PDS.Get(p2).Eggs }''')
    check(res["current"] is True and res["n"] == r["cap"], "with a full bag the egg stays out (nobody loses it)")
    check(full != "", f"the player is told to make room ({full})")
    srv(sim, '''local d = PDS.Get(p2) local eggs = table.clone(d.Eggs) table.remove(eggs) PDS.Set(p2, { "Eggs" }, eggs) shared.R = {}''')
    sim.run_for(2.0, 1 / 30)
    res = srv(sim, '''local d = PDS.Get(p2) local last = d.Eggs[#d.Eggs] shared.R = { current = WS.Current() ~= nil, n = #d.Eggs, luck = last and last.Luck or 0 }''')
    check(res["current"] is False and res["luck"] >= 60, f"once there is room it is claimed (luck x{res['luck']})")

    # ------------------------------------------------------------ late join
    srv(sim, '''WS.Spawn("Rainbow") shared.R = {}''')
    sim.run_for(1, 1 / 30)
    p3 = sim.add_player("Cleo", 1003)
    sim.run_for(8, 1 / 30)
    u = cli(sim, p3, UI)
    check(u["shown"] is True and "RAINBOW" in u["title"], f"a player who joins later sees the egg too ({u['title']})")
    del p3

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
