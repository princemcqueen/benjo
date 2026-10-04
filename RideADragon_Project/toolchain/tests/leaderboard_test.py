"""Leaderboards at spawn + Teleport menu: boards built in the plaza, live ranking,
Travel 'Spawn' arrival looks at the boards, Teleport window opens and travels."""
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
local LB = require(SSS.Services.LeaderboardService)
local players = game:GetService("Players"):GetPlayers()
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def req(sim, player, action, payload="{}", domain="Travel"):
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
    p2 = sim.add_player("Player2", 1002)
    sim.run_for(5, 1 / 30)
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    r = srv(sim, '''
local a, b = players[1], players[2]
PDS.Set(a, { "TotalEarned" }, 5000000)
PDS.Set(b, { "TotalEarned" }, 12000000)
PDS.Set(a, { "Stats", "Hatched" }, 40)
PDS.Set(b, { "Stats", "Hatched" }, 12)
PDS.Set(a, { "Stats", "PlayTime" }, 7380)
LB.RefreshNow()
local out = {}
local folder = workspace.World:FindFirstChild("Leaderboards")
out.Boards = folder and #folder:GetChildren() or 0
local function rows(id)
	local m = folder and folder:FindFirstChild("Leaderboard_" .. id)
	local bg = m and m.Screen.Board:FindFirstChildOfClass("Frame")
	local res = {}
	for i = 1, 3 do
		local row = bg and bg:FindFirstChild("Row" .. i)
		res[i] = row and (row.PlayerName.Text .. " | " .. row.Value.Text) or "?"
	end
	return res
end
out.Earned = rows("Earned")
out.Hatched = rows("Hatched")
out.PlayTime = rows("PlayTime")
out.Income = rows("Income")
local m = folder and folder:FindFirstChild("Leaderboard_Earned")
out.Status = m and m.Screen.Board:FindFirstChildOfClass("Frame").Status.Text or "?"
local pos = {}
for _, b in folder:GetChildren() do
	local p = b.PrimaryPart.Position
	table.insert(pos, string.format("%s (%.0f, %.1f, %.0f)", b.Name, p.X, p.Y, p.Z))
end
out.Pos = pos
shared.R = out
''')
    print(r)
    check(r["Boards"] == 4, "4 leaderboards built in the plaza")
    check(r["Earned"][0].startswith("Player2") and "$12M" in r["Earned"][0], "earned board ranks Player2 first ($12M)")
    check(r["Earned"][1].startswith("Player1"), "earned board ranks Player1 second")
    check(r["Hatched"][0].startswith("Player1") and r["Hatched"][0].endswith("40"), "hatched board ranks Player1 first (40)")
    check("2h 03m" in r["PlayTime"][0], "play time formatted (2h 03m)")

    # travel to spawn: arrive looking at the boards
    res = req(sim, p1, "To", '{ Place = "Spawn" }')
    sim.run_for(1.0, 1 / 30)
    look = run_client_lua(sim, p1, '''
local hrp = game:GetService("Players").LocalPlayer.Character.HumanoidRootPart
local lb = workspace.World.Leaderboards
local n, near = 0, 0
for _, b in lb:GetChildren() do
	local d = b.PrimaryPart.Position - hrp.Position
	local flat = Vector3.new(d.X, 0, d.Z).Unit
	if flat:Dot(hrp.CFrame.LookVector) > 0.3 then n += 1 end
	if d.Magnitude < 60 then near += 1 end
end
shared.L = { ok = true, inView = n, near = near, pos = tostring(hrp.Position) }
''')
    L = lua_table_to_py(look.get("L"))
    print("travel", res, L)
    check(res["ok"], "Travel To Spawn succeeds")
    check(L["inView"] >= 3 and L["near"] == 4, "arrival faces the leaderboards (in view: %s)" % L["inView"])

    # teleport window
    sim.run_for(3.0, 1 / 30)
    out = run_client_lua(sim, p1, '''
local uic = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
uic.Open("Teleport")
task.wait(0.6)
local w = uic.Windows.Teleport
shared.T = { open = w ~= nil and w.Root.Visible, rows = w and #w.Content.List:GetChildren() or 0 }
''')
    T = lua_table_to_py(out.get("T"))
    print("window", T)
    check(T["open"], "Teleport window opens")
    ui_render(sim, p1, f"{OUT}/teleport_window.png", debug=False)
    out = run_client_lua(sim, p1, '''
local uic = require(game:GetService("Players").LocalPlayer.PlayerScripts.Controllers.UIController)
local w = uic.Windows.Teleport
w:Go(w.Places[1])
task.wait(1.5)
local hrp = game:GetService("Players").LocalPlayer.Character.HumanoidRootPart
shared.G = { open = w.Root.Visible, pos = tostring(hrp.Position) }
''')
    G = lua_table_to_py(out.get("G"))
    plot = srv(sim, '''
local SS = require(SSS.Services.SanctuaryService)
local id = SS.GetPlotId(players[1])
local hrp = players[1].Character.HumanoidRootPart
shared.R = { dist = (SS.SpawnCFrame(id).Position - hrp.Position).Magnitude }
''')
    print("go", G, plot)
    check(not G["open"] and plot["dist"] < 20, "GO -> My Sanctuary closes the window and teleports home")
    # snapshot of a board as 2D UI for a visual check
    run_client_lua(sim, p1, '''
local lp = game:GetService("Players").LocalPlayer
local src = workspace.World.Leaderboards.Leaderboard_Earned.Screen.Board:FindFirstChildOfClass("Frame")
local sg = Instance.new("ScreenGui")
sg.Name = "BoardSnap"
local holder = Instance.new("Frame")
holder.Size = UDim2.fromOffset(640, 840)
holder.BackgroundTransparency = 1
holder.Parent = sg
local c = src:Clone()
c.Parent = holder
sg.Parent = lp.PlayerGui
shared.S = { ok = true }
''')
    ui_render(sim, p1, f"{OUT}/board_snap.png", debug=False)
    print("ERRORS:", len(sim.errors), sim.errors[:4])
    print("FAILED:", FAIL)
    print("done in %ds" % (time.time() - t0))


if __name__ == "__main__":
    main()
