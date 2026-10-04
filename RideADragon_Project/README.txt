RIDE A DRAGON - project snapshot (4 Oct 2026, TEST 9)
======================================================

CONTENTS
  RideADragon_Dev.rbxlx   Ready-to-open place file (Roblox Studio: File > Open).
                          Built from the source below at the time of this snapshot.
  RideADragon/            Game source (Luau) in Rojo layout:
                            default.project.json  - Rojo project file
                            src/                  - ReplicatedFirst, ReplicatedStorage,
                                                    ServerScriptService, StarterPlayer
  toolchain/              Offline tools used to build and test the game (Python 3):
                            build_place.py  - builds the .rbxlx from default.project.json
                                              (refuses to build when the real Luau compiler finds
                                              a syntax / type error in any script)
                            luau_lint.py    - Luau linter
                            tests/          - simulation tests (shop, spin, eggs, inventory, race,
                                              combat, animations...)
                            worldgen/       - terrain / layout generator for Dragon Haven

OPEN / TEST IN STUDIO
  1. Open RideADragon_Dev.rbxlx in Roblox Studio and press Play.
  2. UI Lab (Studio only, ` key) > TEST row: +$1M, ALL 30 DRAGONS, FILL EGGS, HATCH NOW.
  3. Robux items with Id = 0 are free TEST purchases inside Studio.
  4. If something does not start, the red Diagnostics panel (Studio only) lists the script errors.

REBUILD THE PLACE FROM SOURCE
  cd toolchain
  python3 build_place.py ../RideADragon/default.project.json ../RideADragon_Dev.rbxlx
  (or sync RideADragon/default.project.json with Rojo)

ROBUX ITEMS (before publishing)
  Create the game pass / developer products on create.roblox.com with the same
  prices and paste their IDs into
  ReplicatedStorage > Configs > MonetizationConfig (field Id):
    Game passes: Owner Dragon 3000, PRINCE 8999, N2RC1S 8999, LEGENDARY M0NICA DRAGON 11999,
                 EGG HUNTER 1299
    Products: Luck Potion 49, Super Luck Potion 149, Cash Potion 49, Level Potion 39,
              Mutation Potion 99, 5 Spins 49, 25 Spins 199, Cash packs 25 / 99 / 249,
              Egg Radar 49, Egg Magnet 39, Fast Hatch 59, Lucky Egg Call 99, Mythic Bundle 249

SOUNDS
  Every sound is a key in ReplicatedStorage > Configs > AudioConfig; an empty Id is skipped
  silently. New keys in this snapshot: EggPlace, RaceCount, RaceGo, RaceGate, RaceBoost,
  RaceFinish, Strike, Blast, Hit, Knockout, DuelStart (paste Creator Store ids to give them a sound).

RACE & BATTLE ISLAND (new in TEST 5)  -  Teleport menu > RACE ISLAND (or fly north-east)
  A floating LEGO island with a plaza, start grid, a sky circuit, a duel arena, a podium and
  three leaderboard screens.
  - SKY CIRCUIT: 2 laps of 26 ring gates (about 2,750 studs a lap) with 5 cyan BOOST rings. Join at
    the red pad (or in the Race window): a 20 s lobby fills, everybody is put on the start grid,
    3-2-1-GO. A lone racer can press START NOW (time trial). EVERYBODY RACES THE SAME STANDARD
    DRAGON (no bond perks, no tree bonuses): the line you fly and the boost rings decide.
    The server checks every racer 10 times a second: rings in order and forward only, speed,
    dismounting, leaving the course. HUD: timer, gate / lap counter, place, a marker on the
    next ring (an arrow at the screen edge when it is out of view; the next ring glows).
    Finish card: place, time, personal best, rewards (cash from your income + XP) and everybody's
    results. Cheaters / people who leave get no result.
  - LEADERBOARDS on the island plaza (and the Race window): FASTEST RACERS (best time ever),
    MONTHLY RACE (this month's best time), ARENA WARRIORS (knockouts). The hub plaza also has
    STRONGEST DRAGON and HIGHEST LEVEL DRAGON.
  - MONTHLY PRIZE ("$50"): the fastest racer of a month wins. Roblox cannot pay real money from
    a game script, so the game RECORDS the winner and gives the in-game honours:
      * the first server that runs on the 1st (UTC) reads last month's top time and writes the
        winner (month, UserId, name, time) once to the DataStore "RaceWinners_v1", key "history"
        (open it in Creator Hub > your experience > Data Stores), prints
        "[Race] MONTHLY WINNER 2026xx: Name (id N) in m:ss.mmm" to the server log and shows the
        winner on the podium of the island and in the Race window (PAST CHAMPIONS);
      * the whole server gets a banner, the winner gets a trophy flag, +cash +XP, and a gold
        "RACE CHAMPION" line over their dragon for the next month.
    YOU pay the prize outside the game (for example by sending the winner a Robux gift or a
    PayPal / gift card): look the winner up in "RaceWinners_v1" and check their run if you wish.
    Change the text / amount in RaceConfig.Monthly (PrizeText, Headline).
  - DUEL ARENA (PvP): fly into the arena on your dragon and other riders can hit you - and you
    can hit them. STRIKE (F / left click / gamepad X): a bite and tail slam in front of you.
    BLAST (G / gamepad R3): a fireball you aim (slower to recharge). Touch: two buttons.
    Hit points and damage come from the dragon's level and rarity; the server decides every hit
    (cooldowns, reach, cone, projectile flight). Knockout: 3 s on a respawn pad, then back with
    full hit points and a few seconds of protection. A knockout pays cash + XP (not twice for
    the same opponent within 45 s) and counts for ARENA WARRIORS. Nobody can be hit outside the
    arena, on foot, or while racing. A TRAINING DUMMY in the middle takes hits, shows damage
    numbers and a hit point bar, falls and stands up again, pays nothing.
  - New animations: Strike, Cast, Hurt. Numbers live in RaceConfig / CombatConfig.

BATTLE HALL: POKEMON-STYLE DUELS (new in TEST 9)  -  Teleport menu > BATTLE HALL (or the hall in the village)
  A turn-based duel in a fixed scene, like the old Pokemon games: your dragon in front on the left,
  the opponent's behind on the right, a name / hit point plate for each, a text box and a menu of
  four moves. The scene is built far above the world (nobody else sees it, nothing of the map is in
  the way); HUD and walking are held until the duel is over and come back on their own.
  - OPPONENTS: 4 NPC TRAINERS in the Battle window (Rookie Ren, Ranger Kai, Captain Vale, Champion
    Ashka). Their dragon's level follows YOUR equipped dragon (-2 / 0 / +3 / +6 levels), so a duel is
    never hopeless and never trivial. Or CHALLENGE ANOTHER PLAYER of the server (PLAYERS tab): they
    get an ACCEPT / DECLINE panel, the answer starts the duel on both screens (30 s to answer).
  - YOUR FIGHTER is the dragon you have EQUIPPED (change it in DRAGONS). Hit points and damage come
    from its level and rarity (the same formulas as the arena, hit points scaled down so a duel
    lasts about 5-7 turns).
  - MOVES (click or keys 1-4): STRIKE (reliable, free), FIRE (the strong breath, 8 uses, can miss),
    GUARD (goes first and halves the damage of the turn, 6 uses, fails if used twice in a row),
    SPECIAL (a mutated dragon: <MUTATION> BURST, the strongest hit, 3 uses; a normal dragon: ROAR,
    +30% damage for 3 turns, 4 uses). The faster dragon moves first (the one that flies faster).
    Every hit is rolled by the SERVER (accuracy, 8% critical, +-10% variance); the scene only plays it.
  - ELEMENTS: every species has an element (FIRE, WATER, NATURE, EARTH, STORM, ICE, DARK, LIGHT).
    Fire > Nature / Ice, Water > Fire / Earth, Nature > Water / Earth, Earth > Fire / Storm,
    Storm > Water / Ice, Ice > Nature / Earth, Dark and Light are neutral to each other.
    "It's super effective!" is x1.5, "It's not very effective..." x0.67.
  - REWARDS: a trainer pays cash from YOUR income (2-30 minutes of it, with a minimum) + XP, the first
    win of each trainer every 3 minutes (a rematch right away pays 25%). A player duel pays the winner
    like a trainer of the loser's level, the loser gets a little XP; a duel that ends in 2 turns or
    by a forfeit pays nothing (no win trading), the same two players within 10 minutes pay 25%.
    FORFEIT button any time (the other side wins). Leaving the game forfeits too.
    Counted: Stats DuelsWon / DuelsLost. Numbers: ReplicatedStorage > Configs > DuelConfig.
    Server: DuelService (Net domain "Duel"). Client scene: DuelController, window: DuelWindow.

DAILY REWARD + DRAGON INDEX (new in TEST 8)  -  the DAILY and INDEX buttons of the HUD work now
  - DAILY (button on the right, key J): a 7-day calendar. One reward per UTC day; claiming on
    consecutive days builds a streak that walks through the week (day 1 cash, 2 spins, 3 luck boost,
    4 cash, 5 spins + cash, 6 Golden Egg x5, 7 big cash + 5 spins + Celestial Egg x10). A whole day
    missed starts the streak again. Every completed week adds +10% to the cash (up to +100%). Cash is
    worth seconds of your income, so it grows with you. A red dot lights the button while a reward
    waits. Numbers: ReplicatedStorage > Configs > DailyConfig. Server: DailyService.
  - INDEX / Dragon Index (button on the left, key X): the collection book. A card for every species
    (3D preview when found, "?" when not), how many you found, the mutations you found of each (tap a
    card for the detail: description, base stats, the 16 mutations), filter ALL / FOUND / MISSING.
    The 30 hatchable species count; the 4 Robux exclusives are shown after them but do not count.
    MILESTONE REWARDS for 5 / 10 / 15 / 20 / 25 / 30 species found (cash, spins, luck boost, Golden
    Egg, and a Rainbow Egg x50 for the whole book). Numbers: IndexConfig. Server: IndexService.

COINS ON THE MAP (new in TEST 7)
  - About 290 coins along the roads and landmarks of Dragon Haven: COPPER coins on trails that
    follow every road (for walkers and low flyers), big gold SKY COINS in arcs above the roads and
    a ring above the village (for riders), and TREASURE GEMS at the landmarks (ruins, waterfall
    top and pool, cave mouth, the top of the sky pillar, lake island, the forests, the ends of
    the roads). Just touch a coin (on foot, or with your dragon) to take it.
  - A coin is worth a few seconds of your income (copper 0.6 s, sky coin 2 s, gem 30 s) so it
    stays worth taking as you grow, with a floor for new players ($6 / $20 / $150).
  - CHAIN: coins taken within 2.5 s of each other build a chain; every coin pays 25% more than
    the one before, up to x3. A pill under the cash shows "CHAIN x2.5  +$1.2K" while it runs.
  - Every player has their own coins; a coin you took comes back after 75 s (sky coin 100 s,
    treasure 10 min). The server checks every pickup (distance, your own cooldown) and pays.
  - Numbers, layout rules and respawn times: ReplicatedStorage > Configs > CoinConfig. Sounds:
    AudioConfig keys CoinPickup, CoinChain. The total is kept in Stats.Coins.

EGG HUNTING (new in TEST 6)  -  Shop > ROBUX tab: sections POTIONS / EGG HUNTING / CASH & SPINS
  - EGG RADAR (49 R$, 30 min): every egg on the map gets a marker you can see through walls and a
    chip under the level badge points an arrow at the best egg (luck + distance). Without the
    potion the same radar comes from the Forge upgrade (250 / 600 / 1200 studs / whole map).
  - EGG MAGNET (39 R$, 15 min): eggs are picked up from twice as far away. Adds up with the Great
    Tree "Egg Magnet" branch and the Egg Hunter pass.
  - FAST HATCH (59 R$, 30 min): eggs you put in the nest take half the time.
  - LUCKY EGG CALL (99 R$): 3 eggs with x25 - x100 luck appear around you (only you see them)
    for 5 minutes.
  - MYTHIC BUNDLE (249 R$): 3 Celestial Eggs with x50 luck straight into the bag (even when the
    bag is full: paid eggs are never lost).
  - EGG HUNTER pass (1,299 R$, permanent, no dragon): radar always on, +50% pickup range, +3 egg
    bag slots. Shown in the shop with an egg instead of a dragon.
  - HUD: a pill under the cash shows the running perks (MAGNET / FAST HATCH / HUNTER + timer);
    phones get a compact text and the row shrinks a little when many pills are lit.
  - Studio: Robux items with Id = 0 are free test purchases.

DONE IN THIS SNAPSHOT (TEST 5 additions first)
  - LEGENDARY M0NICA DRAGON (game pass 11,999 R$): +50T income, x20 luck.
  - ALL your dragons can rest on perches now (also the last one), RIDE brings the strongest
    one down; nicer LEGO perches and a bigger LEGO nest with lanterns and banners.
  - FIRE BREATH has a real animation (inhale, rear back, lunge, held blast) with a glowing ball
    gathering at the mouth first; hatching shows the dragon's FULL NAME and its NUMBER (No. NN)
    with letter-by-letter particles; 10 new everyday animations (yawn, stretch, tail swish,
    sniff, shake, twirl, bow, howl, cheer, loop) that perch dragons and companions play on their
    own and as reactions (a greeting when you walk up, a cheer when you find an egg).
  - Startup is protected: every script step runs in its own pcall and the build is checked with
    the real Luau compiler, so one broken script can no longer stop the game.
  - THE GREAT TREE (plaza, north-east of the statue): big LEGO tree with 5 pods (Luck, Wealth,
    Flight, Nest, Bond) whose orbs light up as you upgrade. 20 branches / 194 levels bought with
    cash (prices follow the economy). Every branch has a real effect: roll luck, mutation luck,
    find luck, spin luck/speed, income, offline earnings, Ancient Wisdom (XP), recycler refund,
    flight/run speed, boost length/regen, hatch speed, egg bag size, egg magnet, egg respawn,
    bond growth, quick feathers (shorter cooldowns), dragonfire range.
  - Player level system (LevelService): XP from picking up eggs, hatching (rarity, mutation,
    first discovery), flying, bond levels and tree upgrades; level-up rewards (cash, spin
    tickets every 5th level), region unlock notices, level shown in the HUD.
  - DRAGON BOND: riding a dragon raises ITS bond (only while moving: no AFK farming).
    Lv5 Wind Dash (Q / B), Lv10 Fire Breath (hold E / LB, burns "Burnable" things), Lv20 Sky Dance
    (Z / RB), Lv50 Bond Aura. Bond bar + ability cooldowns in the HUD, touch buttons on phones.
  - EGG IN HAND: a picked-up egg is carried in your hand (everyone sees it, arm cradles it);
    walk to your nest and place it in the nest spot you like (egg flies from your hand into the
    spot). Egg Bag window: HOLD button per egg; HUD chip with PUT AWAY.
  - Owner names float above every sanctuary plot (FREE when nobody lives there).
  - NEW HATCHING: the room darkens, the egg lifts and glows, cracks open one by one (camera
    shake, sparks), bursts in a flash + pillar of light, the dragon steps out and WALKS TO THE
    CAMERA, rears up and ROARS (shock wave, push-in), then the result card. Rare results get a
    longer charge and more cracks. SKIP button for impatient hatchers.
  - 6 NEW MUTATIONS (18 in total): Neon, Infernal, Corrupted, Crystal, Lightning, Angelic.
    Each one really changes the dragon: palette, glowing / glass materials, particles, a light in
    its colour, ribbons behind the wings, a halo (Angelic), crystal clusters (Crystal). The fire
    breath takes the mutation's colours (frost, venom, hellfire, lightning, holy light, rainbow...).
  - SERVER-WIDE ANNOUNCEMENTS: a hatch of "1 in 25,000" or rarer shows a banner to every player
    (after the hatcher's reveal, so nobody is spoiled); "1 in 1,000,000"+ gets a MEGA banner.
  - LUCKY WILD EGGS: every 10-20 minutes one special egg (Lucky / Epic / Mythic / Rainbow, x25 ...
    x2000 luck) appears somewhere in the world for the whole server: "A MYTHIC EGG HAS SPAWNED!
    02:00", a pillar of light, a countdown, an arrow and the distance. First to reach it wins.
  - Studio test buttons (UI Lab, ` key): WILD EGG, BOND MAX, MEGA BANNER next to +$1M, ALL 30
    DRAGONS, FILL EGGS, HATCH NOW.
  - Earlier snapshot:
  - 30 LEGO dragons (6 body types) + mutations with effects, "1 in N" rarity titles,
    RNG roll animation when hatching
  - Exclusive dragons: Owner Dragon (x2 luck), PRINCE and N2RC1S (x3 luck, Omni = all mutations)
  - Robux shop (passes, potions, spin packs, cash packs) + cash upgrades
  - White HUD, Teleport menu, leaderboards at spawn (earned, hatched, income, play time)
  - Spin Wheel Island (3D wheel, camera view, auto x5, luck-weighted prizes)
  - 14 egg types across regions + Golden / Rainbow special eggs, more eggs in the world,
    every world egg has its own luck (x1 ... x1000) shown above it and used when it hatches
  - Your dragon picks up eggs (riding, and the companion flies to nearby eggs)
  - Passive income, offline earnings, inventory, perches, nest, spawn at own plot

NOT FINISHED YET (planned next, in this order)
  - The QUESTS button of the HUD (and the Elder Rowan station) opens nothing yet: the window was
    never built in the original project. Next: Quests and the guided tutorial for new players.
  - Pokemon-style turn-based duel scene (planned, in this order after the quests).
  - New eggs / dragons and the zones they live in
  - Bigger map with Frostpeak / Ember Caldera / Skyreach regions (their eggs currently
    spawn at the valley's landmark spots: plateau, cave, ruins, pillar, island)
  - Hidden eggs / treasure, weather and events, Golden Dragon, adventure + boss, collection
    book, titles, daily streak, coins on the map
  - Audio ids (see SOUNDS) still have to be pasted in
