RIDE A DRAGON - project snapshot (4 Oct 2026, TEST 2)
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
                            luau_lint.py    - Luau linter
                            tests/          - simulation tests (shop, spin, eggs, inventory...)
                            worldgen/       - terrain / layout generator for Dragon Haven

OPEN / TEST IN STUDIO
  1. Open RideADragon_Dev.rbxlx in Roblox Studio and press Play.
  2. UI Lab (Studio only, ` key) > TEST row: +$1M, ALL 30 DRAGONS, FILL EGGS, HATCH NOW.
  3. Robux items with Id = 0 are free TEST purchases inside Studio.

REBUILD THE PLACE FROM SOURCE
  cd toolchain
  python3 build_place.py ../RideADragon/default.project.json ../RideADragon_Dev.rbxlx
  (or sync RideADragon/default.project.json with Rojo)

ROBUX ITEMS (before publishing)
  Create the game pass / developer products on create.roblox.com with the same
  prices and paste their IDs into
  ReplicatedStorage > Configs > MonetizationConfig (field Id):
    Game passes: Owner Dragon 3000, PRINCE 8999, N2RC1S 8999
    Products: Luck Potion 49, Super Luck Potion 149, Cash Potion 49, Level Potion 39,
              Mutation Potion 99, 5 Spins 49, 25 Spins 199, Cash packs 25 / 99 / 249

DONE IN THIS SNAPSHOT (TEST 2 additions first)
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
    longer charge and more cracks. SKIP button for impatient hatchers. The camera finds a clear
    spot in the plot (walls / gate / shrine) and frames every dragon size and screen shape.
  - 6 NEW MUTATIONS (18 in total): Neon, Infernal, Corrupted, Crystal, Lightning, Angelic.
    Each one really changes the dragon: palette, glowing / glass materials, particles, a light in
    its colour, ribbons behind the wings, a halo (Angelic), crystal clusters (Crystal). The fire
    breath takes the mutation's colours (frost, venom, hellfire, lightning, holy light, rainbow...).
  - SERVER-WIDE ANNOUNCEMENTS: a hatch of "1 in 25,000" or rarer shows a banner to every player
    (after the hatcher's reveal, so nobody is spoiled); "1 in 1,000,000"+ gets a MEGA banner.
  - LUCKY WILD EGGS: every 10-20 minutes one special egg (Lucky / Epic / Mythic / Rainbow, x25 ...
    x2000 luck) appears somewhere in the world for the whole server: "A MYTHIC EGG HAS SPAWNED!
    02:00", a pillar of light, a countdown, an arrow and the distance. First to reach it wins; the
    egg goes straight into their hand. Nobody in time: it vanishes.
  - Studio test buttons (UI Lab, ` key): WILD EGG, BOND MAX, MEGA BANNER next to +$1M, ALL 30
    DRAGONS, FILL EGGS, HATCH NOW.
  - Menu blur is now optional (Settings) and the Spin Wheel prize shows on a clean card.
  - Earlier snapshot:
  - 30 LEGO dragons (6 body types) + 10 mutations with effects, "1 in N" rarity titles,
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
  - New eggs / dragons / Robux items (Egg Radar, Egg Magnet, Lucky Egg Call, Hatch Boost, bundles)
  - Bigger map with Frostpeak / Ember Caldera / Skyreach regions (their eggs currently
    spawn at the valley's landmark spots: plateau, cave, ruins, pillar, island)
  - Nicer perches/nest, extra animations, coins on the map
  - Dragon races and the fastest / strongest / highest-level leaderboards
