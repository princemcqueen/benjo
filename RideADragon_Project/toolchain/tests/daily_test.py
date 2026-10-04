"""Daily rewards: the 7-day calendar with a streak (DailyService / DailyWindow / DailyController):
claiming once a day, the streak surviving a day boundary and breaking after a missed day, the rewards
of every day (cash, spins, boost, eggs), the weekly cash bonus, the HUD badge and the window."""
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
local BS = require(SSS.Services.BoostService)
local DS = require(SSS.Services.DailyService)
local DailyConfig = require(RS.Configs.DailyConfig)
local p = game:GetService("Players"):GetPlayers()[1]
local d = PDS.Get(p)
local DAY = 86400
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("Daily", "{action}", {payload})
local days = {{}}
if r.data and r.data.Days then
	for i, e in r.data.Days do days[i] = e.State end
end
shared.RQ = {{ ok = r.ok, err = r.err or "", data = r.data and {{ CanClaim = r.data.CanClaim, Streak = r.data.Streak, Day = r.data.Day, ClaimedToday = r.data.ClaimedToday,
	SecondsLeft = r.data.SecondsLeft, Bonus = r.data.Bonus, DayOut = r.data.Day, States = table.concat(days, ","), Cash = r.data.Cash, Spins = r.data.Spins }} or nil }}
''')
    return lua_table_to_py(res.get("RQ"))


def set_daily(sim, days_ago, streak):
    """The last claim was `days_ago` days ago (0 = earlier today) with this streak."""
    srv(sim, f'''
local today = DailyConfig.dayOf(os.time())
local at = today * DAY + 100 - {days_ago} * DAY
PDS.Set(p, {{ "Daily" }}, {{ LastClaim = at, Streak = {streak} }})
shared.R = {{}}''')


def claim(sim, alice):
    sim.run_for(2.0, 1 / 30)  # (the claim is rate limited: one a second after a burst of three)
    before = srv(sim, 'shared.R = { cash = d.Cash, spins = d.Spin.Tickets, eggs = #d.Eggs, luck = BS.Remaining(p, "Luck") }')
    r = req(sim, alice, "Claim")
    after = srv(sim, '''
local cel, gold = 0, 0
for _, e in d.Eggs do
	if e.Type == "CelestialEgg" and e.Luck == 10 then cel += 1 end
	if e.Type == "GoldenEgg" and e.Luck == 5 then gold += 1 end
end
shared.R = { cash = d.Cash, spins = d.Spin.Tickets, eggs = #d.Eggs, luck = BS.Remaining(p, "Luck"), cel = cel, gold = gold }''')
    return r, before, after


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    alice = sim.add_player("Alice", 5001)
    sim.run_for(8, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ------------------------------------------------------------------ the calendar for a new player
    r = req(sim, alice, "State")
    print("state", r)
    d = r["data"]
    check(r["ok"] and d["CanClaim"] and d["Streak"] == 0 and d["Day"] == 1, "a new player can claim day 1 (streak 0)")
    check(d["States"] == "Today,Next,Later,Later,Later,Later,Later", f"the calendar: {d['States']}")

    # ------------------------------------------------------------------ day 1: cash, once a day
    r, b, a = claim(sim, alice)
    print("claim 1", r)
    check(r["ok"] and r["data"]["Day"] == 1 and r["data"]["Streak"] == 1, "claiming pays day 1 and starts the streak")
    check(a["cash"] - b["cash"] >= 1000 and r["data"]["Cash"] == 1000, f"day 1 pays $1000 for a player without income (${r['data']['Cash']:.0f})")
    r = req(sim, alice, "State")
    d = r["data"]
    check(d["ClaimedToday"] and not d["CanClaim"] and 0 < d["SecondsLeft"] <= 86400, f"claimed today, next reward in {d['SecondsLeft']:.0f} s")
    check(d["States"].startswith("Done,Next"), f"day 1 is done ({d['States']})")
    r = req(sim, alice, "Claim")
    check(not r["ok"] and r["err"] == "ALREADY_CLAIMED", "a second claim on the same day is refused")

    # ------------------------------------------------------------------ the streak goes on the next day: day 2 = spins
    set_daily(sim, 1, 1)
    r = req(sim, alice, "State")
    check(r["data"]["CanClaim"] and r["data"]["Streak"] == 1 and r["data"]["Day"] == 2, "the next day: streak 1 is alive, day 2 is up")
    r, b, a = claim(sim, alice)
    check(r["ok"] and r["data"]["Day"] == 2 and a["spins"] == b["spins"] + 2, f"day 2 pays 2 spin tickets ({b['spins']:.0f} -> {a['spins']:.0f})")

    # ------------------------------------------------------------------ day 3: a luck boost
    set_daily(sim, 1, 2)
    r, b, a = claim(sim, alice)
    check(r["ok"] and r["data"]["Day"] == 3 and a["luck"] >= 290, f"day 3 gives a luck boost ({a['luck']:.0f} s)")

    # ------------------------------------------------------------------ a missed day breaks the streak
    set_daily(sim, 3, 5)
    r = req(sim, alice, "State")
    check(r["data"]["CanClaim"] and r["data"]["Streak"] == 0 and r["data"]["Day"] == 1, "two days missed: the streak is back to 0, day 1")
    r, b, a = claim(sim, alice)
    check(r["ok"] and r["data"]["Streak"] == 1 and r["data"]["Day"] == 1, "...and a claim starts at day 1 again")

    # ------------------------------------------------------------------ day 6: an egg, day 7: the big one
    set_daily(sim, 1, 5)
    r, b, a = claim(sim, alice)
    check(r["ok"] and r["data"]["Day"] == 6 and a["gold"] >= 1 and a["eggs"] == b["eggs"] + 1, "day 6 puts a Golden Egg (x5 luck) in the bag")
    set_daily(sim, 1, 6)
    srv(sim, '''PDS.Set(p, { "Eggs" }, {}) shared.R = {}''')
    r, b, a = claim(sim, alice)
    check(r["ok"] and r["data"]["Day"] == 7 and r["data"]["Cash"] >= 10000 and a["spins"] == b["spins"] + 5 and a["cel"] == 1,
          f"day 7: ${r['data']['Cash']:.0f}, 5 spins and a Celestial Egg (x10)")
    r = req(sim, alice, "State")
    check(r["data"]["States"] == "Done,Done,Done,Done,Done,Done,Done", f"the week is complete ({r['data']['States']})")

    # ------------------------------------------------------------------ the week bonus
    set_daily(sim, 1, 7)
    r = req(sim, alice, "State")
    check(r["data"]["Day"] == 1 and abs(r["data"]["Bonus"] - 1.1) < 1e-9, f"a new week starts on day 1 with +10% cash (x{r['data']['Bonus']})")
    r, b, a = claim(sim, alice)
    check(r["ok"] and r["data"]["Cash"] == 1100, f"day 1 of week 2 pays $1100 (${r['data']['Cash']:.0f})")
    cfg = srv(sim, 'shared.R = { b0 = DailyConfig.bonus(0), b7 = DailyConfig.bonus(7), b70 = DailyConfig.bonus(70), b300 = DailyConfig.bonus(300) }')
    check(cfg["b0"] == 1 and abs(cfg["b7"] - 1.1) < 1e-9 and abs(cfg["b70"] - 2) < 1e-9 and cfg["b300"] == 2, "the bonus grows 10% a week up to +100%")

    # ------------------------------------------------------------------ income scales the cash
    srv(sim, '''
PDS.Set(p, { "Dragons", "TESTD" }, { IncomePerSecond = 1000, Name = "Test", SpeciesId = "GreenDrake", Level = 1, Rarity = "Common" })
PDS.Set(p, { "Nests", "Slots", "1" }, "TESTD")
shared.R = {}''')
    sim.run_for(0.3, 1 / 30)
    set_daily(sim, 1, 3)
    r, b, a = claim(sim, alice)
    check(r["ok"] and r["data"]["Day"] == 4 and r["data"]["Cash"] >= 300000, f"day 4 is 300 s of income: ${r['data']['Cash']:.0f}")

    # ------------------------------------------------------------------ the HUD badge and the window (client)
    set_daily(sim, 1, 0)
    srv(sim, '''
local net = require(RS.Shared.Net)
net.signal(p, "DailyReady", {})
shared.R = {}''')
    sim.run_for(1.0, 1 / 30)
    c = run_client_lua(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local DC = require(LP.PlayerScripts.Controllers.DailyController)
local btn = LP.PlayerGui:FindFirstChild("Daily", true)
local badge
for _, d in (btn and btn:GetDescendants() or {}) do
	if d.Name == "Badge" and d:IsA("GuiObject") then badge = d end
end
shared.R = { ready = DC.isReady(), button = btn ~= nil, badge = badge ~= nil and badge.Visible }''')
    c = lua_table_to_py(c.get("R"))
    print("badge", c)
    check(c["ready"] and c["button"] and c["badge"], "the DAILY button lights up when a reward waits")

    c = run_client_lua(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local ui = require(LP.PlayerScripts.Controllers.UIController)
ui.Open("Daily")
task.wait(1.0)
local win = ui.Windows.Daily
local function vis(inst) return inst ~= nil and inst.Visible end
local labels = {}
for i = 1, 7 do
	local card = win.Cards[i]
	labels[i] = card.Day.Text .. ":" .. card.Text.Text
end
shared.R = { open = ui.IsOpen("Daily"), claim = vis(win.ClaimButton.Instance), countdown = vis(win.Countdown), streak = win.StreakNumber.Text,
	hint = win.StreakHint.Text, cards = table.concat(labels, " | ") }''', max_steps=1200)
    c = lua_table_to_py(c.get("R"))
    print("window", c)
    check(c["open"] and c["claim"] and not c["countdown"], "the window opens with a CLAIM button")
    check(c["cards"].count("DAY") == 7 and c["cards"].count("$") >= 2 and "SPIN" in c["cards"], f"seven day cards with rewards ({c['cards'][:90]}...)")
    c = run_client_lua(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local ui = require(LP.PlayerScripts.Controllers.UIController)
local win = ui.Windows.Daily
win:Claim()
task.wait(1.0)
local DC = require(LP.PlayerScripts.Controllers.DailyController)
local function vis(inst) return inst ~= nil and inst.Visible end
shared.R = { claim = vis(win.ClaimButton.Instance), countdown = vis(win.Countdown), text = win.Countdown.Text, streak = win.StreakNumber.Text, ready = DC.isReady() }''', max_steps=1200)
    c = lua_table_to_py(c.get("R"))
    print("after claim", c)
    check(not c["claim"] and c["countdown"] and c["text"].startswith("NEXT REWARD IN  "), f"after the claim: countdown ({c['text']})")
    check(c["streak"] == "1" and not c["ready"], "streak shows 1 and the badge is gone")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    print("done in %ds" % (time.time() - t0))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
