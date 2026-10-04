"""Race & Battle Island - the race: course geometry, lobby -> start grid -> countdown -> GO, gates in
order, times, places, rewards, best times + leaderboards, anti-cheat (skipping, speed, going back,
dismounting, travel), the queue, the monthly champion."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import luau_interp as LI  # noqa: E402
import rbx_physics  # noqa: E402
from sim_runner import boot, run_client_lua, lua_table_to_py  # noqa: E402
from rbx_types import CFrame as CF  # noqa: E402

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
local MS = require(SSS.Services.MountService)
local RaceService = require(SSS.Services.RaceService)
local LB = require(SSS.Services.LeaderboardService)
local RaceConfig = require(RS.Configs.RaceConfig)
local players = game:GetService("Players"):GetPlayers()
local function byName(n) for _, p in players do if p.Name == n then return p end end end
local alice, bob = byName("Alice"), byName("Bob")
'''
    fn = LI.load(head + src, f"srv{abs(hash(src)) % 100000}", env)
    sim.in_ctx(ctx, fn)
    return lua_table_to_py(ctx.shared.get("R"))


def srv_wait(sim, src, wait=2.0):
    """A server snippet that may yield (DataStore calls): run it, let the sim advance, read the result."""
    srv(sim, "shared.R = nil\n" + src)
    sim.run_for(wait, 1 / 30)
    return lua_table_to_py(sim.server_ctx.shared.get("R"))


def req(sim, player, domain, action, payload="{}"):
    res = run_client_lua(sim, player, f'''
local Net = require(game:GetService("ReplicatedStorage").Shared.Net)
local r = Net.request("{domain}", "{action}", {payload})
shared.R = {{ ok = r.ok, err = r.err or "", msg = r.msg or "", data = r.data }}
''')
    return lua_table_to_py(res.get("R"))


GEOMETRY = '''
local C = RaceConfig
local gates = C.Gates
local minGap, maxGap, maxTurn, minY, maxY = math.huge, 0, 0, math.huge, 0
for i, g in gates do
	local nxt = gates[i % #gates + 1]
	local gap = (nxt.Position - g.Position).Magnitude
	minGap, maxGap = math.min(minGap, gap), math.max(maxGap, gap)
	local turn = math.deg(math.acos(math.clamp(g.Direction:Dot(nxt.Direction), -1, 1)))
	maxTurn = math.max(maxTurn, turn)
	minY, maxY = math.min(minY, g.Position.Y), math.max(maxY, g.Position.Y)
end
local padsOk = true
for _, p in C.Pads do
	if p.Magnitude > C.Island.Radius - 10 then padsOk = false end
end
local boostMinDist = math.huge
for _, b in C.Boosts do
	for _, g in gates do
		boostMinDist = math.min(boostMinDist, (b.Position - g.Position).Magnitude)
	end
end
local d = os.date("!*t")
shared.R = {
	count = #gates, minGap = minGap, maxGap = maxGap, maxTurn = maxTurn, minY = minY, maxY = maxY, length = C.CourseLength,
	padsOk = padsOk, pads = #C.Pads, boosts = #C.Boosts, boostMinDist = boostMinDist,
	total = C.totalPasses(), lastGate = select(2, C.gateForPass(C.totalPasses())), firstGate = select(2, C.gateForPass(1)),
	score = C.scoreTime(C.timeScore(83456)), text = C.formatTime(83456), month = C.monthKey(), prev = C.previousMonthKey(), left = C.secondsLeftInMonth(),
	year = d.year,
	archZ = gates[1].Position.Z, archDir = gates[1].Direction.Z,
	civil0 = C.daysFromCivil(1970, 1, 1), civil1 = C.daysFromCivil(2000, 3, 1), civil2 = C.daysFromCivil(2026, 10, 1),
	civil3 = C.daysFromCivil(2027, 1, 1), civil4 = C.daysFromCivil(2024, 3, 1),
	courseRadius = C.CourseRadius, courseLeave = C.CourseLeave,
	dec = C.secondsLeftInMonth(C.daysFromCivil(2026, 12, 15) * 86400), nov30 = C.secondsLeftInMonth(C.daysFromCivil(2026, 11, 30) * 86400 + 86399),
}
'''


def world_gate(sim, index):
    return srv(sim, f'''
local g = RaceConfig.Gates[{index} % RaceConfig.GateCount + 1]
local c = RaceConfig.toWorld(g.Position)
shared.R = {{ x = c.X, y = c.Y, z = c.Z, dx = g.Direction.X, dy = g.Direction.Y, dz = g.Direction.Z }}''')


def set_root(sim, name, pos):
    srv(sim, f'''
local p = byName("{name}")
local comp = MS.Get(p)
comp.Root.CFrame = CFrame.new({pos[0]}, {pos[1]}, {pos[2]})
shared.R = {{}}''')


def root_pos(sim, name):
    r = srv(sim, f'''
local comp = MS.Get(byName("{name}"))
local p = comp.Root.Position
shared.R = {{ x = p.X, y = p.Y, z = p.Z, anchored = comp.Root.Anchored }}''')
    return [r["x"], r["y"], r["z"]], r["anchored"]


def state(sim, name):
    return srv(sim, f'''
local p = byName("{name}")
local d = PDS.Get(p)
shared.R = {{ state = p:GetAttribute("RaceState") or "", active = p:GetAttribute("RaceActive") == true, pass = p:GetAttribute("RacePass") or 0,
	start = p:GetAttribute("RaceStart") or 0, riding = p:GetAttribute("Riding") == true, best = d.Race.Best, monthBest = d.Race.MonthBest,
	runs = d.Race.Runs, wins = d.Race.Wins, cash = d.Cash }}''')


def fly(sim, plans, total_passes, speeds, wait=0.1, max_steps=2200, hook=None):
    """Moves racers along the gate centres at the given speeds (studs/s). plans: name -> next pass number."""
    pos = {}
    for name in plans:
        pos[name], _ = root_pos(sim, name)
    done = set()
    steps = 0
    gate_cache = {}
    while len(done) < len(plans) and steps < max_steps:
        steps += 1
        for name in list(plans):
            if name in done:
                continue
            j = plans[name]
            g = gate_cache.get(j) or world_gate(sim, j)
            gate_cache[j] = g
            target = [g["x"], g["y"], g["z"]]
            d = [t - p for t, p in zip(target, pos[name])]
            dist = sum(x * x for x in d) ** 0.5
            stepd = speeds[name] * wait
            if dist <= stepd:
                # overshoot a little so the segment crosses the plane
                pos[name] = [t + gd * 6 for t, gd in zip(target, [g["dx"], g["dy"], g["dz"]])]
                plans[name] = j + 1
                if plans[name] > total_passes:
                    done.add(name)
            else:
                pos[name] = [p + x / dist * stepd for p, x in zip(pos[name], d)]
            set_root(sim, name, pos[name])
        sim.run_for(wait, 1 / 30)
        if hook:
            hook(steps)
    return steps


def main():
    sim = boot()
    sim.physics = rbx_physics.make_physics()
    alice = sim.add_player("Alice", 1001)
    bob = sim.add_player("Bob", 1002)
    sim.run_for(8, 1 / 30)

    # ------------------------------------------------------------------ course geometry + helpers
    g = srv(sim, GEOMETRY)
    print("course:", {k: (round(v, 1) if isinstance(v, float) else v) for k, v in g.items()})
    check(g["count"] == 26 and g["total"] == 52, f"26 gates per lap, 2 laps = {int(g['total'])} passes")
    check(g["firstGate"] == 1 and g["lastGate"] == 0, "the first pass is gate 1, the last is the arch again (finish)")
    check(70 < g["minGap"] and g["maxGap"] < 170, f"gates are {g['minGap']:.0f}-{g['maxGap']:.0f} studs apart (a ring every second or so)")
    check(g["maxTurn"] < 60, f"no sharp corners (largest turn between gates {g['maxTurn']:.0f} deg)")
    check(g["minY"] > 10, f"the course never touches the island (lowest gate {g['minY']:.0f} above the surface)")
    check(g["padsOk"] and g["pads"] == 8, "eight start pads on the island")
    check(g["boosts"] == 5 and g["boostMinDist"] > 30, f"{int(g['boosts'])} boost rings between the gates")
    check(2500 < g["length"] < 4500, f"a lap is {g['length']:.0f} studs")
    check(g["archDir"] < -0.9, "the start arch looks north (racers fly towards -Z)")
    check(g["score"] == 83456 and g["text"] == "1:23.456", f"time <-> score <-> text round trips ({g['text']})")
    check(len(g["month"]) == 6 and g["month"].startswith(str(int(g["year"]))), f"month key {g['month']}, previous {g['prev']}, {g['left'] / 86400:.1f} days left")
    check([g["civil0"], g["civil1"], g["civil2"], g["civil3"], g["civil4"]] == [0, 11017, 20727, 20819, 19783], "calendar arithmetic for the month end is right")
    check(0 < g["left"] <= 31 * 86400, f"the month ends in {g['left'] / 86400:.1f} days")
    check(abs(g["dec"] - 17 * 86400) < 2 and g["nov30"] == 1, "the month countdown crosses month and year ends correctly")
    check(g["courseLeave"] > g["courseRadius"] + 200, f"the whole circuit (reach {g['courseRadius']:.0f}) is inside the leave limit ({g['courseLeave']:.0f})")

    # ------------------------------------------------------------------ the island exists
    isl = srv(sim, '''
local world = workspace:FindFirstChild("World")
local island = world and world:FindFirstChild("RaceIsland")
local gates, boosts, pads, join, arena = 0, 0, 0, false, false
if island then
	for _, d in island:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute("Gate") ~= nil then gates += 1 end
		if d:IsA("Model") and d:GetAttribute("Boost") ~= nil then boosts += 1 end
		if d:IsA("BasePart") and string.match(d.Name, "^Pad%d$") then pads += 1 end
		if d.Name == "JoinPad" then join = d:FindFirstChildOfClass("ProximityPrompt") ~= nil end
		if d.Name == "ArenaFloor" then arena = true end
	end
end
local boards = 0
local lbf = world and world:FindFirstChild("Leaderboards")
if lbf then for _, m in lbf:GetChildren() do
	if m.Name == "Leaderboard_RaceMonthly" or m.Name == "Leaderboard_RaceBest" or m.Name == "Leaderboard_ArenaKills" then boards += 1 end
end end
local parts = island and #island:GetDescendants() or 0
shared.R = { island = island ~= nil, gates = gates, boosts = boosts, pads = pads, join = join, arena = arena, boards = boards, parts = parts,
	winners = island and island:FindFirstChild("Winners", true) ~= nil or false }''')
    print("island:", isl)
    check(isl["island"] and isl["gates"] == 26 and isl["boosts"] == 5 and isl["pads"] == 8, "the island is built: 26 gates, 5 boost rings, 8 pads")
    check(isl["join"] and isl["arena"] and isl["winners"], "join pad with prompt, arena floor and winners board")
    check(isl["boards"] == 3, "three leaderboard screens on the island plaza")
    check(isl["parts"] < 6000, f"{isl['parts']} instances on the island")

    # nothing solid stands on the racing line (pillars, signs, boards, the arena)
    clear = srv(sim, '''
local island = workspace.World.RaceIsland
local params = OverlapParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { island }
local hits = {}
local checked = 0
for i = 1, #RaceConfig.Gates do
	local a = RaceConfig.toWorld(RaceConfig.Gates[i].Position)
	local b = RaceConfig.toWorld(RaceConfig.Gates[i % #RaceConfig.Gates + 1].Position)
	for s = 0, 16 do
		local p = a:Lerp(b, s / 17)
		checked += 1
		for _, part in workspace:GetPartBoundsInRadius(p, 9, params) do
			if part.CanCollide then
				hits[part.Name] = (hits[part.Name] or 0) + 1
			end
		end
	end
end
local names = {}
for n, c in hits do table.insert(names, n .. " x" .. c) end
shared.R = { checked = checked, solid = #names, names = table.concat(names, ", ") }''')
    check(clear["solid"] == 0, f"nothing solid within 9 studs of the racing line ({int(clear['checked'])} points checked) {clear['names']}")

    # ------------------------------------------------------------------ not on the island: refused
    r = req(sim, alice, "Race", "Join")
    check(not r["ok"] and r["err"] == "NOT_ON_ISLAND", f"joining from the valley is refused ({r['err']})")

    # ------------------------------------------------------------------ travel there
    for p in (alice, bob):
        r = req(sim, p, "Travel", "To", '{ Place = "RaceIsland" }')
        check(r["ok"], f"{p.props.get('Name')} travels to the Race Island")
    sim.run_for(3, 1 / 30)

    # ------------------------------------------------------------------ lobby
    r = req(sim, alice, "Race", "Join")
    check(r["ok"] and r["data"]["State"] == "Lobby", "Alice joins: a lobby opens")
    r = req(sim, alice, "Race", "StartNow")
    check(r["ok"], "alone she may start straight away...")
    # ...but Bob joins before the 3 s are over
    r = req(sim, bob, "Race", "Join")
    check(r["ok"] and len(r["data"]["Racers"]) == 2, "Bob joins the same lobby")
    r = req(sim, bob, "Race", "StartNow")
    check(not r["ok"] and r["err"] == "NOT_ALONE", "with two racers nobody can cut the lobby short")
    st = state(sim, "Alice")
    check(st["state"] in ("Lobby", "Countdown"), f"RaceState attribute ({st['state']})")
    # the lobby timer (SoloStart shortened it to 3 s: it is already running) - wait for the countdown
    sim.run_for(3.2, 1 / 30)
    st = state(sim, "Alice")
    check(st["state"] == "Countdown" and st["active"], f"countdown: RaceState={st['state']}, standard stats on ({st['active']})")
    check(st["riding"], "both are on their dragons")
    pa, anchored_a = root_pos(sim, "Alice")
    pb, anchored_b = root_pos(sim, "Bob")
    pads = srv(sim, 'local a = RaceConfig.toWorld(RaceConfig.Pads[1]) local b = RaceConfig.toWorld(RaceConfig.Pads[2]) shared.R = { ax = a.X, az = a.Z, bx = b.X, bz = b.Z }')
    check(abs(pa[0] - pads["ax"]) < 3 and abs(pa[2] - pads["az"]) < 3, "Alice stands on pad 1")
    check(abs(pb[0] - pads["bx"]) < 3 and abs(pb[2] - pads["bz"]) < 3, "Bob stands on pad 2")
    check(anchored_a and anchored_b, "both dragons are held on the grid (no false start)")
    check(state(sim, "Alice")["start"] == 0, "no start time yet")
    # travelling during the race is refused
    r = req(sim, bob, "Travel", "To", '{ Place = "Spawn" }')
    check(not r["ok"] and r["err"] == "RACING", f"travel is blocked during a race ({r['err']})")

    # ------------------------------------------------------------------ GO
    sim.run_for(3.3, 1 / 30)
    st = state(sim, "Alice")
    check(st["state"] == "Running" and st["start"] > 0 and st["pass"] == 1, f"GO: running, next gate {st['pass']}")
    _, anchored_a = root_pos(sim, "Alice")
    check(not anchored_a, "the dragons are released")

    # ------------------------------------------------------------------ the race: Alice 300 studs/s, Bob 240
    total = int(g["total"])
    cash0 = {"Alice": state(sim, "Alice")["cash"], "Bob": state(sim, "Bob")["cash"]}
    fly(sim, {"Alice": 1, "Bob": 1}, total, {"Alice": 300, "Bob": 240})
    sim.run_for(1.0, 1 / 30)
    sa, sb = state(sim, "Alice"), state(sim, "Bob")
    print("after the race:", sa, sb)
    check(sa["runs"] == 1 and sb["runs"] == 1 and sa["best"] > 0 and sb["best"] > 0, "both finished (the race closes as soon as the last racer is over the line)")
    check(not sa["active"] and not sb["active"], "...and both are back on their own dragons")
    check(sa["best"] > 0 and sb["best"] > sa["best"], f"Alice {sa['best']} ms < Bob {sb['best']} ms")
    length = g["length"] * 2
    # (the test hops from ring to ring in 0.1 s steps and wastes half a step at every ring)
    check(abs(sa["best"] / 1000 - length / 300) / (length / 300) < 0.25, f"Alice's time matches 300 studs/s ({sa['best'] / 1000:.1f}s for {length:.0f} studs)")
    check(sa["runs"] == 1 and sa["wins"] == 1 and sb["wins"] == 0, "Alice won, Bob did not")
    check(sa["monthBest"] == sa["best"], "monthly best recorded too")
    check(sa["cash"] > cash0["Alice"] and sb["cash"] > cash0["Bob"] and sa["cash"] - cash0["Alice"] > sb["cash"] - cash0["Bob"], "rewards: the winner gets more")
    v = srv(sim, '''
shared.R = { a = LB.valueOf(alice, "RaceBest"), b = LB.valueOf(bob, "RaceBest"), am = LB.valueOf(alice, "RaceMonthly"), aexp = RaceConfig.timeScore(PDS.Get(alice).Race.Best) }''')
    check(v["a"] == v["aexp"] and v["b"] > 0 and v["a"] > v["b"] and v["am"] == v["a"], "leaderboard scores follow the times (faster = higher)")
    top = req(sim, alice, "Race", "Top", '{ Board = "RaceBest" }')["data"]["List"]
    topm = req(sim, alice, "Race", "Top", '{ Board = "RaceMonthly" }')["data"]["List"]
    check(len(top) == 2 and top[0]["Name"] == "Alice" and top[1]["Name"] == "Bob", f"fastest racers: {[t['Name'] + ' ' + t['Text'] for t in top]}")
    check(len(topm) == 2 and topm[0]["Text"] == top[0]["Text"], "monthly board agrees")
    sim.run_for(5.5, 1 / 30)  # the race closes
    st = state(sim, "Alice")
    check(st["state"] == "" and not st["active"], "afterwards the standard stats are off and the state is clear")
    snap = req(sim, alice, "Race", "State")["data"]
    check(snap["State"] == "Idle" and snap["Best"] == sa["best"] and snap["Prize"] == "$50 PRIZE", f"window snapshot: {snap['State']}, best {snap['Best']}, {snap['Prize']}")

    # ------------------------------------------------------------------ "race again": back to the island, then a second race (Bob alone)
    far_pos, _ = root_pos(sim, "Bob")
    r = req(sim, bob, "Travel", "To", '{ Place = "RaceIsland" }')
    check(r["ok"], "a finisher may travel back to the island at once")
    sim.run_for(3, 1 / 30)
    check(req(sim, bob, "Race", "State")["data"]["OnIsland"], "...and is on the island again")

    # ------------------------------------------------------------------ cheats (a second race, Bob alone)
    req(sim, bob, "Race", "Join")
    req(sim, bob, "Race", "StartNow")
    sim.run_for(3.5 + 3.5, 1 / 30)
    check(state(sim, "Bob")["state"] == "Running", "second race: Bob runs")
    # (a) teleport ahead: the speed check disqualifies him (and a jump never counts for a ring)
    far = world_gate(sim, 6)
    for i in range(3):
        set_root(sim, "Bob", [far["x"] - far["dx"] * 10 - i, far["y"], far["z"] - far["dz"] * 10])
        sim.run_for(0.12, 1 / 30)
        set_root(sim, "Bob", [far["x"] + far["dx"] * 10 + i, far["y"], far["z"] + far["dz"] * 10])
        sim.run_for(0.12, 1 / 30)
    sim.run_for(1.2, 1 / 30)
    st = state(sim, "Bob")
    check(st["state"] == "" and not st["active"], f"teleporting through a far gate gets you disqualified (state '{st['state']}')")
    sim.run_for(6, 1 / 30)

    # (b) honest rings only: a hop, backwards, past the ring or around it never counts
    r = req(sim, bob, "Travel", "To", '{ Place = "RaceIsland" }')  # (the cheat left him far from the island)
    check(r["ok"], "a disqualified racer can travel back to the island")
    sim.run_for(3, 1 / 30)
    req(sim, bob, "Race", "Join")
    req(sim, bob, "Race", "StartNow")
    sim.run_for(3.5 + 3.5, 1 / 30)
    check(state(sim, "Bob")["state"] == "Running", "third race: Bob runs again")
    g1 = world_gate(sim, 1)
    c = [g1["x"], g1["y"], g1["z"]]
    d = [g1["dx"], g1["dy"], g1["dz"]]

    def move_to(target, speed=250):
        p, _ = root_pos(sim, "Bob")
        while True:
            dv = [t - q for t, q in zip(target, p)]
            dist = sum(x * x for x in dv) ** 0.5
            if dist < speed * 0.1:
                set_root(sim, "Bob", target)
                sim.run_for(0.1, 1 / 30)
                return
            p = [q + x / dist * speed * 0.1 for q, x in zip(p, dv)]
            set_root(sim, "Bob", p)
            sim.run_for(0.1, 1 / 30)
    # fly up to a point 60 studs BEFORE the ring (never touching its plane)...
    move_to([c[0] - d[0] * 60, c[1] - d[1] * 60, c[2] - d[2] * 60])
    sim.run_for(0.6, 1 / 30)
    check(state(sim, "Bob")["pass"] == 1, "flying up to the ring does not count yet")
    # ...then a single 105 stud hop through it: a jump never counts (and one hop is not a speed crime)
    set_root(sim, "Bob", [c[0] + d[0] * 45, c[1] + d[1] * 45, c[2] + d[2] * 45])
    sim.run_for(0.6, 1 / 30)
    st = state(sim, "Bob")
    check(st["pass"] == 1 and st["state"] == "Running", f"a jump through the ring does not count (next gate {st['pass']}, {st['state']})")
    move_to([c[0] - d[0] * 40, c[1] - d[1] * 40, c[2] - d[2] * 40])  # backwards through the ring
    st = state(sim, "Bob")
    check(st["pass"] == 1, "flying through a gate backwards does not count")
    side = [c[0] + d[2] * 70, c[1], c[2] - d[0] * 70]  # 70 studs to the side
    move_to([side[0] - d[0] * 40, side[1], side[2] - d[2] * 40])
    move_to([side[0] + d[0] * 40, side[1], side[2] + d[2] * 40])
    st = state(sim, "Bob")
    check(st["pass"] == 1, "flying past the gate (outside the ring) does not count")
    move_to([c[0] - d[0] * 30, c[1], c[2] - d[2] * 30])
    move_to([c[0] + d[0] * 30, c[1], c[2] + d[2] * 30])
    st = state(sim, "Bob")
    check(st["pass"] == 2, "through the ring the right way: the next gate is 2")
    # (c) dismounting ends the run
    srv(sim, 'MS.Dismount(bob) shared.R = {}')
    sim.run_for(0.5, 1 / 30)
    st = state(sim, "Bob")
    check(st["state"] == "" and not st["active"], "getting off the dragon ends the race (DNF)")
    sim.run_for(6, 1 / 30)

    # ------------------------------------------------------------------ queue: join while a race runs
    req(sim, alice, "Race", "Join")
    req(sim, alice, "Race", "StartNow")
    sim.run_for(3.5 + 1, 1 / 30)
    r = req(sim, bob, "Race", "Join")
    check(r["ok"] and r["data"]["Joined"], "Bob can queue up while the race is under way")
    # Alice leaves -> race ends; the queue opens a lobby
    req(sim, alice, "Race", "Leave")
    sim.run_for(8, 1 / 30)
    r = req(sim, bob, "Race", "State")["data"]
    check(r["State"] in ("Lobby", "Countdown", "Running") and r["Joined"], f"the waiting racer is in the next lobby ({r['State']})")
    req(sim, bob, "Race", "Leave")
    sim.run_for(2, 1 / 30)

    # ------------------------------------------------------------------ the monthly champion
    out = srv_wait(sim, '''
-- fake the previous month's store: Alice won with 41.234 s
LB.TopOfStore = function(name, count)
	return { { UserId = alice.UserId, Value = RaceConfig.timeScore(41234) } }
end
local cash0 = PDS.Get(alice).Cash
RaceService._rollover()
local w = RaceService.Winners()
local island = workspace.World.RaceIsland
local row = island:FindFirstChild("Row1", true)
shared.R = { n = #w, month = w[1] and w[1].Month or "", name = w[1] and w[1].Name or "", ms = w[1] and w[1].Ms or 0, prev = RaceConfig.previousMonthKey(),
	flag = PDS.Get(alice).Flags.RaceChampion or "", cashGain = PDS.Get(alice).Cash - cash0, crown = PDS.Get(alice).Race.Crowns[RaceConfig.previousMonthKey()] == true,
	row = row and row.Text or "" }''')
    print("champion:", out)
    check(out["n"] == 1 and out["month"] == out["prev"] and out["ms"] == 41234, "the monthly champion is recorded (month, name, time)")
    check(out["flag"] == out["prev"] and out["crown"] and out["cashGain"] > 0, "the champion gets the trophy flag and a reward")
    check("41.234" in out["row"] or "0:41.234" in out["row"], f"the podium board shows the winner ({out['row'].strip()})")
    out2 = srv_wait(sim, '''
RaceService._rollover()
shared.R = { n = #RaceService.Winners() }''')
    check(out2["n"] == 1, "a month is only recorded once")

    # ------------------------------------------------------------------ Studio helpers (UI Lab TEST row)
    r = req(sim, alice, "Dev", "RaceTime")
    if r["ok"]:
        d = srv(sim, 'shared.R = { best = PDS.Get(alice).Race.Best, month = PDS.Get(alice).Race.MonthBest }')
        check(d["best"] >= 41234 and d["month"] == d["best"], f"the RACE TIME test button sets a best time ({d['best']:.0f} ms)")
        r = req(sim, bob, "Dev", "RaceChampion")
        check(r["ok"], "the CHAMPION test button runs")
        sim.run_for(0.5, 1 / 30)
        d = srv(sim, '''
local w = RaceService.Winners()
shared.R = { first = w[1] and w[1].UserId or 0, prev = RaceConfig.previousMonthKey(), flag = PDS.Get(bob).Flags.RaceChampion or "", attr = bob:GetAttribute("RaceChampion") or "" }''')
        check(d["first"] == 1002 and d["flag"] == d["prev"] and d["attr"] == d["prev"], "...Bob is crowned: podium entry, trophy flag and the crown attribute")
    else:
        print("  (the Dev helpers are not registered in this run: skipped)")

    print("errors:", len(sim.errors), sim.errors[:3])
    check(len(sim.errors) == 0, "no script errors")
    print("\nFAILED:" if FAIL else "\nALL OK", FAIL if FAIL else "")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
