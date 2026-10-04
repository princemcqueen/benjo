"""Bootstrap resilience: one broken script must not take the game down.

Fault injection: a controller that throws while it is required, one whose Init throws, one whose
Start throws, a broken developer UI (UILab) and a broken server service. Everything else must keep
working (HUD, eggs, nest prompts, dragons) and the failures must be listed on the Diagnostics
panel (Studio) and in the ServerBootErrors attribute.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py, find_node  # noqa: E402

FAIL = []


def check(cond, label):
    print(("  ok   " if cond else "  FAIL ") + label)
    if not cond:
        FAIL.append(label)


STATE = '''
local LP = game:GetService("Players").LocalPlayer
local pg = LP.PlayerGui
local diag = pg:FindFirstChild("Diagnostics")
local rows, header = {}, ""
if diag then
	local panel = diag:FindFirstChild("Panel")
	header = panel and panel:FindFirstChild("Header") and panel.Header.Text or ""
	local body = panel and panel:FindFirstChild("Rows")
	if body then
		for _, r in body:GetChildren() do
			if r:IsA("TextLabel") then table.insert(rows, r.Text) end
		end
	end
end
local EC = require(LP.PlayerScripts.Controllers.EggController)
local prompts = 0
for _, d in workspace:GetDescendants() do
	if d:IsA("ProximityPrompt") then prompts += 1 end
end
shared.R = {
	hud = pg:FindFirstChild("GameHUD") ~= nil,
	diag = diag ~= nil and diag.Enabled,
	header = header,
	rows = rows,
	eggs = EC.count(),
	prompts = prompts,
	serverBoot = game:GetService("ReplicatedStorage"):GetAttribute("ServerBootErrors") or "",
}
'''


def read(sim, player):
    res = run_client_lua(sim, player, STATE)
    return lua_table_to_py(res.get("R"))


def run(label, patch):
    t0 = time.time()
    sim = boot(patch_tree=patch)
    sim.physics = rbx_physics.make_physics()
    p = sim.add_player()
    sim.run_for(9, 1 / 30)
    s = read(sim, p)
    print(label, {k: v for k, v in s.items() if k != "rows"}, "(%.0fs)" % (time.time() - t0))
    return sim, s


def main():
    # ---- clean boot: no panel
    sim, s = run("clean", None)
    check(s["hud"] and not s["diag"], "clean boot: HUD up, no error panel")
    check(len(sim.errors) == 0, "clean boot: no script errors")
    check(s["eggs"] > 0, f"eggs spawned for the player ({s['eggs']})")

    # ---- fault injection
    def patch(tree):
        ctrl = find_node(tree, "Controllers")
        def src(name, text):
            node = find_node(ctrl, name)
            node.source = text
        src("HeldEggController", 'error("boom while requiring")')
        src("AnnounceController", 'return { Init = function() error("boom in Init") end }')
        src("WildEggController", 'return { Start = function() error("boom in Start") end }')
        lab = find_node(tree, "UILab")
        lab.source = 'error("lab boom")'
        svc = find_node(tree, "WildEggService")
        svc.source = 'return { Init = function() error("server boom in Init") end }'

    sim, s = run("faulty", patch)
    check(s["hud"], "faulty boot: the HUD still comes up")
    check(s["eggs"] > 0, f"faulty boot: the egg system still works ({s['eggs']} eggs)")
    check(s["prompts"] > 0, f"faulty boot: prompts exist ({s['prompts']})")
    check(s["diag"], "faulty boot: the error panel is shown")
    text = "\n".join(s["rows"])
    for needle in ("HeldEggController", "AnnounceController", "WildEggController", "UILab", "server"):
        check(needle in text, f"panel lists {needle}")
    check("SCRIPT ERRORS" in s["header"], f"panel header ({s['header'][:60]})")
    check("WildEggService" in s["serverBoot"], "server boot error is published for the client")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
