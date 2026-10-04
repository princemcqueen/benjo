"""Sanctuary plots: the owner's name floats above the gate of every plot, a free
plot says FREE, and the plate follows players joining / leaving."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, lua_table_to_py  # noqa: E402

FAIL = []


def check(cond, label):
    print(("  ok   " if cond else "  FAIL ") + label)
    if not cond:
        FAIL.append(label)


def srv(sim, src):
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    head = '''
local WS = game:GetService("Workspace")
local plots = WS:WaitForChild("World"):WaitForChild("Sanctuaries")
local function plate(i)
	local plot = plots:FindFirstChild("Plot" .. i)
	local tag = plot and plot:FindFirstChild("NameTag", true)
	local gui = tag and tag:FindFirstChild("NameGui")
	local pill = gui and gui:FindFirstChild("Pill")
	return plot, tag, gui, pill
end
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    p1 = sim.add_player("Alice", 1001)
    sim.run_for(6, 1 / 30)

    r = srv(sim, '''
local plot, tag, gui, pill = plate(1)
local plot2, tag2, gui2, pill2 = plate(2)
shared.R = {
	hasTag = tag ~= nil, hasGui = gui ~= nil,
	name = pill and pill.OwnerLabel.Text or "?",
	sub = pill and pill.PlotLabel.Text or "?",
	freeName = pill2 and pill2.OwnerLabel.Text or "?",
	freeSub = pill2 and pill2.PlotLabel.Text or "?",
	transparent = tag and tag.Transparency or -1,
	collide = tag.CanCollide,
	query = tag.CanQuery,
	maxDist = gui and gui.MaxDistance or 0,
	height = tag.Position.Y - plot:FindFirstChild("Sign", true).Position.Y,
	adornee = gui and gui.Adornee == tag,
	sign = plot and plot:FindFirstChild("Sign", true).SignGui.Text.Text or "?",
	owner = plot and plot:GetAttribute("OwnerName") or "?",
}
''')
    print(r)
    check(r["hasTag"] and r["hasGui"], "every plot has a floating name plate")
    check(r["name"] == "Alice", f"plot 1 shows the owner's name ({r['name']})")
    check(r["sub"] == "SANCTUARY 1", f"plot number is shown ({r['sub']})")
    check(r["freeName"] == "FREE" and r["freeSub"] == "SANCTUARY 2", "free plot says FREE")
    check(r["transparent"] == 1 and r["collide"] is False and r["query"] is False,
          "plate anchor is invisible and never blocks anything")
    check(r["maxDist"] >= 1000, f"readable from far away (MaxDistance {r['maxDist']})")
    check(r["height"] > 25, f"plate floats clear above the gate arch ({r['height']:.0f} studs over the sign)")
    check(r["adornee"] is True, "plate is adorned to its anchor")
    check(r["sign"] == "Alice's Sanctuary", f"gate sign still names the owner ({r['sign']})")

    # second player gets the next plot, with a different accent colour
    p2 = sim.add_player("Bob", 1002)
    sim.run_for(6, 1 / 30)
    r = srv(sim, '''
local _, _, _, pill1 = plate(1)
local _, _, _, pill2 = plate(2)
local _, _, _, pill3 = plate(3)
shared.R = {
	n1 = pill1.OwnerLabel.Text, n2 = pill2.OwnerLabel.Text, n3 = pill3.OwnerLabel.Text,
	c1 = pill1.Stroke.Color:ToHex(), c2 = pill2.Stroke.Color:ToHex(), c3 = pill3.Stroke.Color:ToHex(),
}
''')
    print(r)
    check(r["n1"] == "Alice" and r["n2"] == "Bob" and r["n3"] == "FREE", "each plot carries its own owner's name")
    check(r["c1"] != r["c2"] and r["c3"] != r["c2"], "owned plates get their plot colour, free plates stay grey")

    # leaving frees the plot and the plate goes back to FREE
    sim.remove_player(p1)
    sim.run_for(2, 1 / 30)
    r = srv(sim, '''
local plot, _, _, pill1 = plate(1)
shared.R = { name = pill1.OwnerLabel.Text, owner = plot:GetAttribute("OwnerUserId") }
''')
    check(r["name"] == "FREE" and r["owner"] == 0, "plot goes back to FREE when the owner leaves")

    # a newcomer takes the freed plot and the plate shows them
    p3 = sim.add_player("Cleo", 1003)
    sim.run_for(6, 1 / 30)
    r = srv(sim, '''
local _, _, _, pill1 = plate(1)
shared.R = { name = pill1.OwnerLabel.Text }
''')
    check(r["name"] == "Cleo", f"freed plot is re-claimed with the new owner's name ({r['name']})")
    del p2, p3

    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
