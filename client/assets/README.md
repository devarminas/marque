# client/assets

The world scale contract is the `## World scale` section of [NOTES.md](../../NOTES.md). This file holds the per-asset numbers behind it. `kaykit/` has its own [README](kaykit/README.md).

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
| `weapons/Sword_1_A.glb` | 1.388 | |
| `weapons/Shield_1_A.glb` | 0.708 | |
| `weapons/Bow_1_1_A_001.glb` | 1.683 | measured along Z, the bow's long axis |
| `weapons/DruidStaff_1_1_A.glb` | 1.354 | |
| `tools/axe.obj` | 6.631 | longest axis, off contract |
| `tools/pickaxe.obj` | 14.466 | longest axis, off contract |
| `kaykit/Knight.glb` | 2.543 | off contract |

Every Quaternius pack and the Weapons pack are authored at roughly 1 unit = 1 metre. They import at `nodes/root_scale=1.0` and need no correction. Two sources are off contract. The tool pack OBJ files are 8x to 17x too large. The KayKit Knight is 2.543 u, so the player renders about 2.5 m tall today.

The Knight gap is live. `client/scenes/player_avatar.tscn` instances `Knight.glb` with no scale override, while the same scene's `ClickBody/CollisionShape3D` is a `CapsuleShape3D` with `height = 1.6` and `radius = 0.4` centred at y 0.8, and `HpLabel` sits at y 2.4. The collision already encodes the 1.6 to 1.8 band. The visual does not. ARM-168 closes the gap when it swaps the avatar.

Root scale is target height divided by authored height. Worked examples:

- Player base at 1.7 u from `Superhero_Male_FullBody.gltf`. 1.7 / 1.820 = 0.934.
- A 0.75 m axe from `tools/axe.obj`. 0.75 / 6.631 = 0.113.
- A 0.85 m pickaxe from `tools/pickaxe.obj`. 0.85 / 14.466 = 0.059.

The tool lengths are examples of the arithmetic, not decisions. ARM-170 picks the hand-tool lengths.

## Which unit consumes which directory

| Unit | Directory |
|---|---|
| ARM-168, player body from Universal Base plus UAL2 | `quaternius/base_characters/`, `quaternius/animations/` |
| ARM-169, Peasant and Ranger outfits plus per-class recolours | `quaternius/outfits_fantasy/` |
| ARM-170, hand tools and weapons attach | `tools/`, `weapons/` |
| ARM-171, Nature MegaKit trees on gather nodes | `quaternius/nature/` |
| ARM-172, Imp and Puglin replace dummy NPC visuals | `quaternius/bestiary/`, not in the repository; the unit is blocked on scope |

## Staging manifest

Source packs live at `C:\Users\armin\Documents\Projects\game\assets\` and are not in git. Every file here is a byte-for-byte copy of what the pack ships; two are copied under a different filename and say so below.

The snippet below measures three directories, and all three are committed. `quaternius/` holds the four CC0 packs, 104,022,006 bytes across 94 files. `tools/` holds two OBJ meshes with their MTL files and sidecars, 6,631,217 bytes across 6 files. `weapons/` holds four GLBs with their sidecars, 2,384,842 bytes across 8 files. `quaternius/bestiary/` is not in the tree and is not counted; see Not staged at all.

Every byte figure in this file is a blob size from the git index, and the `.import` sidecars git tracks are included. The whole tree is 113,038,065 bytes, 107.80 MiB, across 108 files.

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

Left out on purpose: the pack's `Godot_Setup.png`. Anything under `client/` is imported as a game resource and shipped in the export, and a setup screenshot is not a game resource. Read it in the source pack.

Left in the bundle: `UAL2_Standard_RM.glb`, the 8.1 MB root-motion variant. The server owns position and the client walks server-supplied polylines, which is an architecture invariant in `CLAUDE.md`. Root motion would drive the transform from the animation, so the RM file can never be used here.

### `quaternius/outfits_fantasy/` (70,192,161 bytes)

From `Modular Character Outfits - Fantasy[Standard]\Exports\glTF (Godot-Unreal)\Modular Parts\`. CC0 1.0.

Taken: ten male parts as `.gltf` plus `.bin` (`Male_Peasant_Arms`, `Male_Peasant_Body`, `Male_Peasant_Feet`, `Male_Peasant_Legs`, `Male_Ranger_Acc_Pauldron`, `Male_Ranger_Arms`, `Male_Ranger_Body`, `Male_Ranger_Feet_Boots`, `Male_Ranger_Head_Hood`, `Male_Ranger_Legs`), the six outfit textures (`T_Peasant_BaseColor.png`, `T_Peasant_Normal.png`, `T_Peasant_ORM.png`, `T_Ranger_BaseColor.png`, `T_Ranger_Normal.png`, `T_Ranger_ORM.png`), three skin textures (`T_Regular_Male_Dark_BaseColor.png`, `T_Regular_Male_Normal.png`, `T_Regular_Male_Roughness.png`), and the pack's `Readme.txt` and `License_Standard.txt`. Textures are 67.75 MB of the directory. The meshes are 2.42 MB.

The three skin textures are not optional. `Male_Peasant_Arms.gltf` and `Male_Ranger_Arms.gltf` both name all three as image URIs, for the exposed forearm under the sleeve. Without them the arms import with a null skin albedo. They are laid out for this pack's own body, so substituting `T_Superhero_Male_*` from `base_characters/` is a different image and risks a visible seam at the wrist.

Left in the bundle: the ten female parts (3.11 MB of mesh, but they pull `T_Regular_Female_*`, another 8.54 MB, and are useless without the 16.0 MB female base, so the real female path is about 27.6 MB) and the `Outfits/` folder of combined full-body glTFs. The pack's `Readme.txt` says only the head of the base model is used under clothing and a full body clips. `Modular Parts` is the correct source and `Outfits` is not.

### `quaternius/nature/` (10,239,256 bytes)

From `Stylized Nature MegaKit[Standard]\glTF\`. CC0 1.0.

Taken: `CommonTree_1` through `CommonTree_5` as `.gltf` plus `.bin`, the three textures they reference (`Bark_NormalTree.png`, `Bark_NormalTree_Normal.png`, `Leaves_NormalTree_C.png`), and `License_Standard.txt`.

Left in the bundle: `DeadTree_1..5` (about 12.0 MB with its bark pair), `TwistedTree_1..5` (about 14.2 MB), and the rest of the 68-mesh pack. ARM-171 needs one live gather tree. The other two tree families are a cheap copy when a depleted or dead-tree look is wanted.

### `weapons/` (2,384,842 bytes)

From `Weapons\gLTF\`. Free, from https://pszemoo.itch.io/3d-tools. The pack ships no licence file at any depth, so that page is the evidence and the only provenance these files will ever carry. Finding 3 records the search that established it, so the question is closed.

Taken: `Sword_1_A.glb`, `Shield_1_A.glb`, `Bow_1_1_A_001.glb`, `DruidStaff_1_1_A.glb`. One per row of the ARM-170 map. Each GLB is self-contained.

Left in the bundle: the other 28 GLBs. That includes `BattleAxe_1_1_A.glb`, which ARM-170 marks optional and which no `shared/sets.json` kind names, plus arrows, spiked clubs, a horn, and lettered variants of the four taken.

### `tools/` (6,631,217 bytes)

From `tool pack\`. Free, from https://pszemoo.itch.io/3d-tools, the same page that `weapons/` came from. This pack ships no licence file either, so that page is again the only provenance. Finding 3 records the search that established it, so the question is closed.

Taken: `axe.obj` with `axe.mtl`, `pickaxe.obj` with `pickaxe.mtl`.

Left in the bundle: the `.fbx` versions of both, and the two shared 4096x4096 albedos `drewno_Albedo.png` (25.0 MB) and `metal_Albedo.png` (16.9 MB). The OBJ files carry the same meshes as the FBX files, so staging both would import each tool twice. The albedos can never bind. Both `.mtl` files and both `.fbx` files name them by an absolute path on the author's machine (`C:\Users\przem\Pictures\Desktop\tool pack1\siekieraG\...` for the axe, `...\kilofG\...` for the pickaxe), and the imported `axe.obj` mesh in `.godot/imported/` carries no texture path at all. A headless editor pass proves it. Importing `tools/` prints four `ERROR: Failed loading resource: C://Users/przem/Pictures/Desktop/tool pack1/...` lines, one per material, then imports both meshes anyway with Godot's default material. Those four errors are the expected output of building the import cache, not a regression. Excluding the albedos costs nothing. ARM-170 rebinds materials by hand during conversion. A 4096x4096 albedo on a hand-held tool is the wrong resolution, so downscale before staging.

### Not staged at all

`Medieval Village MegaKit[Standard]` (169 MB). No M8 unit needs it. `kenney_cursor-pack` is already partly staged at `kenney_cursors/`.

`quaternius/bestiary/`. No enemies exist in the game yet, so nothing uses `Imp.glb` or `Puglin.glb`, and ARM-172 is blocked on scope. From `Bestiary - Dungeon Monsters Kit[Standard]`, under the Quaternius Asset License v1.0, not CC0; finding 4 records the terms and why they were not what kept it out. The copy would be `Imp.glb`, `Puglin.glb` and `License_Standard.txt`, 17,271,661 bytes. Both GLBs embed their textures, so the 20 MB of loose `T_Imp_*` and `T_Puglin_*` PNGs stayed in the bundle. The Standard pack ships only these two monsters. Authored heights, measured the same way as the table above: `Imp.glb` 1.678 u, `Puglin.glb` 0.931 u. Neither carries animation clips; see finding 8.

## Import settings by format

Godot 4.7.2, Forward+. Git tracks the `.import` sidecars. `client/.godot/` is gitignored, so a fresh worktree has no import cache and the editor must run once to build it.

### `.gltf` plus `.bin` plus loose `.png`

Base characters, outfits, nature trees. Scene importer. `nodes/apply_root_scale=true` and `nodes/root_scale=1.0` unless the height table says otherwise. `gltf/embedded_image_handling=1` (Extract Textures) is the default and is correct, because the textures are already loose files beside the glTF. The URIs are bare relative filenames, so a texture must sit in the same directory as its `.gltf`.

### `.glb`

`UAL2_Standard.glb` and the four weapons. Scene importer. All five GLBs in the repository have `gltf/embedded_image_handling=3` (Embed as Uncompressed) instead of the default `1` (Extract Textures). With Extract, Godot writes every embedded texture out as a loose PNG beside the `.glb` inside `res://`. Measured with five weapon GLBs staged, that added 18.6 MB of derived binaries to the working tree. Five of those files were byte-identical copies of the same 554 KB weapons atlas, one per weapon GLB. Embed keeps them inside the imported scene under `.godot/`, which is gitignored.

The tradeoff is that an embedded texture cannot be tuned per-texture in the import dock. If a normal map in one of these GLBs ever needs the normal-map compression flag, that GLB switches back to Extract and its extracted PNG gets committed.

### `.obj` plus `.mtl`

Tool pack. Godot imports OBJ natively as a `Mesh` with no rig and no scene hierarchy, so there is no `root_scale` knob, only `scale_mesh=Vector3(1, 1, 1)` in the sidecar. Two problems. The vendor `.mtl` points at absolute paths on the author's machine, so materials do not bind and the mesh imports with a default material. And the meshes are 8x to 17x off contract. ARM-170 owns the conversion to glTF and sets a root scale then.

### `.fbx`

Not staged, though Godot 4.3 and later ship a built-in ufbx importer that would handle it. The tool pack ships each mesh as both `.obj` and `.fbx`, and the OBJ already imports. Whoever converts the tool pack to glTF for ARM-170 works from the source pack.

### `.png` as a texture

Standard texture importer defaults. Every staged sidecar has `compress/mode=0` (Lossless), `compress/normal_map=0` (Detect), and `detect_3d/compress_to=1`. Detect reads the pixel content, not the `_Normal` filename suffix. The first time the editor sees one of these textures in a 3D material it rewrites the sidecar to VRAM compression, which shows up as a modified tracked file. Commit that rewrite. For a normal map that Detect misses, set `compress/normal_map=1` by hand.

## Findings

1. `Superhero_Male_FullBody.gltf` references two texture URIs that do not exist anywhere in the source pack, `T_Hair_1_Normal_png.png` and `T_Eye_Normal_png.png`. The pack ships `T_Hair_1_Normal.png` and `T_Eye_Normal.png`. Vendor typo. The vendor glTF is unmodified. The two textures are staged under the names the glTF asks for, so the glTF binds them as is. Anyone re-copying from the pack must rename them again.
2. **This repository is public.** `gh api repos/devarminas/marque` returns `"visibility": "public"`. Every licence question below is decided against a public tree, not a private one. `STANDING-ORDERS.md` no longer states a visibility at all. It used to say private, and that stale claim had already propagated into this unit's licensing analysis before the API check caught it. A visibility claim that goes stale is worse than none, so the claim was removed rather than corrected.
3. Neither the `Weapons` pack nor the `tool pack` ships a licence file at any depth. A recursive search of both source directories for any file matching `licen*`, `readme*`, `*.txt`, `*.pdf` or `*.md` returned nothing. Every other pack staged here ships one. The owner identified the source of both packs as https://pszemoo.itch.io/3d-tools and confirms they are free, so `weapons/` and `tools/` are in the tree on that basis, with the source page as their only provenance. There is no file to copy in beside the meshes. ARM-178 has nothing left to settle for these two packs.
4. The Bestiary pack is under the Quaternius Asset License v1.0, not CC0. Section 2 grants commercial use with no credit required and explicitly covers contractors and collaborators. Section 3(a) forbids redistributing the assets themselves as an asset pack, in original or modified form, whether alone or bundled, and adds that this applies regardless of how much they were modified. A game's source tree is not an asset pack, and section 2 permits distributing a Product that incorporates the assets, so the reading that allows this is available. That question is not what kept the pack out in the end. `quaternius/bestiary/` is out of the tree because no enemies exist in the game yet and nothing uses these meshes; ARM-172 is blocked on scope. When scope changes, this paragraph is the record to decide the licence against. Section 7 binds whichever licence version was in force when the pack was obtained, and the shipped text is dated 8/28/2026. The other Quaternius packs staged here (Universal Base Characters, UAL2, Modular Fantasy, Stylized Nature) are CC0 1.0 and carry no such clause.
5. `kaykit/README.md` cites a source bundle path that no longer exists on this machine, and KayKit's own license file was never copied into the repo. The README records the pack as CC0 by Kay Lousberg. The license file cannot be backfilled from local disk.
6. The repo has no `.gitattributes` and no git LFS. This unit adds 107.80 MiB of binaries and later M8 work adds more. ARM-179 owns the evaluation. Nothing here enables it.
7. UAL2 Standard ships no neutral idle, walk, or run. All 43 clips are situational (`Idle_FoldArms_Loop`, `Walk_Carry_Loop`, `Zombie_Walk_Fwd_Loop`), and `UAL2_Standard_RM.glb` holds the identical 43, so the root-motion file is no help either. ARM-168's "idle plus locomotion from UAL2" cannot be met from the free pack. It does ship `TreeChopping_Loop`, `Farm_Harvest`, `Farm_PlantSeed` and `Farm_Watering`, which are this game's verbs. Raised on ARM-168.
8. `Imp.glb` and `Puglin.glb` carry no animation clips. Both are rigged but neither has an `animations` array, so ARM-172 gets static posed meshes. Raised on ARM-172.
9. `Superhero_Male_FullBody.gltf`, `UAL2_Standard.glb` and every staged outfit part share an identical 65-bone skeleton with zero name differences. Godot's name-based retarget works across all three with no bone map.
