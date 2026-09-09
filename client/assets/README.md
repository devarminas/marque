# client/assets

The world scale contract is the `## World scale` section of [NOTES.md](../../NOTES.md). This file holds the per-asset numbers behind it.

## Authored heights

Heights are the Y extent of the mesh as the vendor shipped it, in Godot units, before any root scale. glTF and GLB heights come from the `POSITION` accessor min and max with node transforms applied. OBJ heights come from the raw `v` lines.

| Asset | Authored height (u) | Notes |
|---|---|---|
| `quaternius/base_characters/Superhero_Male_FullBody.gltf` | 1.820 | bind pose, arms out, width 1.859 |
| `quaternius/animations/UAL2_Standard.glb` | 1.829 | mannequin, same proportions as the base character |
| `quaternius/outfits_fantasy/Male_Peasant_Body.gltf` | 0.637 | torso part, sits at y 0.921 |
| `quaternius/outfits_fantasy/Male_Ranger_Body.gltf` | 0.691 | torso part, sits at y 0.909 |
| `quaternius/nature/CommonTree_1.gltf` | 7.265 | |
| `quaternius/nature/CommonTree_3.gltf` | 9.425 | tallest of the five |
| `quaternius/nature/CommonTree_5.gltf` | 7.006 | |
| `quaternius/nature/Pine_4.gltf` | 10.238 | tallest pine; `Pine_1` is 7.322 |
| `quaternius/nature/Rock_Medium_3.gltf` | 2.318 | 3.42 x 3.48 footprint |
| `quaternius/nature/Bush_Common.gltf` | 1.583 | |
| `quaternius/village/Wall_Plaster_Straight.gltf` | 3.125 | one wall module: 2.000 wide, z -0.314 to 0.092, trim faces -z |
| `quaternius/village/Floor_Brick.gltf` | 0.020 | 2.000 x 2.000 tile |
| `quaternius/village/Roof_RoundTiles_4x6.gltf` | 4.234 | y -0.52 to 3.72 over a 4 x 6 footprint; ridge along z |
| `quaternius/village/Roof_RoundTiles_8x12.gltf` | 6.780 | the largest roof staged |
| `quaternius/village/Roof_Tower_RoundTiles.gltf` | 7.360 | 4 x 4 footprint |
| `quaternius/village/Prop_Chimney.gltf` | 3.180 | |
| `weapons/Sword_1_A.glb` | 1.388 | |
| `weapons/Shield_1_A.glb` | 0.708 | |
| `weapons/Bow_1_1_A_001.glb` | 1.683 | measured along Z, the bow's long axis |
| `weapons/DruidStaff_1_1_A.glb` | 1.354 | |
| `tools/axe.obj` | 6.631 | longest axis, authored; imports at 0.900 |
| `tools/pickaxe.obj` | 14.466 | longest axis, authored; imports at 0.851 |

Every Quaternius pack and the Weapons pack are authored at roughly 1 unit = 1 metre. They import at `nodes/root_scale=1.0` and need no correction. The tool pack OBJ files are the one source authored off contract, 8x to 17x too large, and their sidecars correct that with `scale_mesh`.

The Medieval Village MegaKit is a modular building kit on a 2 u grid: every wall is 2 u wide and 3 u tall, every floor tile is 2 x 2 u, and `Roof_RoundTiles_WxL` covers a W x L footprint with the ridge along the length. The full AABB table for both kits comes from `scripts/measure_gltf_bounds.mjs` run over the source pack's `glTF/` directory; `client/tools/build_world_map.gd` assembles houses from those numbers.

ARM-168 replaced the 2.543 u KayKit Knight, which had made the player render about 2.5 m tall. `client/scenes/player_avatar.tscn` instances `Superhero_Male_FullBody.gltf` at `root_scale` 1.0 and stands 1.733 u in idle, measured by `client/tests/avatar_height_probe.tscn` against a 1.7 u box in the same frame, which that run read back as 1.702 u. The bind pose is 1.820 u and the idle pose stands 8.7 cm shorter, which is why no sidecar correction was needed. `ClickBody/CollisionShape3D` stays a `CapsuleShape3D` with `height = 1.6` and `radius = 0.4` centred at y 0.8. `HpLabel` moved from y 2.4 to y 2.0. ARM-173 deleted `kaykit/` once nothing instanced it; finding 5 records why deletion rather than a tombstone.

Root scale is target height divided by authored height. Worked examples:

- Player base at 1.7 u from `Superhero_Male_FullBody.gltf`. 1.7 / 1.820 = 0.934. ARM-168 measured the animated idle before applying it and left the scale at 1.0; see the paragraph above.
- A 0.90 m axe from `tools/axe.obj`. 0.90 / 6.631 = 0.1357, and `axe.obj.import` carries it as `scale_mesh`.
- A 0.85 m pickaxe from `tools/pickaxe.obj`. 0.85 / 14.466 = 0.0588, likewise in `pickaxe.obj.import`.

ARM-170 picked those two lengths.

## Which unit consumes which directory

| Unit | Directory |
|---|---|
| ARM-168, player body from Universal Base plus UAL2 | `quaternius/base_characters/`, `quaternius/animations/` |
| ARM-169, Peasant and Ranger outfits plus per-class recolours | `quaternius/outfits_fantasy/` |
| ARM-170, hand tools and weapons attach | `tools/`, `weapons/` |
| ARM-171, Nature MegaKit trees on gather nodes | `quaternius/nature/` |
| Open-world map with three towns (`client/scenes/world_map.tscn`) | `quaternius/village/`, `quaternius/nature/` |
| ARM-208, Imp client visual (hostile `imp`) | `quaternius/bestiary/Imp.glb` (+ `License_Standard.txt`); Puglin stays unstaged |

## Staging manifest

Source packs live at `C:\Users\armin\Documents\Projects\game\assets\` and are not in git. Every file here is a byte-for-byte copy of what the pack ships; two are copied under a different filename and say so below.

The snippet below measures three directories, and all three are committed. `quaternius/` holds the five CC0 packs, 167,700,770 bytes across 368 files once the village kit and the extra nature pieces for the world map are counted; before them it was 104,022,006 bytes across 94 files. `tools/` holds two OBJ meshes with their MTL files and sidecars, 6,631,217 bytes across 6 files. `weapons/` holds four GLBs with their sidecars, 2,384,842 bytes across 8 files. `quaternius/bestiary/` stages `Imp.glb`, its `.import` sidecar, and `License_Standard.txt` for ARM-208; `Puglin.glb` stays out.

Every byte figure in this file is a blob size from the git index, and the `.import` sidecars git tracks are included. The whole tree is 176,716,829 bytes, 168.53 MiB, across 382 files.

Do not measure this on disk. The repo sets `core.autocrlf=true` and ships no `.gitattributes`, so git stores the text files (`.obj`, `.mtl`, `.import`) with LF and checks them out with CRLF. `quaternius/` alone is 19,577 bytes larger on disk than in the index, and that gap widens every time the Godot editor rewrites a sidecar. A disk measurement records one machine at one moment. Measure the index:

```powershell
$e = git ls-tree -r -l HEAD client/assets/quaternius client/assets/tools client/assets/weapons
"{0} files {1} bytes" -f $e.Count, ($e | ForEach-Object { [long]($_ -split '\s+')[3] } | Measure-Object -Sum).Sum
```

The CRLF conversion also means a fresh checkout of the OBJ, MTL and sidecar files will not diff clean against the source pack. The blobs match it; the working copies do not.

### `quaternius/base_characters/` (15,496,959 bytes)

From `Universal Base Characters[Standard]\Base Characters\Godot - UE\`. CC0 1.0.

Taken: `Superhero_Male_FullBody.gltf` and `.bin`, the seven textures its URIs name, and `License_Standard.txt` from the pack root. Five textures keep their vendor names (`T_Superhero_Male_Dark.png`, `T_Superhero_Male_Normal.png`, `T_Superhero_Male_Roughness.png`, `T_Hair_1_BaseColor.png`, `T_Eye_Brown.png`). Two are copied under a different name: `T_Hair_1_Normal.png` is staged as `T_Hair_1_Normal_png.png` and `T_Eye_Normal.png` as `T_Eye_Normal_png.png`. See finding 1.

Left in the bundle: the female base (`Superhero_Female_FullBody` with its `T_Hair_2_*` and `T_Superhero_Female_*` textures, 16.0 MB), the unreferenced `T_Hair_*_BaseColor_png.png` duplicates, the light skin-tone variants, the `Hairstyles/` subtree, and the Unity FBX exports.

### `quaternius/animations/` (8,093,630 bytes)

From `Universal Animation Library 2[Standard]\...\Unreal-Godot\`. CC0 1.0.

Taken: `UAL2_Standard.glb`, plus the pack's `README.txt` and `License.txt`. The GLB holds 43 clips.

`locomotion_library.tres` is the one file under `quaternius/` that is not a pack copy. The byte figures in this section were measured before it existed and do not count it. `client/tests/bake_ual2_library.gd` copies `Idle_FoldArms` and `Walk_Carry` out of the imported GLB into that `AnimationLibrary`, and `player_avatar.tscn` loads it as `ual2`. Rerun the bake to add a clip:

```powershell
godot --headless --path client --script res://tests/bake_ual2_library.gd
```

It also prints the walk clip's ground speed, 0.6527 u/s, measured from the planted toe; `player_avatar.gd` carries it rounded to 0.65. Godot's scene importer strips the vendor `_Loop` suffix into `loop_mode`, so the GLB's `Idle_FoldArms_Loop` and `Walk_Carry_Loop` are `Idle_FoldArms` and `Walk_Carry` inside Godot and in the library.

Left out on purpose: the pack's `Godot_Setup.png`. Anything under `client/` is imported as a game resource and shipped in the export, and a setup screenshot is not a game resource. Read it in the source pack.

Left in the bundle: `UAL2_Standard_RM.glb`, the 8.1 MB root-motion variant. The server owns position and the client walks server-supplied polylines, which is an architecture invariant in `AGENTS.md`. Root motion would drive the transform from the animation, so the RM file can never be used here.

### `quaternius/outfits_fantasy/` (70,192,161 bytes)

From `Modular Character Outfits - Fantasy[Standard]\Exports\glTF (Godot-Unreal)\Modular Parts\`. CC0 1.0.

Taken: ten male parts as `.gltf` plus `.bin` (`Male_Peasant_Arms`, `Male_Peasant_Body`, `Male_Peasant_Feet`, `Male_Peasant_Legs`, `Male_Ranger_Acc_Pauldron`, `Male_Ranger_Arms`, `Male_Ranger_Body`, `Male_Ranger_Feet_Boots`, `Male_Ranger_Head_Hood`, `Male_Ranger_Legs`), the six outfit textures (`T_Peasant_BaseColor.png`, `T_Peasant_Normal.png`, `T_Peasant_ORM.png`, `T_Ranger_BaseColor.png`, `T_Ranger_Normal.png`, `T_Ranger_ORM.png`), three skin textures (`T_Regular_Male_Dark_BaseColor.png`, `T_Regular_Male_Normal.png`, `T_Regular_Male_Roughness.png`), and the pack's `Readme.txt` and `License_Standard.txt`. Textures are 67.75 MB of the directory. The meshes are 2.42 MB.

The three skin textures are not optional. `Male_Peasant_Arms.gltf` and `Male_Ranger_Arms.gltf` both name all three as image URIs, for the exposed forearm under the sleeve. Without them the arms import with a null skin albedo. They are laid out for this pack's own body, so substituting `T_Superhero_Male_*` from `base_characters/` is a different image and risks a visible seam at the wrist.

Left in the bundle: the ten female parts (3.11 MB of mesh, but they pull `T_Regular_Female_*`, another 8.54 MB, and are useless without the 16.0 MB female base, so the real female path is about 27.6 MB) and the `Outfits/` folder of combined full-body glTFs. The pack's `Readme.txt` says only the head of the base model is used under clothing and a full body clips. `Modular Parts` is the correct source and `Outfits` is not.

### `quaternius/nature/` (19,223,618 bytes)

From `Stylized Nature MegaKit[Standard]\glTF\`. CC0 1.0.

Taken by ARM-171: `CommonTree_1` through `CommonTree_5` as `.gltf` plus `.bin`, the three textures they reference (`Bark_NormalTree.png`, `Bark_NormalTree_Normal.png`, `Leaves_NormalTree_C.png`), and `License_Standard.txt`. That was 10,239,256 bytes.

Taken by the world map: `Pine_1..5`, `Bush_Common`, `Bush_Common_Flowers`, `Flower_3_Group`, `Flower_3_Single`, `Flower_4_Group`, `Grass_Common_Tall`, `Grass_Wispy_Short`, `Grass_Wispy_Tall`, `Rock_Medium_1..3`, `RockPath_Round_Wide`, `RockPath_Round_Thin`, `RockPath_Square_Wide`, `RockPath_Round_Small_1`, `Pebble_Round_1`, `Pebble_Round_2`, `Pebble_Square_1`, each as `.gltf` plus `.bin`, and the seven textures they reference (`Leaf_Pine_C.png`, `Leaves_TwistedTree_C.png` for the bush, `Flowers.png`, `Leaves.png`, `Grass.png`, `Rocks_Diffuse.png`, `PathRocks_Diffuse.png`). The pines share the common tree's bark pair.

Left in the bundle: `DeadTree_1..5` (about 12.0 MB with its bark pair), `TwistedTree_1..5` (about 14.2 MB, and 16 to 19 u tall, too big for a 1.7 u player to read as a tree), the ferns, clovers, mushrooms, petals, the remaining pebble and path variants, and `Rocks_Desert_Diffuse.png`. The two unstaged tree families are a cheap copy when a depleted or dead-tree look is wanted.

### `quaternius/village/` (54,564,287 bytes)

From `Medieval Village MegaKit[Standard]\glTF\`. CC0 1.0; the pack's `License_Standard.txt` is staged beside the meshes and says so. This is the free Standard cut of the kit, which is why some obvious pieces (a well, a market stall) do not exist to stage.

Taken: 49 pieces as `.gltf` plus `.bin`, every texture they reference (22 PNGs, 2048 x 2048, 52.8 MB of the directory), and the licence. The pieces, by role in `client/tools/build_world_map.gd`:

| Role | Pieces |
|---|---|
| walls | `Wall_Plaster_Straight`, `Wall_Plaster_Door_Flat`, `Wall_Plaster_Window_Wide_Flat`, `Wall_Plaster_Window_Thin_Round`, `Wall_Plaster_WoodGrid`, `Wall_UnevenBrick_Straight`, `Wall_UnevenBrick_Door_Flat`, `Wall_UnevenBrick_Window_Wide_Flat`, `Wall_UnevenBrick_Window_Thin_Round`, `Wall_Arch` |
| corners and floors | `Corner_Exterior_Wood`, `Corner_Exterior_Brick`, `Floor_WoodDark`, `Floor_UnevenBrick`, `Floor_Brick` |
| roofs | `Roof_RoundTiles_4x4`, `4x6`, `4x8`, `6x6`, `6x8`, `6x10`, `8x8`, `8x10`, `8x12`, `Roof_Front_Brick4`, `Brick6`, `Brick8`, `Roof_Tower_RoundTiles`, `Roof_Dormer_RoundTile` |
| doors and windows | `DoorFrame_Flat_WoodDark`, `Door_1_Flat`, `Door_2_Flat`, `Window_Wide_Flat1`, `Window_Thin_Round1`, `WindowShutters_Wide_Flat_Open`, `Overhang_Plaster_Long` |
| props | `Prop_Crate`, `Prop_Wagon`, `Prop_Chimney`, `Prop_WoodenFence_Single`, `Prop_WoodenFence_Extension1`, `Prop_MetalFence_Simple`, `Prop_ExteriorBorder_Straight1`, `Prop_ExteriorBorder_Corner`, `Prop_Brick1`, `Prop_Brick2`, `Prop_Vine1`, `Prop_Vine4`, `Stairs_Exterior_Straight` |

Left in the bundle: the other 133 meshes (balconies, interior stairs, hole covers, the remaining roof sizes and the wooden roof family, plaster overhang corners, the round door and window variants) and the `Textures/` directory at the pack root, which duplicates what `glTF/` carries plus terrain and clothing noise textures nothing here binds.

### `weapons/` (2,384,842 bytes)

From `Weapons\gLTF\`. Free, from https://pszemoo.itch.io/3d-tools. The pack ships no licence file at any depth, so that page is the evidence and the only provenance these files will ever carry. Finding 3 records the search that established it, so the question is closed.

Taken: `Sword_1_A.glb`, `Shield_1_A.glb`, `Bow_1_1_A_001.glb`, `DruidStaff_1_1_A.glb`. One per row of the ARM-170 map. Each GLB is self-contained.

Left in the bundle: the other 28 GLBs. That includes `BattleAxe_1_1_A.glb`, which ARM-170 marks optional and which no `shared/sets.json` kind names, plus arrows, spiked clubs, a horn, and lettered variants of the four taken.

### `tools/` (6,631,217 bytes)

From `tool pack\`. Free, from https://pszemoo.itch.io/3d-tools, the same page that `weapons/` came from. This pack ships no licence file either, so that page is again the only provenance. Finding 3 records the search that established it, so the question is closed.

Taken: `axe.obj` with `axe.mtl`, `pickaxe.obj` with `pickaxe.mtl`.

Left in the bundle: the `.fbx` versions of both, and the two shared 4096x4096 albedos `drewno_Albedo.png` (25.0 MB) and `metal_Albedo.png` (16.9 MB). The OBJ files carry the same meshes as the FBX files, so staging both would import each tool twice. The albedos can never bind. Both `.mtl` files and both `.fbx` files name them by an absolute path on the author's machine (`C:\Users\przem\Pictures\Desktop\tool pack1\siekieraG\...` for the axe, `...\kilofG\...` for the pickaxe), and the imported `axe.obj` mesh in `.godot/imported/` carries no texture path at all. A headless editor pass proves it. Importing `tools/` prints four `ERROR: Failed loading resource: C://Users/przem/Pictures/Desktop/tool pack1/...` lines, one per material, then imports both meshes anyway with Godot's default material. Those four errors are the expected output of building the import cache, not a regression. Excluding the albedos costs nothing. ARM-170 rebinds materials by hand during conversion. A 4096x4096 albedo on a hand-held tool is the wrong resolution, so downscale before staging.

### Not staged at all

`Medieval Village MegaKit[Standard]` is 169 MB in the source bundle and 54.6 MB of it is staged at `quaternius/village/` for the world map; see that section. `kenney_cursor-pack` is already partly staged at `kenney_cursors/`.

`quaternius/bestiary/` now stages hostile Imp for ARM-208: `Imp.glb`, `Imp.glb.import`, and `License_Standard.txt` from `Bestiary - Dungeon Monsters Kit[Standard]`, under the Quaternius Asset License v1.0 (finding 4). `Puglin.glb` remains unstaged. Both GLBs embed their textures, so the loose `T_Imp_*` and `T_Puglin_*` PNGs stay in the bundle. Authored heights: `Imp.glb` 1.678 u (inside the ~1.7u player band at `root_scale` 1.0), `Puglin.glb` 0.931 u. Neither carries animation clips; see finding 8.

## Import settings by format

Godot 4.7.2, Forward+. Git tracks the `.import` sidecars. `client/.godot/` is gitignored, so a fresh worktree has no import cache and the editor must run once to build it.

### `.gltf` plus `.bin` plus loose `.png`

Base characters, outfits, nature trees. Scene importer. `nodes/apply_root_scale=true` and `nodes/root_scale=1.0` unless the height table says otherwise. `gltf/embedded_image_handling=1` (Extract Textures) is the default and is correct, because the textures are already loose files beside the glTF. The URIs are bare relative filenames, so a texture must sit in the same directory as its `.gltf`.

### `.glb`

`UAL2_Standard.glb` and the four weapons. Scene importer. All five GLBs in the repository have `gltf/embedded_image_handling=3` (Embed as Uncompressed) instead of the default `1` (Extract Textures). With Extract, Godot writes every embedded texture out as a loose PNG beside the `.glb` inside `res://`. Measured with five weapon GLBs staged, that added 18.6 MB of derived binaries to the working tree. Five of those files were byte-identical copies of the same 554 KB weapons atlas, one per weapon GLB. Embed keeps them inside the imported scene under `.godot/`, which is gitignored.

The tradeoff is that an embedded texture cannot be tuned per-texture in the import dock. If a normal map in one of these GLBs ever needs the normal-map compression flag, that GLB switches back to Extract and its extracted PNG gets committed.

### `.obj` plus `.mtl`

Tool pack. Godot imports OBJ natively as a `Mesh` with no rig and no scene hierarchy, so there is no `root_scale` knob. `scale_mesh` in the sidecar is the equivalent: it scales the vertices at import, and both tools carry their contract factor there rather than on an instance node. The remaining problem is materials. The vendor `.mtl` points at absolute paths on the author's machine, so materials do not bind and the mesh imports with a default material. Converting the pack to glTF is what fixes that, and it no longer has scale riding on it.

### `.fbx`

Not staged, though Godot 4.3 and later ship a built-in ufbx importer that would handle it. The tool pack ships each mesh as both `.obj` and `.fbx`, and the OBJ already imports. Whoever converts the tool pack to glTF for ARM-170 works from the source pack.

### `.png` as a texture

Standard texture importer defaults. Every staged sidecar has `compress/mode=0` (Lossless), `compress/normal_map=0` (Detect), and `detect_3d/compress_to=1`. Detect reads the pixel content, not the `_Normal` filename suffix. The first time the editor sees one of these textures in a 3D material it rewrites the sidecar to VRAM compression, which shows up as a modified tracked file. Commit that rewrite. For a normal map that Detect misses, set `compress/normal_map=1` by hand.

## Findings

1. `Superhero_Male_FullBody.gltf` references two texture URIs that do not exist anywhere in the source pack, `T_Hair_1_Normal_png.png` and `T_Eye_Normal_png.png`. The pack ships `T_Hair_1_Normal.png` and `T_Eye_Normal.png`. Vendor typo. The vendor glTF is unmodified. The two textures are staged under the names the glTF asks for, so the glTF binds them as is. Anyone re-copying from the pack must rename them again.
2. **This repository is public.** `gh api repos/devarminas/marque` returns `"visibility": "public"`. Every licence question below is decided against a public tree, not a private one. Do not invent a private-repo assumption in licensing analysis.
3. Neither the `Weapons` pack nor the `tool pack` ships a licence file at any depth. A recursive search of both source directories for any file matching `licen*`, `readme*`, `*.txt`, `*.pdf` or `*.md` returned nothing. Every other pack staged here ships one. The owner identified the source of both packs as https://pszemoo.itch.io/3d-tools and confirms they are free, so `weapons/` and `tools/` are in the tree on that basis, with the source page as their only provenance. There is no file to copy in beside the meshes. ARM-178 has nothing left to settle for these two packs.
4. The Bestiary pack is under the Quaternius Asset License v1.0, not CC0. Section 2 grants commercial use with no credit required and explicitly covers contractors and collaborators. Section 3(a) forbids redistributing the assets themselves as an asset pack, in original or modified form, whether alone or bundled, and adds that this applies regardless of how much they were modified. A game's source tree is not an asset pack, and section 2 permits distributing a Product that incorporates the assets, so the reading that allows this is available. That question is not what kept the pack out in the end. `Imp.glb` is staged under ARM-208 for hostile `imp` NPCs; `Puglin.glb` remains out. This paragraph is the licence record for the pack. Section 7 binds whichever licence version was in force when the pack was obtained, and the shipped text is dated 8/28/2026. The other Quaternius packs staged here (Universal Base Characters, UAL2, Modular Fantasy, Stylized Nature, Medieval Village) are CC0 1.0 and carry no such clause.
5. `client/assets/kaykit/` is gone. ARM-173 deleted the whole directory rather than leaving a tombstone README. The pack was KayKit Adventurers Character Pack 2.0 by Kay Lousberg, recorded as CC0 in the directory's own README on the strength of a `License.txt` that lived in the itch.io bundle and was never copied into the repo; that bundle path no longer exists on this machine, so the licence text could not be backfilled. This repository is public (finding 2), and unlicensed art in a public tree is the exposure the ARM-167 audit was run to find. A tombstone leaves that exposure standing for every file it describes, so the files went. The directory held `Knight.glb` and its texture, `Rig_Medium_General.glb`, `Rig_Medium_MovementBasic.glb`, `movement_library.tres`, and `props/axe_1handed.{gltf,bin}` with `barbarian_texture.png`, 2.3 MB in fourteen files. Their replacements are `quaternius/base_characters/` for the body, `quaternius/animations/` for the clips, and `tools/axe.obj` for the axe, in hand and on the ground. Git history still holds every deleted byte; anyone restoring one must resolve the licence question first.
6. The repo has no `.gitattributes` and no git LFS. This unit adds 107.80 MiB of binaries and later M8 work adds more. ARM-179 owns the evaluation. Nothing here enables it.
7. UAL2 Standard ships no neutral idle, walk, or run. All 43 clips are situational (`Idle_FoldArms_Loop`, `Walk_Carry_Loop`, `Zombie_Walk_Fwd_Loop`), and `UAL2_Standard_RM.glb` holds the identical 43, so the root-motion file is no help either. ARM-168's "idle plus locomotion from UAL2" cannot be met from the free pack. It does ship `TreeChopping_Loop`, `Farm_Harvest`, `Farm_PlantSeed` and `Farm_Watering`, which are this game's verbs. Raised on ARM-168 and settled there by substitution, `Idle_FoldArms_Loop` for idle and `Walk_Carry_Loop` for every locomotion speed; the record is in `NOTES.md`, *Player body and UAL2 locomotion*.
8. `Imp.glb` and `Puglin.glb` carry no animation clips. Both are rigged but neither has an `animations` array, so ARM-208 Imp (and any future Puglin) ships as a static posed mesh. Raised on ARM-172; Imp half superseded by ARM-208.
9. `Superhero_Male_FullBody.gltf`, `UAL2_Standard.glb` and every staged outfit part share an identical 65-bone skeleton with zero name differences. Godot's name-based retarget works across all three with no bone map.
