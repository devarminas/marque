# 0012. Character art contract

## Status

Accepted (Prototype art / ARM-271).

## Context

Prototype character art replaces the Quaternius and Bestiary stand-ins and must itself be replaceable by real skinned art later. Players and NPCs share animations: an imp swing plays the player swing clip. The Quaternius UAL2 clips key bone rotations plus only `pelvis` location, so a clip transfers between bodies that share bone names and rest orientations.

## Decision

1. **One contract file.** `client/assets/proto/art_contract.json` holds the bones, variants, regions, slot ownership, clips, and routes. `art/contract.py` parses it for the generator. `client/scripts/art_contract.gd` parses it for the client and collects every violation in `errors`. No code reads the raw JSON past these two parsers.
2. **Bones.** The rig has 23 UE-named bones: `root`, `pelvis`, `spine_01` to `spine_03`, `neck_01`, `Head`, and `clavicle`, `upperarm`, `lowerarm`, `hand`, `thigh`, `calf`, `foot`, and `ball` on each side. The armature node is `Rig`, so Godot imports the skeleton at `Rig/Skeleton3D`.
3. **Rest source.** `art/extract_rest.py` copies each bone's rest head, tail, and roll from `rest_source` (`UAL2_Standard.glb`) into the contract. The rerun is idempotent. Clips authored on the contract rig drive Quaternius-rigged bodies with no retarget.
4. **Variants.** A variant scales every rest position by `scale`, so bone lengths change and rest orientations stay identical. `human` has scale 1.0 and a pelvis at 0.917 m. `imp` has scale 0.676, a pelvis at 0.62 m, and a height of about 1.2 m. `clip_rig` names the variant that clips are authored on. A skeleton of another variant sets `Skeleton3D.motion_scale` to `ArtContract.motion_scale(variant)`, so the `pelvis` position track lands at that variant's own height.
5. **Regions.** Nine regions partition every bone except `root`. Each region is one skinned `MeshInstance3D` named `region_<region>` under `Rig/Skeleton3D`. Every prototype vertex weighs 100% to one bone of its region, so a later armor piece that covers a region shares that bone's frame and cannot clip through it.
6. **Slot ownership.** `slot_regions` maps each armor slot to the regions it owns. No region belongs to two slots, and `hands` belongs to none. A worn piece hides only regions that its own slot owns.
7. **Clips.** `anim/clips.glb` is one clip library authored on the `clip_rig`. Each clip keys bone rotations plus one `pelvis` position track. The exporter runs with `export_optimize_animation_keep_anim_armature=False`, so it writes no constant per-bone position tracks and a smaller variant keeps its own bone lengths. The `.import` sidecar imports `clips.glb` as an `AnimationLibrary` and sets each loop mode in `_subresources`. Clip names carry no `_Loop` suffix. The rig glbs import with `animation/import=false`.
8. **Routes.** Each `routes` row maps an `action` and a `key` to a clip. Every action has a row with `key: ""`. `ArtContract.clip_for` returns the exact row, else the `key: ""` row, so an actor with no special key plays the default clip.
9. **Generator.** `art/build.py` regenerates `characters/humanoid.glb`, `characters/imp.glb`, and `anim/clips.glb` in headless Blender with pinned export settings and sorted iteration. `art/check_determinism.py` runs the build twice and fails unless every glb has the same SHA-256.

## Regenerate the prototype art

1. To change a rest orientation, update `rest_source`, then run `blender --background --factory-startup --python-exit-code 1 --python art/extract_rest.py`.
2. Edit the region shapes in `art/body.py`, the keyframes in `art/clips.py`, or the contract.
3. Run `blender --background --factory-startup --python-exit-code 1 --python art/check_determinism.py`. It rebuilds every glb twice.
4. Run `godot --headless --path client --import`, then run the headless suite.

## Swap in real skinned art

1. Rig the art on the 23 contract bones with the contract rest orientations. The armature in `characters/humanoid.glb` is a valid starting rig.
2. Split the body into the nine `region_<region>` meshes. Weight each mesh only to its own region's bones.
3. Export to the variant's `glb` path with the armature named `Rig`. Keep `animation/import=false` in its sidecar.
4. Relax the single-bone weight check in `client/tests/test_art_assets.gd` to region membership, because real art blends weights between bones.
5. Run the headless suite. `test_art_assets.tscn` checks the bone set, the rest orientations against the clip rig and `rest_source`, and the region meshes.
6. To add a clip, add rows to `clips` and `routes`, author the clip, and add its `settings/loop_mode` to the `clips.glb.import` sidecar.

## Consequences

- `client/tests/test_art_contract.gd` checks the contract invariants and names each violation. `client/tests/test_art_assets.tscn` checks the imported glbs against the contract, including the imp pelvis height under `motion_scale`.
- A change to rest orientations invalidates every authored clip.

## Non-goals

- Armor pieces, hand items, props, and clips other than `idle`, `walk`, and `swing`.
- Wiring the art into `player_avatar.tscn`, NPC scenes, or `session.gd`.
- Deleting the Quaternius assets.
