"""Resolution matrix QA: renders every screen on every device and runs UIChecks."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_runner import boot, DEVICES, render, run_client_lua, client_of, lua_table_to_py

SNIPPET_SHOW = r'''
local UILab = require(game:GetService("Players").LocalPlayer.PlayerScripts.UI.Dev.UILab)
local w = UILab.show("%s")
task.wait(0.5)
local issues = UILab.check(w)
shared.qa = { window = w or "", issues = issues }
'''


def run(screens, devices=None, outdir=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "qa"), setup=None, verbose=False):
    os.makedirs(outdir, exist_ok=True)
    devices = devices or list(DEVICES.keys())
    sim = boot(verbose=verbose)
    # UI QA runs many players in one shared DataModel: skip companion dragons
    sim.services["ReplicatedStorage"].attrs["DevDisableCompanions"] = True
    players = {}
    for i, name in enumerate(devices):
        players[name] = sim.add_player(f"QA_{i}", 5000 + i, DEVICES[name])
    sim.step(1 / 60, 40)
    if setup:
        setup(sim, players)
        sim.step(1 / 60, 20)
    summary = []
    for screen in screens:
        for name in devices:
            p = players[name]
            ctx = client_of(p)
            run_client_lua(sim, p, SNIPPET_SHOW % screen)
            qa = lua_table_to_py(ctx.shared.get("qa"))
            issues = qa.get("issues") or [] if isinstance(qa, dict) else []
            if isinstance(issues, dict):
                issues = list(issues.values())
            path = os.path.join(outdir, f"{screen}_{name}.png")
            render(sim, p, path)
            status = "PASS" if not issues else f"{len(issues)} issue(s)"
            summary.append((screen, name, status, issues))
    errs = sim.errors
    return summary, errs, sim, players


if __name__ == "__main__":
    screens = sys.argv[1].split(",") if len(sys.argv) > 1 else ["HUD"]
    devs = sys.argv[2].split(",") if len(sys.argv) > 2 else None
    t0 = time.time()
    summary, errs, sim, players = run(screens, devs)
    for screen, dev, status, issues in summary:
        print(f"{screen:14s} {dev:16s} {status}")
        for i in issues[:8]:
            print("     -", i.get("Kind"), i.get("Message"))
    print("runtime errors:", len(errs))
    for e in errs[:10]:
        print("  ", e)
    print(f"done in {time.time()-t0:.1f}s")
