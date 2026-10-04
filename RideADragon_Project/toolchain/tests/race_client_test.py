"""Race & Battle Island - the race on the client: lobby panel, countdown, the standard dragon, the
takeoff at GO, the timer, the marker on the next ring, boost rings (dash + the event the server
checks), the finish card, the Race window."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402

import race_test as rt  # noqa: E402

check = rt.check
req = rt.req


def client(sim, player, src, steps=600):
    res = run_client_lua(sim, player, src, max_steps=steps)
    return lua_table_to_py(res.get("R"))


UI = '''
local LP = game:GetService("Players").LocalPlayer
local gui = LP.PlayerGui:FindFirstChild("GameRace")
local root = gui and gui.Root
local function vis(name) local f = root and root:FindFirstChild(name) return f ~= nil and f.Visible end
local RC = require(LP.PlayerScripts.Controllers.RaceController)
local DC = require(LP.PlayerScripts.Controllers.DragonController)
local s = DC.getState()
'''


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    alice = sim.add_player("Alice", 3001)
    sim.run_for(8, 1 / 30)

    r = req(sim, alice, "Travel", "To", '{ Place = "RaceIsland" }')
    check(r["ok"], "Alice travels to the Race Island")
    sim.run_for(3, 1 / 30)

    # ------------------------------------------------------------------ the window
    w = client(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local ui = require(LP.PlayerScripts.Controllers.UIController)
ui.Open("Race")
task.wait(1.0)
local win = ui.Windows.Race
local join = win.JoinButton
shared.R = { open = ui.IsOpen("Race"), mode = win.JoinMode, status = win.Status.Text, prize = win.PrizeText.Text, label = join.Instance.Content.Label.Text }''')
    print("window:", w)
    check(w["open"] and w["mode"] == "Join", f"the Race window opens on the island with a JOIN button ({w['label']})")
    check("$50" in w["prize"], f"the prize is on the window ({w['prize']})")
    client(sim, alice, '''
local LP = game:GetService("Players").LocalPlayer
local ui = require(LP.PlayerScripts.Controllers.UIController)
ui.Close()
task.wait(0.5)
shared.R = {}''')

    # ------------------------------------------------------------------ lobby (through the window's own request)
    r = req(sim, alice, "Race", "Join")
    check(r["ok"], "join the lobby")
    sim.run_for(1.0, 1 / 30)
    u = client(sim, alice, UI + '''
local lobby = root and root:FindFirstChild("Lobby")
shared.R = { lobby = vis("Lobby"), phase = RC.phase(), start = lobby.StartNow.Visible, names = lobby.Names1.Text, timer = lobby.Timer.Text, hud = vis("RaceHud") }''')
    print("lobby:", u)
    check(u["lobby"] and u["phase"] == "Lobby", "the lobby panel shows")
    check("Alice" in u["names"], f"...with the racers ({u['names']!r})")
    check(u["start"], "...and START NOW (she is alone)")
    check(not u["hud"], "the race HUD is not up yet")
    r = req(sim, alice, "Race", "StartNow")
    check(r["ok"], "start now")

    # ------------------------------------------------------------------ countdown
    sim.run_for(3.5, 1 / 30)
    u = client(sim, alice, UI + '''
shared.R = { phase = RC.phase(), hud = vis("RaceHud"), lobby = vis("Lobby"), riding = DC.isRiding(), cruise = s and s.Stats.CruiseSpeed or -1,
	mode = s and s.Mode or "", yaw = s and s.Yaw or -9, count = vis("Countdown"), text = root.Countdown.Text, active = LP:GetAttribute("RaceActive") == true }''')
    print("countdown:", u)
    check(u["phase"] == "Countdown" and u["hud"] and not u["lobby"], "the lobby gives way to the race panel and the countdown")
    check(u["count"] and u["text"] in ("3", "2", "1"), f"a big number is on screen ({u['text']})")
    check(u["riding"] and u["active"], "she is on her dragon with the race switched on")
    check(u["cruise"] == 135, f"the dragon flies the standard stats (cruise {u['cruise']})")
    check(abs(u["yaw"]) < 0.05, "facing north on the grid")

    # ------------------------------------------------------------------ GO
    sim.run_for(3.0, 1 / 30)
    u = client(sim, alice, UI + '''
shared.R = { phase = RC.phase(), mode = s and s.Mode or "", speed = s and s.Speed or -1, timer = root.RaceHud.Timer.Text, marker = vis("GateMarker"),
	gate = root.RaceHud.Gate.Text, y = DC.getModel() and DC.getModel().Root.Position.Y or 0 }''')
    print("go:", u)
    check(u["phase"] == "Running", "the race is on")
    check(u["mode"] in ("Takeoff", "Fly"), f"the dragon takes off at GO (mode {u['mode']})")
    check(u["timer"] != "0:00.000", f"the timer runs ({u['timer']})")
    check(u["marker"], "a marker shows the next ring")
    check(u["gate"].startswith("GATE 1/26"), f"gate counter ({u['gate']})")
    sim.run_for(2.0, 1 / 30)
    u = client(sim, alice, UI + '''
shared.R = { mode = s and s.Mode or "", y = DC.getModel() and DC.getModel().Root.Position.Y or 0 }''')
    check(u["mode"] in ("Fly", "Takeoff"), f"...and keeps flying (mode {u['mode']})")

    # ------------------------------------------------------------------ boost ring: fly through ring 1 (honestly: through the first four gates, then the ring)
    rt.fly(sim, {"Alice": 1}, 4, {"Alice": 300})
    rt.srv(sim, 'MS.Get(alice).Root.Anchored = true shared.R = {}')  # hold the dragon: the test moves it by hand
    boost = rt.srv(sim, '''
local b = RaceConfig.Boosts[1]
local c = RaceConfig.toWorld(b.Position)
shared.R = { x = c.X, y = c.Y, z = c.Z, dx = b.Direction.X, dy = b.Direction.Y, dz = b.Direction.Z }''')
    before = [boost["x"] - boost["dx"] * 12, boost["y"] - boost["dy"] * 12, boost["z"] - boost["dz"] * 12]
    after = [boost["x"] + boost["dx"] * 12, boost["y"] + boost["dy"] * 12, boost["z"] + boost["dz"] * 12]

    def hop_to(target, speed=250):
        p, _ = rt.root_pos(sim, "Alice")
        while True:
            dv = [t - q for t, q in zip(target, p)]
            dist = sum(x * x for x in dv) ** 0.5
            if dist < speed * 0.1:
                rt.set_root(sim, "Alice", target)
                sim.run_for(0.1, 1 / 30)
                return
            p = [q + x / dist * speed * 0.1 for q, x in zip(p, dv)]
            rt.set_root(sim, "Alice", p)
            sim.run_for(0.1, 1 / 30)
    hop_to(before)
    sim.run_for(0.3, 1 / 30)
    hop_to(after)
    sim.run_for(0.2, 1 / 30)
    u = client(sim, alice, UI + '''
shared.R = { dash = s and (s.DashLeft or 0) or -1, flash = vis("BoostFlash") }''')
    check(u["dash"] > 0, f"flying through a boost ring starts a dash ({u['dash']:.2f} s left)")
    ok = rt.srv(sim, '''
local comp = MS.Get(alice)
shared.R = { allowed = comp.DashUntil ~= nil and os.clock() < comp.DashUntil }''')
    check(ok["allowed"], "the server was told (RaceBoost) and relaxes the speed check for the dash")
    u = client(sim, alice, UI + '''
shared.R = { race = LP:GetAttribute("RaceActive") == true }''')
    check(u["race"], "she is still racing (the boost did not disqualify her)")

    # ------------------------------------------------------------------ finish the race (hop through every ring)
    sim.run_for(0.5, 1 / 30)
    state = rt.state(sim, "Alice")
    total = 52
    print("before the hop-through flight:", state)
    rt.fly(sim, {"Alice": int(state["pass"])}, total, {"Alice": 300})
    seen = rt.srv(sim, '''
local r = RaceService._race()
local rc = r and r.Racers[alice]
shared.R = { has = r ~= nil, status = rc and rc.Status or "", reason = rc and rc.Reason or "", pass = rc and rc.Pass or -1, violations = rc and rc.Violations or -1, place = rc and rc.Place or -1 }''')
    print("server view right after the flight:", seen)
    sim.run_for(1.5, 1 / 30)
    u = client(sim, alice, UI + '''
local card = root and root:FindFirstChild("RaceFinish")
shared.R = { card = card ~= nil and card.Visible, place = card and card.Place.Text or "", time = card and card.Time.Text or "", caption = card and card.Caption.Text or "",
	rewards = card and card.Rewards.Text or "", hud = vis("RaceHud"), marker = vis("GateMarker"), phase = RC.phase(), active = LP:GetAttribute("RaceActive") == true }''')
    print("finish:", u)
    check(u["card"], f"the finish card shows ({u['caption']}: {u['place']} {u['time']})")
    check(u["time"] != "0:00.000" and ":" in u["time"], "...with her time")
    check("$" in u["rewards"] and "XP" in u["rewards"], f"...and the rewards ({u['rewards'].splitlines()[0] if u['rewards'] else ''})")
    check(not u["hud"] and not u["marker"], "the race panel and the marker are gone")
    check(not u["active"], "she flies her own dragon again")
    u = client(sim, alice, UI + '''
shared.R = { cruise = s and s.Stats.CruiseSpeed or -1 }''')
    check(u["cruise"] != 135, f"her own stats are back (cruise {u['cruise']})")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if rt.FAIL else "\nALL OK", rt.FAIL if rt.FAIL else "")
    sys.exit(1 if rt.FAIL else 0)


if __name__ == "__main__":
    main()
