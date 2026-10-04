"""Riders do not run: the default Roblox character sounds (Running, Jumping, Landing...) are muted while a
character is mounted (AudioController.Start) and come back when it dismounts. The dragon's own footsteps only
play after the dragon has been on the ground for a moment (AnimationController)."""
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
    fn = LI.load('''
local p = game:GetService("Players"):GetPlayers()[1]
local char = p.Character
local hrp = char:FindFirstChild("HumanoidRootPart")
''' + src, "ag", sim.script_env(None, ctx))
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def groups(sim, player):
    res = run_client_lua(sim, player, '''
local char = game:GetService("Players").LocalPlayer.Character
local hrp = char:FindFirstChild("HumanoidRootPart")
local out = {}
for _, name in { "Running", "Jumping", "Landing", "Splash" } do
	local s = hrp:FindFirstChild(name)
	out[name] = s and (s.SoundGroup and s.SoundGroup.Name or "none") or "missing"
end
local other = hrp:FindFirstChild("Whoosh")
out.Other = other and (other.SoundGroup and other.SoundGroup.Name or "none") or "missing"
shared.R = out''')
    return lua_table_to_py(res.get("R"))


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    player = sim.add_player("Rider", 8001)
    sim.run_for(8, 1 / 30)
    # the sounds Roblox's own character script would add
    srv(sim, '''
for _, name in { "Running", "Jumping", "Landing", "Splash", "Whoosh" } do
	local s = Instance.new("Sound")
	s.Name = name
	s.Parent = hrp
end
shared.R = {}''')
    sim.run_for(1.0, 1 / 30)
    g = groups(sim, player)
    print("on foot:", g)
    check(all(g[k] == "none" for k in ("Running", "Jumping", "Landing", "Splash")), "on foot the character sounds are untouched")
    srv(sim, 'char:SetAttribute("Mounted", true) shared.R = {}')
    sim.run_for(1.0, 1 / 30)
    g = groups(sim, player)
    print("mounted:", g)
    check(all(g[k] == "RAD_MuteCharacter" for k in ("Running", "Jumping", "Landing", "Splash")), "mounted: Running / Jumping / Landing / Splash go to the muted group")
    check(g["Other"] == "none", "...other sounds on the character are left alone")
    srv(sim, 'char:SetAttribute("Mounted", nil) shared.R = {}')
    sim.run_for(1.0, 1 / 30)
    g = groups(sim, player)
    print("dismounted:", g)
    check(all(g[k] == "none" for k in ("Running", "Jumping", "Landing", "Splash")), "dismounted: they come back")
    res = run_client_lua(sim, player, '''
local sg = game:GetService("SoundService"):FindFirstChild("RAD_MuteCharacter")
shared.R = { exists = sg ~= nil, volume = sg and sg.Volume or -1 }''')
    m = lua_table_to_py(res.get("R"))
    check(m["exists"] and m["volume"] == 0, "the muted group has volume 0")
    check(not sim.errors, f"no script errors ({len(sim.errors)})")
    print()
    print("FAILED:" if FAIL else "ALL OK", FAIL if FAIL else "", f"({time.time() - t0:.0f} s)")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
