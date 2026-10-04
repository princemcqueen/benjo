"""Spin Island: island built, travel there, window opens via prompt flow, roll
(free spin, then tickets), prize granted, client rotor built and spin plays."""
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
    sim.run_for(5, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))
    isl = srv(sim, '''
local m = workspace.World:FindFirstChild("SpinIsland")
local n = 0
if m then for _, x in m:GetDescendants() do if x:IsA("BasePart") then n += 1 end end end
local prompt = m and m:FindFirstChild("SpinPad", true) and m:FindFirstChild("SpinPad", true):FindFirstChildOfClass("ProximityPrompt")
shared.R = { island = m ~= nil, parts = n, prompt = prompt ~= nil and prompt:GetAttribute("Window") or "" , spin = d.Spin and d.Spin.Tickets or -1 }
''')
    print("island", isl)
    check(isl["island"] and isl["parts"] > 50, "Spin Island built (%s parts)" % isl["parts"])
    check(isl["prompt"] == "Spin", "podium prompt opens the Spin window")
    far = req(sim, p1, "Spin", "Roll")
    check(not far["ok"] and far["err"] == "TOO_FAR", "cannot spin away from the island")
    tr = req(sim, p1, "Travel", "To", '{ Place = "SpinIsland" }')
    sim.run_for(1.0, 1 / 30)
    check(tr["ok"], "Travel to Spin Island")
    r1 = req(sim, p1, "Spin", "Roll")
    print("roll1", r1)
    check(r1["ok"] and r1["data"]["Free"], "first spin uses the free spin")
    r2 = req(sim, p1, "Spin", "Roll")
    print("roll2", r2)
    check(r2["ok"] and not r2["data"]["Free"] and r2["data"]["Tickets"] == 2, "second spin uses a ticket (3 -> 2)")
    st = srv(sim, 'shared.R = { cash = d.Cash, eggs = #d.Eggs, tickets = d.Spin.Tickets, spins = d.Stats.Spins }')
    print("state", st)
    check(st["spins"] == 2, "spins counted")
    # client: window + rotor + cinematic
    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local ctrl = lp.PlayerScripts.Controllers
local uic = require(ctrl.UIController)
uic.Open("Spin")
task.wait(0.6)
local w = uic.Windows.Spin
task.wait(1.0)
shared.W = { open = w ~= nil and w.Root.Visible, rotor = workspace:FindFirstChild("SpinWheelRotor") ~= nil, spins = w and w.SpinsText.Text or "", viewing = require(ctrl.SpinController).isViewing() }
''', max_steps=1200)
    W = lua_table_to_py(out.get("W"))
    print("window", W)
    check(W["open"], "Spin panel opens")
    check(W["rotor"], "wheel rotor built near the island")
    ui_render(sim, p1, f"{OUT}/spin_window.png", debug=False)
    out = run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local ctrl = lp.PlayerScripts.Controllers
local spinner = require(ctrl.SpinController)
local uic = require(ctrl.UIController)
uic.Close()
spinner.play({ Index = 10, Prize = { Kind = "Egg", Egg = "SkyEgg", Count = 1, Label = "SKY EGG!" } })
shared.S = { seg = spinner.segmentAt(require(game:GetService("ReplicatedStorage").Configs.SpinConfig).Wheel and 0 or 0) }
''', max_steps=1200)
    land = run_client_lua(sim, p1, '''
local spinner = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.SpinController)
shared.L = { spinning = spinner.isSpinning() }
''')
    print("spin played", lua_table_to_py(land.get("L")))
    print("ERRORS:", len(sim.errors), sim.errors[:4])
    print("FAILED:", FAIL)
    print("done in %ds" % (time.time() - t0))


if __name__ == "__main__":
    main()
