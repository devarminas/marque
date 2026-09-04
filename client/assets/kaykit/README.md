# KayKit — Adventurers Character Pack 2.0

Source: itch.io bundle downloaded to `..\..\..\..\..\assets\KayKit_Adventurers_2.0_FREE`
(outside the repo). License: **CC0** (Kay Lousberg, kaylousberg.com); see
`License.txt` in the bundle. Nothing here is modified content, only copies.

| File | What it is |
|---|---|
| `Knight.glb` | Rigged Knight character (skin + skeleton, no animations) |
| `Rig_Medium_MovementBasic.glb` | Rig_Medium animations only: idle, walk, run, jump |
| `Rig_Medium_General.glb` | Rig_Medium animations only: idles, hit reactions, interactions, spawn, death |
| `movement_library.tres` | Both GLBs baked into one library; see below |
| `props/axe_1handed.{gltf,bin}` + `barbarian_texture.png` | 1-handed axe prop (glTF split files, texture shared by name with the character texture naming) |

Animations live in a separate GLB because the pack's characters share one
`Rig_Medium` skeleton. Retargeting inside Godot is automatic for same-named
bones (Skeleton3D name-cast); the probe recorded the actual list in the avatar
suite's structure block.

The pack also ships five other characters (Barbarian, Mage, Ranger, Rogue,
Rogue_Hooded), left in the bundle.
