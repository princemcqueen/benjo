RIDE A DRAGON - project snapshot (4 Oct 2026)
==============================================

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

DONE IN THIS SNAPSHOT
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

NOT FINISHED (work stopped here)
  - Skill tree / upgrade tree (only its config TreeConfig.luau exists; no UI or service yet)
  - Bigger map with Frostpeak / Ember Caldera / Skyreach regions (their eggs currently
    spawn at the valley's landmark spots: plateau, cave, ruins, pillar, island)
  - New hatch reveal (dragon walking to the camera), nicer perches/nest, extra animations
  - Dragon races and the fastest / strongest / highest-level leaderboards
