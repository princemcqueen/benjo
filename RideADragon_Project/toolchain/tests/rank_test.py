"""Ranks (RankConfig / RankService / AdminModule / ChatController): the five ranks and their titles, the
/rank command (who may, what they may hand out), the tag over the character, the player attributes the chat
reads, persistence in the player data, the Net path of the chat commands and /give for the high ranks."""
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


HEAD = '''
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local PDS = require(SSS.Services.PlayerDataService)
local RankService = require(SSS.Services.RankService)
local AdminModule = require(SSS.AdminModule)
local RankConfig = require(RS.Configs.RankConfig)
local Net = require(RS.Shared.Net)
local owner, bob, carol
for _, pl in game:GetService("Players"):GetPlayers() do
	if pl.Name == "Bendzaminoo" then owner = pl elseif pl.Name == "Bob" then bob = pl elseif pl.Name == "Carol" then carol = pl end
end
local function cmd(sender, text)
	local log = {}
	local orig = Net.notify
	Net.notify = function(pl, kind, msg) table.insert(log, pl.Name .. ":" .. kind .. ":" .. msg) end
	local handled = AdminModule.Execute(sender, text)
	Net.notify = orig
	return handled, log
end
local function joined(log) return table.concat(log, " || ") end
'''


def srv(sim, src):
    ctx = sim.server_ctx
    env = sim.script_env(None, ctx)
    fn = LI.load(HEAD + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def main():
    t0 = time.time()
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    owner = sim.add_player("Bendzaminoo", 8001)
    sim.run_for(8, 1 / 30)
    bob = sim.add_player("Bob", 8002)
    carol = sim.add_player("Carol", 8003)
    sim.run_for(6, 1 / 30)
    sim.is_studio = False  # the rules of a real server: only AdminConfig names / ranks may use the commands
    print("booted", round(time.time() - t0, 1), "s; errors", len(sim.errors))

    # ------------------------------------------------------------------ the ranks
    r = srv(sim, '''
local function name(x) local r = RankConfig.parse(x) return r and r.Title or "-" end
local none1, isNone1 = RankConfig.parse("none")
shared.R = {
	n = #RankConfig.Ranks, vip = name("vip"), mod = name("Moderator"), admin = name("ADMIN"), co = name("co-owner"), co2 = name("Co Owner"), co3 = name("coowner"),
	five = name("5"), king = name("king"), bad = name("banana"), none = isNone1, noneRank = none1 == nil,
	title1 = RankConfig.ByLevel[1].Title, title5 = RankConfig.ByLevel[5].Title, hex = RankConfig.hex(Color3.fromRGB(255, 70, 80)),
	level0 = RankService.Level(bob),
}''')
    print("config", r)
    check(r["n"] == 5, "five ranks")
    check(r["vip"] == "VIP" and r["mod"] == "MOD" and r["admin"] == "ADMIN" and r["co"] == "CO-OWNER" and r["five"] == "OWNER", "the rank names and numbers parse")
    check(r["co2"] == "CO-OWNER" and r["co3"] == "CO-OWNER" and r["king"] == "OWNER", "aliases: 'Co Owner', 'coowner', 'king'")
    check(r["bad"] == "-" and r["none"], "an unknown word is no rank; 'none' means remove")
    check(r["level0"] == 0, "nobody has a rank at the start")

    # ------------------------------------------------------------------ the owner hands out ranks
    r = srv(sim, '''
local handled, log = cmd(owner, "/rank Bob vip")
shared.R = { handled = handled, level = RankService.Level(bob), attr = bob:GetAttribute("RankLevel"), title = bob:GetAttribute("RankTitle"), saved = PDS.Get(bob).Rank,
	log = joined(log), isOwner = AdminModule.IsOwner(owner), bobOwner = AdminModule.IsOwner(bob) }''')
    print("vip", r)
    check(r["handled"] and r["level"] == 1 and r["attr"] == 1 and r["title"] == "VIP" and r["saved"] == 1, "/rank Bob vip: level 1, attributes set, stored in the player data")
    check(r["isOwner"] and not r["bobOwner"], "Bendzaminoo is the owner (AdminConfig), Bob is not (outside Studio)")
    check("Bob" in r["log"] and "VIP" in r["log"], "the owner and Bob are told")
    sim.run_for(1.0, 1 / 30)
    r = srv(sim, '''
local tag = bob.Character and bob.Character:FindFirstChild("RankTag", true)
local title = tag and tag:FindFirstChild("Title")
shared.R = { hasChar = bob.Character ~= nil, tag = tag ~= nil, text = title and title.Text or "", epithet = tag and tag:FindFirstChild("Epithet") and tag.Epithet.Text or "" }''')
    print("tag", r)
    if r["hasChar"]:
        check(r["tag"] and r["text"] == "VIP" and r["epithet"] == "Friend of the Dragons", f"a tag with the title and the epithet floats over Bob ({r['text']} / {r['epithet']})")
    else:
        print("  (no character in the simulator: tag not checked)")

    # ------------------------------------------------------------------ a CO-OWNER may hand out lower ranks and /give
    r = srv(sim, '''
local _, log = cmd(owner, "/rank bob 4")
local cash0 = PDS.Get(bob).Cash
local _, g = cmd(bob, "/give me Cash 5000")
shared.R = { level = RankService.Level(bob), title = bob:GetAttribute("RankTitle"), cashDelta = PDS.Get(bob).Cash - cash0, isAdmin = AdminModule.IsAdmin(bob), log = joined(g) }''')
    print("coowner", r)
    check(r["level"] == 4 and r["title"] == "CO-OWNER", "Bob is CO-OWNER now")
    check(r["isAdmin"] and r["cashDelta"] == 5000, f"a CO-OWNER may use /give (+${r['cashDelta']:.0f})")
    r = srv(sim, '''
local cash0 = PDS.Get(carol).Cash
local _, g = cmd(carol, "/give me Cash 5000")
local _, r1 = cmd(carol, "/rank me owner")
local _, r2 = cmd(carol, "/rank bob none")
shared.R = { cashDelta = PDS.Get(carol).Cash - cash0, carol = RankService.Level(carol), bob = RankService.Level(bob), log = joined(g) .. " // " .. joined(r1) .. " // " .. joined(r2) }''')
    check(r["cashDelta"] == 0 and r["carol"] == 0 and r["bob"] == 4, "somebody without a rank can neither /give nor /rank")
    check("not allowed" in r["log"], "...and is told so")
    r = srv(sim, '''
local _, a = cmd(bob, "/rank Carol admin")
local lvl1 = RankService.Level(carol)
local _, b = cmd(bob, "/rank Carol coowner")
local lvl2 = RankService.Level(carol)
local _, c = cmd(bob, "/rank Bendzaminoo none")
local _, d2 = cmd(bob, "/rank me owner")
local lvlBob = RankService.Level(bob)
shared.R = { lvl1 = lvl1, lvl2 = lvl2, lvlBob = lvlBob, refuse = joined(b) .. " // " .. joined(c) .. " // " .. joined(d2) }''')
    print("coowner limits", r)
    check(r["lvl1"] == 3, "a CO-OWNER gives ADMIN (Carol is ADMIN)")
    check(r["lvl2"] == 3 and r["lvlBob"] == 4, "...but nobody can hand out CO-OWNER or OWNER, not even to themselves")
    check("below your own" in r["refuse"], "...and is told why")
    r = srv(sim, '''
local _, a = cmd(bob, "/rank Carol none")
shared.R = { carol = RankService.Level(carol), attr = carol:GetAttribute("RankTitle") }''')
    check(r["carol"] == 0 and r["attr"] == "", "a CO-OWNER can remove a lower rank")
    r = srv(sim, '''
RankService.Set(carol, 4)
local _, a = cmd(bob, "/rank Carol none")
shared.R = { carol = RankService.Level(carol), log = joined(a) }''')
    check(r["carol"] == 4 and "as high" in r["log"], "...but not the rank of an equal")
    srv(sim, 'RankService.Set(carol, 0) shared.R = {}')

    # ------------------------------------------------------------------ the owner can do it all
    r = srv(sim, '''
local _, a = cmd(owner, "/rank Carol owner")
local lvl = RankService.Level(carol)
local _, b = cmd(owner, "/rank Carol co owner")
local lvl2 = RankService.Level(carol)
local _, c = cmd(owner, "/rank Carol none")
local lvl3 = RankService.Level(carol)
local _, d2 = cmd(owner, "/rank Carol banana")
shared.R = { lvl = lvl, lvl2 = lvl2, lvl3 = lvl3, bad = joined(d2) }''')
    check(r["lvl"] == 5 and r["lvl2"] == 4 and r["lvl3"] == 0, "the owner sets OWNER, 'Co Owner' and removes a rank")
    check("Unknown rank" in r["bad"], "an unknown rank word is explained")

    # ------------------------------------------------------------------ /ranks, /rankhelp, unknown players, offline grants
    r = srv(sim, '''
RankService.Set(bob, 2)
local h1, a = cmd(owner, "/ranks")
local h2, b = cmd(owner, "/rankhelp")
local h3, c = cmd(owner, "/rank Nobody vip")
local h4, d2 = cmd(owner, "/rank")
local h5 = AdminModule.Execute(owner, "hello everybody")
shared.R = { a = joined(a), b = joined(b), c = joined(c), d = joined(d2), h1 = h1, h2 = h2, h4 = h4, h5 = h5 }''')
    print("lists", r)
    check(r["h1"] and "MOD" in r["a"] and "Bob [MOD]" in r["a"], "/ranks lists the ranks and who has one here")
    check(r["h2"] and r["h4"] and "/rank" in r["b"], "/rankhelp and /rank explain the command")
    check("Nobody" in r["c"], f"an unknown player gets an answer ({r['c'][:60]})")
    check(not r["h5"], "a normal chat line is not a command")

    # ------------------------------------------------------------------ the chat commands travel over Net (TextChatService)
    srv(sim, 'RankService.Set(bob, 4) RankService.Set(carol, 0) shared.R = {}')
    res = run_client_lua(sim, bob, '''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r1 = Net.request("Admin", "Command", { Text = "/rank Carol vip" })
local r2 = Net.request("Admin", "Command", { Text = "just chatting" })
local r3 = Net.request("Admin", "Command", { Text = 42 })
shared.R = { ok1 = r1.ok, handled1 = r1.data and r1.data.Handled == true, ok2 = r2.ok, handled2 = r2.data and r2.data.Handled == true, ok3 = r3.ok }''', max_steps=1500)
    n = lua_table_to_py(res.get("R"))
    r = srv(sim, 'shared.R = { carol = RankService.Level(carol) }')
    print("net", n, r)
    check(n["ok1"] and n["handled1"] and r["carol"] == 1, "Admin.Command carries a /rank typed in the new chat to the server")
    check(n["ok2"] and not n["handled2"] and not n["ok3"], "an ordinary line is not handled; a bad payload is refused")

    # ------------------------------------------------------------------ the chat prefix on the client
    sim.run_for(1.0, 1 / 30)
    res = run_client_lua(sim, owner, '''
local LP = game:GetService("Players").LocalPlayer
local CC = require(LP.PlayerScripts.Controllers.ChatController)
local carolP = game:GetService("Players"):FindFirstChild("Carol")
shared.R = { prefix = CC.prefixFor(carolP) or "", none = CC.prefixFor(nil) == nil, owner = CC.prefixFor(LP) == nil }''', max_steps=1500)
    c = lua_table_to_py(res.get("R"))
    print("chat", c)
    check("[VIP]" in c["prefix"] and "FFD65A" in c["prefix"], f"the chat line of a VIP starts with a gold [VIP] ({c['prefix']})")
    check(c["none"] and c["owner"], "players without a rank get no prefix")

    # ------------------------------------------------------------------ Studio: everybody is the owner (so it can be tested)
    sim.is_studio = True
    r = srv(sim, '''
local _, a = cmd(carol, "/rank me king")
shared.R = { carol = RankService.Level(carol), isOwner = AdminModule.IsOwner(carol) }''')
    check(r["isOwner"] and r["carol"] == 5, "inside Roblox Studio everybody can use the commands")

    # ------------------------------------------------------------------ persistence
    r = srv(sim, '''
local data = PDS.Get(carol)
local copy = PDS.Template and PDS.Template.Rank
shared.R = { stored = data.Rank, template = copy }''')
    check(r["stored"] == 5 and r["template"] == 0, "the rank is part of the saved player data (template default 0)")

    print("ERRORS:", len(sim.errors))
    for e in sim.errors[:10]:
        print("  ", e)
    check(len(sim.errors) == 0, "no script errors")
    print("FAILED:", FAIL)
    print(f"done in {time.time() - t0:.0f}s")
    print("ALL OK" if not FAIL else "SOME FAILED")


if __name__ == "__main__":
    main()
