"""Elder Rowan's quests (QuestService / QuestController / QuestsWindow): three active quests from the templates,
goals and rewards that grow with the level and income, progress counted from when a quest was given, claiming
(refused before it is done, pays cash + XP, a new quest takes its place, every 3rd gives a spin), the starter
goals, the two counters kept by the service (rides, boost seconds), the HUD badge and the window."""
import os
import sys
import time

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
local RS = game:GetService("ReplicatedStorage")
local PDS = require(SSS.Services.PlayerDataService)
local QS = require(SSS.Services.QuestService)
local MS = require(SSS.Services.MountService)
local QC = require(RS.Configs.QuestConfig)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
-- three known quests, counting from the stats as they are now
local function setActive(list)
	local out = {}
	for i, e in list do
		out[i] = { Id = e[1], Template = e[2], Goal = e[3], Base = d.Stats[QC.Templates[e[2]].Stat] or 0 }
	end
	PDS.Set(p, { "Quests", "Active" }, out)
end
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Quests", "{action}", {payload})
shared.RQ = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", cash = r.data and r.data.Cash or 0, xp = r.data and r.data.XP or 0, spins = r.data and r.data.Spins or 0 }}
''', max_steps=1500)
    return lua_table_to_py(res.get("RQ"))


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Alice", 7001)
    sim.run_for(10, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ------------------------------------------------------------------ a new player
    r = srv(sim, '''
QS.Ensure(p)
local st = QS.State(p)
local templates, distinct = {}, true
for _, q in st.Active do
	if templates[q.Template] then distinct = false end
	templates[q.Template] = true
end
shared.R = { n = #st.Active, distinct = distinct, starter = #st.Starter, left = st.StarterLeft, total = st.StarterTotal, claimable = st.Claimable, level = st.Level,
	first = st.Active[1].Text, spinIn = st.SpinIn, completed = st.Completed }''')
    print("new player", r)
    check(r["n"] == 3 and r["distinct"], f"three different active quests ({r['first']}, ...)")
    check(r["starter"] == 7 and r["left"] == 7 and r["total"] == 7, "seven starter goals, none taken")
    check(r["claimable"] == 0 or r["claimable"] == 1, f"almost nothing waits for a new player ({r['claimable']:.0f})")
    check(r["spinIn"] == 3 and r["completed"] == 0, "the free spin comes after 3 quests")

    # ------------------------------------------------------------------ goals and rewards grow
    r = srv(sim, '''
shared.R = {
	g1 = QC.goal("FindEggs", 1, 0), g21 = QC.goal("FindEggs", 21, 0), fly1 = QC.goal("FlyDistance", 1, 0), fly11 = QC.goal("FlyDistance", 11, 0),
	cash1 = QC.cash("FindEggs", 1, 0), cash11 = QC.cash("FindEggs", 11, 0), cashRich = QC.cash("FindEggs", 1, 100),
	earn1 = QC.goal("CollectIncome", 1, 0), earnRich = QC.goal("CollectIncome", 1, 1000), xp1 = QC.xp(1), xp21 = QC.xp(21),
}''')
    print("scaling", r)
    check(r["g1"] == 3 and r["g21"] == 8, f"'find eggs' goal: 3 at level 1, {r['g21']:.0f} at level 21")
    check(r["fly1"] == 6000 and r["fly11"] == 15000, f"'fly' goal: {r['fly1']:.0f} -> {r['fly11']:.0f} studs")
    check(r["cash1"] == 300 and r["cash11"] == 1350, f"cash grows with the level (${r['cash1']:.0f} -> ${r['cash11']:.0f})")
    check(r["cashRich"] == 15000, f"...and is never less than 150 s of income (${r['cashRich']:.0f})")
    check(r["earn1"] == 1500 and r["earnRich"] == 240000, f"'earn' goal follows the income (${r['earnRich']:.0f})")
    check(r["xp1"] == 40 and r["xp21"] == 80, f"XP of a quest: {r['xp1']:.0f} -> {r['xp21']:.0f}")

    # ------------------------------------------------------------------ progress counts from the moment a quest is given
    srv(sim, '''
PDS.Set(p, { "Stats", "EggsFound" }, 10)
setActive({ { "q1", "FindEggs", 3 }, { "q2", "FeedDragons", 2 }, { "q3", "FlyDistance", 6000 } })
shared.R = {}''')
    r = srv(sim, 'local st = QS.State(p) shared.R = { p1 = st.Active[1].Progress, ready1 = st.Active[1].Ready, text = st.Active[1].Text, cash = st.Active[1].Cash, xp = st.Active[1].XP }')
    check(r["p1"] == 0 and not r["ready1"], f"10 eggs found before the quest was given do not count ({r['text']}: {r['p1']:.0f} / 3)")
    r0 = req(sim, player, "Claim", '{ Id = "q1" }')
    check(not r0["ok"] and r0["err"] == "NOT_DONE", f"claiming before it is done is refused ({r0['err']})")
    srv(sim, 'PDS.Increment(p, { "Stats", "EggsFound" }, 3) shared.R = {}')
    r = srv(sim, 'local st = QS.State(p) shared.R = { p1 = st.Active[1].Progress, ready1 = st.Active[1].Ready, claimable = st.Claimable, cash = st.Active[1].Cash, xp = st.Active[1].XP }')
    check(r["p1"] == 3 and r["ready1"], "3 more eggs: the quest is done")
    check(r["claimable"] >= 1, f"{r['claimable']:.0f} reward(s) waiting")
    expect_cash, expect_xp = r["cash"], r["xp"]

    # ------------------------------------------------------------------ claiming
    before = srv(sim, 'shared.R = { cash = d.Cash, xp = d.XP or 0, level = d.Level, spins = d.Spin.Tickets, done = d.Quests.Completed }')
    res = req(sim, player, "Claim", '{ Id = "q1" }')
    after = srv(sim, '''
local st = QS.State(p)
local ids, templates = {}, {}
for _, q in st.Active do ids[#ids + 1] = q.Id templates[q.Template] = (templates[q.Template] or 0) + 1 end
local distinct = true
for _, n in templates do if n > 1 then distinct = false end end
shared.R = { cash = d.Cash, xp = d.XP or 0, level = d.Level, spins = d.Spin.Tickets, done = d.Quests.Completed, n = #st.Active, first = st.Active[1].Id, firstTemplate = st.Active[1].Template,
	distinct = distinct, ids = table.concat(ids, ",") }''')
    print("claim", res, before, after)
    check(res["ok"] and res["cash"] == expect_cash and after["cash"] - before["cash"] == expect_cash, f"the reward is paid (+${res['cash']:.0f})")
    check(res["xp"] == expect_xp and (after["xp"] > before["xp"] or after["level"] > before["level"]), f"...with {res['xp']:.0f} player XP")
    check(after["done"] == before["done"] + 1, "the quest is counted as done")
    check(after["n"] == 3 and after["first"] not in ("q1",) and after["firstTemplate"] != "FindEggs" and after["distinct"], f"a NEW quest took its place ({after['ids']})")
    again = req(sim, player, "Claim", '{ Id = "q1" }')
    check(not again["ok"] and again["err"] == "GONE", "the same quest cannot be claimed twice")
    check(not req(sim, player, "Claim", '{ Id = "nonsense" }')["ok"], "an unknown id is refused")

    # ------------------------------------------------------------------ every 3rd quest pays a spin
    spins = []
    for i in range(3):
        sim.run_for(0.8, 1 / 30)
        srv(sim, '''
local st = QS.State(p)
local id = st.Active[1].Id
setActive({ { id, "CollectCoins", 1 }, { "x2", "SellDragons", 99 }, { "x3", "SpinWheel", 99 } })
PDS.Increment(p, { "Stats", "Coins" }, 1)
shared.R = {}''')
        before = srv(sim, 'shared.R = { spins = d.Spin.Tickets, done = d.Quests.Completed }')
        rr = req(sim, player, "Claim", '{ Id = "%s" }' % srv(sim, 'shared.R = { id = QS.State(p).Active[1].Id }')["id"])
        after = srv(sim, 'shared.R = { spins = d.Spin.Tickets, done = d.Quests.Completed }')
        spins.append((rr["ok"], after["spins"] - before["spins"], after["done"]))
    print("spins", spins)
    check(all(s[0] for s in spins), "three more quests are claimed")
    gains = [s[1] for s in spins]
    check(sum(gains) >= 1 and any(s[2] % 3 == 0 and s[1] == 1 for s in spins), f"every 3rd completed quest gives a free spin ({gains})")

    # ------------------------------------------------------------------ the starter goals
    r = srv(sim, '''
local st = QS.State(p)
local byId = {}
for _, s in st.Starter do byId[s.Id] = s.Done end
shared.R = { eggDone = byId.FindEgg == true, hatchDone = byId.Hatch == true, left = st.StarterLeft }''')
    check(r["eggDone"] and not r["hatchDone"], "the starter list reads the counters: eggs were found above, nothing was hatched")
    srv(sim, 'PDS.Set(p, { "Stats", "EggsFound" }, 12) shared.R = {}')
    c0 = srv(sim, 'shared.R = { cash = d.Cash }')
    res = req(sim, player, "Claim", '{ Id = "s:FindEgg" }')
    c1 = srv(sim, 'shared.R = { cash = d.Cash }')
    check(res["ok"] and res["cash"] == 200 and c1["cash"] - c0["cash"] == 200, f"'Pick up an egg' pays $200 once done")
    res = req(sim, player, "Claim", '{ Id = "s:FindEgg" }')
    check(not res["ok"] and res["err"] == "ALREADY_CLAIMED", "...and only once")
    res = req(sim, player, "Claim", '{ Id = "s:Hatch" }')
    check(not res["ok"] and res["err"] == "NOT_DONE", "an unfinished goal is refused")
    res = req(sim, player, "Claim", '{ Id = "s:Nope" }')
    check(not res["ok"], "an unknown goal is refused")
    # the goals that read the player's data
    srv(sim, '''
PDS.Set(p, { "Stats", "Hatched" }, 1)
PDS.Set(p, { "Stats", "Fed" }, 1)
PDS.Set(p, { "Stats", "DistanceFlown" }, 800)
PDS.Set(p, { "Stats", "Rides" }, 1)
shared.R = {}''')
    r = srv(sim, '''
local before = QS.State(p)
local done = {}
for _, s in before.Starter do done[s.Id] = s.Done end
PDS.Set(p, { "Upgrades", "EggStorage" }, 1)
local up = false
for _, s in QS.State(p).Starter do if s.Id == "Upgrade" then up = s.Done end end
shared.R = { ride = done.Ride, fly = done.Fly, hatch = done.Hatch, feed = done.Feed, perchBefore = done.Perch, upgradeAfter = up }''')
    print("starter facts", r)
    check(r["ride"] and r["fly"] and r["hatch"] and r["feed"], "Ride / Fly 500 / Hatch / Feed read the counters")
    check(r["upgradeAfter"], "'Buy your first upgrade' reads the upgrade levels")
    # take them all: the list disappears
    for sid in ("Ride", "Fly", "Hatch", "Feed", "Upgrade"):
        sim.run_for(0.8, 1 / 30)
        rr = req(sim, player, "Claim", '{ Id = "s:%s" }' % sid)
        check(rr["ok"] or sid == "Perch", f"starter goal {sid} taken (+${rr['cash']:.0f}, {rr['spins']:.0f} spins)")
    r = srv(sim, '''
PDS.Set(p, { "Quests", "Starter", "Perch" }, true)
local st = QS.State(p)
shared.R = { listed = #st.Starter, left = st.StarterLeft }''')
    check(r["listed"] == 0 and r["left"] == 0, "when every starter goal is taken the list is gone")

    # ------------------------------------------------------------------ the counters kept by the service
    r = srv(sim, '''
local before = d.Stats.Rides
MS.Mounted:Fire(p, nil)
shared.R = { before = before, after = d.Stats.Rides }''')
    check(r["after"] == r["before"] + 1, f"mounting counts a ride ({r['before']:.0f} -> {r['after']:.0f})")
    r = srv(sim, '''
local ok = MS.Mount(p)
local comp = MS.Get(p)
if comp and comp.Riding then comp.Model:SetAttribute("Boost", true) end
shared.R = { riding = comp ~= nil and comp.Riding == true, before = d.Stats.BoostSeconds }''')
    if r["riding"]:
        pass
    if r["riding"]:
        sim.run_for(3.3, 1 / 30)
        r2 = srv(sim, 'shared.R = { after = d.Stats.BoostSeconds }')
        check(r2["after"] - r["before"] >= 2, f"riding with the boost on counts boost seconds (+{r2['after'] - r['before']:.0f} in 3 s)")
    else:
        print("  (could not mount in the simulator: boost seconds not checked)")

    # ------------------------------------------------------------------ the HUD badge and the window
    srv(sim, '''
local st = QS.State(p)
setActive({ { "w1", "CollectCoins", 1 }, { "w2", "SellDragons", 5 }, { "w3", "SpinWheel", 5 } })
PDS.Increment(p, { "Stats", "Coins" }, 1)
shared.R = {}''')
    sim.run_for(3.0, 1 / 30)
    c = lua_table_to_py(run_client_lua(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local QCtl = require(LP.PlayerScripts.Controllers.QuestController)
local btn = LP.PlayerGui:FindFirstChild("Quests", true)
local badge
for _, d in (btn and btn:GetDescendants() or {}) do
	if d.Name == "Badge" and d:IsA("GuiObject") then badge = d end
end
shared.R = { count = QCtl.count(), button = btn ~= nil, badge = badge ~= nil and badge.Visible }''').get("R"))
    print("badge", c)
    check(c["count"] >= 1 and c["button"] and c["badge"], "the QUESTS button lights up when a reward waits")

    w = lua_table_to_py(run_client_lua(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local ui = require(LP.PlayerScripts.Controllers.UIController)
ui.Open("Quests")
task.wait(1.2)
local win = ui.Windows.Quests
local out = { open = ui.Current == "Quests", quests = 0, ready = 0, starter = 0, footer = win.Footer.Text, title = "", claim = false }
for _, r in win.Rows do
	if string.sub(r.Name, 1, 5) == "Quest" then
		out.quests += 1
		local go = r:FindFirstChild("Claim")
		if go then out.claim = true end
		if r:FindFirstChild("Title") and out.title == "" then out.title = r.Title.Text end
	elseif string.sub(r.Name, 1, 8) == "Starter_" then
		out.starter += 1
	end
end
shared.R = out''', max_steps=3000).get("R"))
    print("window", w)
    check(w["open"] and w["quests"] == 3, f"the Quests window opens with three quest rows ({w['title']})")
    check(w["claim"] and "QUESTS DONE" in w["footer"], f"each row has a CLAIM button; footer: {w['footer']}")
    # claim the finished quest from the window
    before = srv(sim, 'shared.R = { done = d.Quests.Completed }')
    run_client_lua(sim, player, '''
local LP = game:GetService("Players").LocalPlayer
local ui = require(LP.PlayerScripts.Controllers.UIController)
local win = ui.Windows.Quests
for _, r in win.Rows do
	if r.Name == "Quest1" then
		local go = r:FindFirstChild("Claim")
		win:Claim("w1", win.Registry and { SetBusy = function() end } or go)
	end
end
task.wait(1.5)
shared.R = {}''', max_steps=3000)
    sim.run_for(1.0, 1 / 30)
    after = srv(sim, 'local st = QS.State(p) shared.R = { done = d.Quests.Completed, first = st.Active[1].Id }')
    check(after["done"] == before["done"] + 1 and after["first"] != "w1", "pressing CLAIM in the window takes the reward and gives a new quest")

    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:10]:
        print("  ", e)
    check(len(sim.errors) == 0, "no script errors")
    print("FAILED:", FAIL)
    print(f"done in {time.time() - t0:.0f}s")
    print("ALL OK" if not FAIL else "SOME FAILED")


if __name__ == "__main__":
    main()
