RIDE A DRAGON - project snapshot (4 Oct 2026, TEST 12)
======================================================

NEW IN TEST 12 (short)
  - EGG GUARDIANS: every egg in the world lies in a NEST and a dragon guards it. To take the egg you must beat the
    guardian in a Pokemon-style duel. The stronger the egg (tier + luck), the stronger the guardian (see EGG
    GUARDIANS below). Lucky Egg Call eggs (Robux) and the wild event eggs have no guardian.

NEW IN TEST 11 (short)
  - QUESTS WORK NOW (the QUESTS button, key Q, and Elder Rowan's hut): see QUESTS below.
  - The owner's statue wears a preset "Dragon King" outfit (armor, cape, crown) instead of your own clothes.

NEW IN TEST 10 (short)
  - FOUR NEW SKY ISLANDS: Crystal Isle, Bloom Isle, Ember Isle, Frost Isle (see SKY ISLANDS below).
  - EGGS EVERYWHERE: up to 24 eggs per player; half of them appear at random places of the whole land,
    a third of those on the sky islands; wild eggs roam over land and islands too.
  - THE STATUE IN THE MIDDLE OF THE PLAZA IS NOW THE OWNER (your avatar, "Bendzaminoo").
  - Teleport menu: a card for every island.

NEW IN TEST 9 (short)
  - ADMIN /give system (from your TEST8_ADMIN_GIVE zip) is in, with your MonetizationConfig untouched
    (Cash Potion still has Id 0).
  - RANKS: five ranks with titles + the chat command  /rank <player|me> <rank|none>  (see RANKS below).
  - SELL dragons: SELL button with the price on every dragon + SELL SHOWN for a whole filtered list.
  - ECONOMY lowered: a smoother income ladder, cheaper and fair feeding (see ECONOMY below).
  - The START / FINISH beam of the race no longer hangs across the first ring.
  - Eggs appear at random places of the whole land; wild eggs always roam.
  - The dragon cards in the inventory show their 3D models again (they stayed on the grey icon).
  - BATTLE HALL duels (Pokemon-style) are in as well (they were TEST 9 before the rest).

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
              Mutation Potion 389, 5 Spins 49, 25 Spins 199, Cash packs 25 / 299 / 249,
              Egg Radar 49, Egg Magnet 49, Fast Hatch 59, Lucky Egg Call 99, Mythic Bundle 249
  MonetizationConfig in this snapshot is YOUR version from the TEST8_ADMIN_GIVE zip (ids and the
  prices above), untouched; Cash Potion still has Id 0 until its developer product exists
  (see DEVELOPER_PRODUCTS_NOTE.txt).

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

EGG GUARDIANS (new in TEST 12)  -  fly to any glowing egg in the world
  - Every egg of the normal spawn cycle (24 per player) lies in a nest of twigs and stones. A dragon - its GUARDIAN -
    stands next to it, wakes up when you come near (it turns to you and roars) and has a label: its name, level and
    how dangerous it is for YOUR equipped dragon (EASY / FAIR / HARD / DEADLY).
  - Flying or walking through the egg does NOT take it any more (the Egg Magnet only widens the challenge range).
    When you are close, the CHALLENGE button appears at the bottom (key X, or tap it): the Pokemon-style duel scene
    starts. WIN = the egg jumps into your hand (or the bag) + XP, the guardian fades away and a new egg grows later.
    LOSS or RUN AWAY = the egg stays; the same guardian needs 6 seconds before the next challenge.
  - Strength: power = egg tier + log10(luck). The guardian's species comes from the rarity pool of the power
    (Common ... Secret), its level is yours + a bonus that grows with the power, a lucky egg also has a mutated
    guardian (stronger SPECIAL), and a stronger guardian is drawn bigger. The weakest guardians are a bit softer
    so the first egg is a fair win. Typical result: an equal dragon wins ~75%, one tier stronger ~45%, two tiers
    ~20% (type advantages and good moves change that).
  - A full egg bag cannot start a challenge; if the bag fills up during the duel the won egg still comes.
  - XP for a win: 20 x 1.55^(power - 1)  (Haven Egg x1: 20 XP, Celestial Egg x1000: ~670 XP). A new quest kind
    "Beat egg guardians" and the Getting Started goal "Win an egg from its guardian" use it (Stats.Guardians).
  - Numbers: ReplicatedStorage > Configs > EggConfig > Guardians (Enabled, Range, Pools, Mutations, Soften, XP...).
    Code: EggConfig.guardian, Services/EggService (GuardInfo / CollectGuarded / GuardLost), Services/DuelService
    (Duel.Guardian), Controllers/EggController (nest, guardian model, button), Controllers/DuelController,
    tests/guardian_test.py. Tests that walk into eggs switch guardians off with sim_runner.NO_GUARDIANS.

QUESTS (new in TEST 11)  -  the QUESTS button of the HUD, key Q, or Elder Rowan's hut (Teleport > ELDER ROWAN)
  - GETTING STARTED: seven first goals for a new player (ride, fly 500 studs, win an egg, hatch a dragon, rest a
    dragon on a perch, feed a dragon, buy an upgrade). Each pays once ($150-$500, the last one also 2 spins); the
    list disappears when you have taken them all.
  - ACTIVE QUESTS: always 3 quests from 12 kinds (find eggs, hatch, fly, earn from perch dragons, feed, boost, collect
    coins, sell dragons, spin the wheel, mutation tries, win a duel, beat egg guardians). A quest counts from the moment it is given. The
    reward is cash (grows with your level, never less than 150 s of your income) + player XP; every 3rd quest also
    gives a free spin; a NEW quest takes the place of the one you took.
  - A red number on the QUESTS button says how many rewards wait.
  - Numbers: ReplicatedStorage > Configs > QuestConfig (Templates, Starter, RewardPerLevel, ...).
    Code: Services/QuestService, Controllers/QuestController, UI/Windows/QuestsWindow, tests/quest_test.py.

SKY ISLANDS + EGGS EVERYWHERE (new in TEST 10)  -  Teleport menu > CRYSTAL / BLOOM / EMBER / FROST ISLE
  Four floating LEGO islands (WorldConfig.SkyIslands: position, size, theme, egg region). Fly there on a dragon
  (they float at 290-430 studs, away from the race circuit) or use the Teleport menu (a landing pad):
    CRYSTAL ISLE (-430, 330, 560)  glowing crystal spires, a shimmering pool        eggs of Skyreach
    BLOOM ISLE   (380, 290, 330)   a giant flower, mushrooms, round trees           eggs of Dragon Haven
    EMBER ISLE   (-780, 380, -330) a small volcano with lava flows, charred trees   eggs of Ember Caldera
    FROST ISLE   (60, 430, -880)   ice spikes, snowy pines, a frozen pond, an igloo eggs of Frostpeak
  Every island has a floating name sign (visible from far away) and glowing stalactites underneath. It is a
  RARE egg area: the luck of an egg that grows there rolls twice and keeps the better one.
  - EGGS: every player has up to 24 own eggs in the world (EggConfig.Spawning.MaxActive). Half of the new ones
    appear at a completely random place of the whole land (not near the fixed areas), and a third of those on
    a random sky island; the rest scatter (70 studs) round the named areas, which now include the 4 islands.
    Wild (lucky) eggs always roam: anywhere on the land or on an island, never close to the previous one.
    The knobs: EggConfig.Spawning (MaxActive, RoamingShare, IslandShare, ScatterRadius, WorldBox).
  - Code: World/SkyIslands.luau (the builder), Services/IslandService (builds them, registers the egg areas),
    EggService.AddArea / RandomSpot, TravelService (places = island ids), toolchain/tests/island_test.py.

THE OWNER'S STATUE (new in TEST 10)
  The statue in the middle of the plaza (on the fountain plinth) is now the owner instead of the stone dragon: built
  from the real avatar of WorldConfig.PlazaStatue.Username ("Bendzaminoo"; or set UserId), 3.6 times the size of a
  normal avatar, in a PRESET "Dragon King" outfit (your face, hair and skin; dark suit, gold breastplate with a gem,
  pauldrons, belt, gauntlets, red cape, crown - set PlazaStatue.Outfit = "Own" to keep your own clothes), right fist raised, with a plaque on the plinth and a floating "OWNER - Dragon King" title in the
  rank colours. If the avatar cannot be loaded (no web access, wrong name) a marble king with a crown stands
  there instead. Change who it is or how big in ReplicatedStorage > Configs > WorldConfig > PlazaStatue.
  Code: Services/StatueService.luau, toolchain/tests/statue_test.py.

ADMIN COMMANDS + RANKS (new in TEST 9)  -  see ADMIN_COMMANDS.txt
  Who is the owner: ReplicatedStorage > Configs > AdminConfig (username "Bendzaminoo", extra user ids,
  the experience creator, and EVERYBODY inside Roblox Studio so it can be tested).
  Typed in the chat (the new chat: nobody sees the line, the client sends it to the server which checks
  who you are; the old chat: the server reads Player.Chatted):
    /give me Cash 10000   /give PlayerName PrinceDragon   /givehelp          (see ADMIN_COMMANDS.txt)
    /rank PlayerName vip          vip / mod / admin / coowner / owner, or 1-5, or none to remove
    /rank me owner                (the owner may rank himself)
    /ranks                        the five ranks and who has one in this server
    /rankhelp
  RANKS (ReplicatedStorage > Configs > RankConfig - change titles, epithets, colours there):
    1 VIP        Friend of the Dragons   gold      tag + chat colour
    2 MOD        Keeper of the Peace     blue      tag + chat colour
    3 ADMIN      Warden of the Realm     orange    tag + chat colour
    4 CO-OWNER   Dragon Lord             purple    tag + chat colour + may use /give and /rank up to ADMIN
    5 OWNER      Dragon King             red       tag + chat colour + everything
  A rank shows as a coloured tag over the character (title + epithet; CO-OWNER and OWNER with stars),
  as a coloured [TITLE] in front of every chat line and in /ranks. It is saved with the player (Rank).
  The owner can also rank somebody who is not in the server: /rank TheirUsername vip - they get it
  the next time they join (stored in the DataStore "RankGrants_v1"). A CO-OWNER cannot hand out
  CO-OWNER / OWNER and cannot change somebody who ranks as high as they do.

SELLING DRAGONS (new in TEST 9)
  - SELL button in the dragon details shows the price: 300 seconds of the dragon's BASE income
    (species income x mutation). The level does not count, so feeding a dragon and selling it can
    never make money. The Gentle Goodbye branch of the Great Tree pays more (up to x5).
  - SELL SHOWN (bottom of the Dragons window): sells every dragon of the current filter / search at once
    after ONE confirmation (count + total, a warning when Epic or better are in it). Locked, equipped,
    resting-on-a-perch and Exclusive dragons are always kept; one dragon always stays.
  - Exclusive (Robux) dragons cannot be sold. Server: DragonService Sell / SellBulk (Release = old name).

ECONOMY (lowered in TEST 9)  -  ReplicatedStorage > Configs > DragonConfig / EconomyConfig
  The income of the regular dragons was inflating about x20-x80 per rarity (a Secret dragon made $642M/s
  while an Epic made $6K/s). New base income per second at level 1, no mutation:
    Common 2-4.5, Uncommon 9-19, Rare 60-160, Epic 520-1,100, Legendary 6.5K-12.5K, Mythic 55K-85K,
    Secret 650K-1.1M   (about x5-x12 per rarity; level +8% per level, mutations x1.5 to x25)
  Feeding was nearly pointless from level 5 on (one level paid back after hours): now a meal costs
  4 x base income x level^1.15, so a level pays itself back in about 2.5 min at level 1, 35 min at level 10,
  3.5 h at level 49. Saves are refreshed on load, so existing dragons get the new numbers.
  The four Robux exclusives (Owner, PRINCE, N2RC1S, M0NICA) keep their own scale: they are the paid,
  strongest dragons, and their pass descriptions quote those numbers. Tell me if they should come down too.

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
