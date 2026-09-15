# 0012. Character art contract

## Status

Accepted (Prototype art / ARM-271).

## Context

Prototype character art replaces the Quaternius and Bestiary stand-ins and must itself be replaceable by real skinned art later. Players and NPCs share animations: an imp swing plays the player swing clip. The Quaternius UAL2 clips key bone rotations plus only `pelvis` location, so a clip transfers between bodies that share bone names and rest orientations.

Armor must never clip through the body in any pose. Shrinking the body under gear was measured to squash limbs and still leak at joints, so gear replaces the body regions it covers instead.

The body is a base-mesh mannequin: capsule limbs, a lofted torso, pelvis, and feet, and thin joint bands in the seams. Rigid single-bone parts leave a notch at a bent seam unless both sides stay on a sphere around the pivot. Where faceted parts on neighbouring bones overlap along a surface, they cross at a shallow angle and render a jagged sawtooth line. A continuous surface that blends weights across its bones bends instead of cutting.

## Decision

1. **One contract file.** `client/assets/proto/art_contract.json` holds the bones, variants, regions, slot ownership, armor pieces, hand items, clips, and routes. `art/contract.py` parses it for the generator. `client/scripts/art_contract.gd` parses it for the client and collects every violation in `errors`. No code reads the raw JSON past these two parsers.
2. **Bones.** The rig has 23 UE-named bones: `root`, `pelvis`, `spine_01` to `spine_03`, `neck_01`, `Head`, and `clavicle`, `upperarm`, `lowerarm`, `hand`, `thigh`, `calf`, `foot`, and `ball` on each side. The armature node is `Rig`, so Godot imports the skeleton at `Rig/Skeleton3D`.
3. **Rest source.** `art/extract_rest.py` copies each bone's rest head, tail, and roll from `rest_source` (`UAL2_Standard.glb`) into the contract. The rerun is idempotent. Clips authored on the contract rig drive Quaternius-rigged bodies with no retarget.
4. **Variants.** A variant scales every rest position by `scale`, so bone lengths change and rest orientations stay identical. `human` has scale 1.0 and a pelvis at 0.917 m. `imp` has scale 0.676, a pelvis at 0.62 m, and a height of about 1.2 m. `clip_rig` names the variant that clips are authored on. A skeleton of another variant sets `Skeleton3D.motion_scale` to `ArtContract.motion_scale(variant)`, so the `pelvis` position track lands at that variant's own height.
5. **Regions.** Nine regions partition every bone except `root`. Each region is one skinned `MeshInstance3D` named `region_<region>` under `Rig/Skeleton3D`. A vertex weighs only bones of its region, and its weights sum to 1. The torso blends `spine_01` to `spine_03`. Every other prototype body vertex weighs 100% to one bone.
6. **Body shapes.** `art/body.py` builds each region from typed records in `HUMAN_SHAPES` and `IMP_SHAPES`:
    - A `Capsule` is a limb or the neck. Its cap centres sit on the joints at both ends, so the limb holds a ball around each pivot.
    - A `Band` is a short flat ring between two anchors on the child bone of a seam: `neck_01`, `spine_01`, `upperarm_*`, `lowerarm_*`, `hand_*`, `thigh_*`, `calf_*`, and `foot_*`. It stands 3 mm to 6 mm proud of the limb and carries the `joint` paint.
    - A `Socket` is a sphere on `clavicle_*` centred on `upperarm_*`. The upper arm leaves the socket on a circle that stays fixed in every pose, and the band starts on that circle. The pelvis has no sockets: its loft encloses the thigh caps, so no hip sphere grazes the pelvis surface.
    - A `Loft` spans a `Profile` of cross-section `Station`s. The torso is one `Loft` whose `chain` is `SPINE`. `body.blend` weights each vertex by a smoothstep over 80 mm (`BLEND`) around each spine joint, so a twist bends the surface and never cuts it.
    - A `Segment` or `Detail` is a superellipse sweep: the head, the hand blocks, the thumb, the horns, and the tail.
    - The imp reuses the human table with thicker radii per region, plus its own head, horns, and tail.
7. **Slot ownership.** `slot_regions` maps each armor slot to the regions it owns. No region belongs to two slots, and `hands` belongs to none.
8. **Clips.** `anim/clips.glb` is one clip library authored on the `clip_rig`. Each clip keys bone rotations plus one `pelvis` position track. The exporter runs with `export_optimize_animation_keep_anim_armature=False`, so it writes no constant per-bone position tracks and a smaller variant keeps its own bone lengths. The `.import` sidecar imports `clips.glb` as an `AnimationLibrary` and sets each loop mode in `_subresources`. Clip names carry no `_Loop` suffix. The rig glbs import with `animation/import=false`. `swing` winds up with the right elbow out to the side and back, strikes forward and down across the front at frame 7, and follows through with the hand in front of the hips at frame 9. The arm stays lateral of the chest in every frame, which padded sleeves need.
9. **Routes.** Each `routes` row maps an `action` and a `key` to a clip. Every action has a row with `key: ""`. `ArtContract.clip_for` returns the exact row, else the `key: ""` row, so an actor with no special key plays the default clip.
10. **Armor pieces.** Each `pieces` row names an item id, its `slot`, and the regions it `hides`. The 16 rows match the armor that `shared/sets.json` ships, in both directions. Each piece is one skinned `MeshInstance3D` named by its item id under `Rig/Skeleton3D` of the `clip_rig` glb (`humanoid.glb`). `art/armor.py` holds one `Look` per piece: a `pad`, a paint, and styled extras.
11. **Replacement rules.** A worn piece shows its mesh and hides the `region_<region>` meshes in its `hides`.
    - The skeleton stays at scale 1.0. No body part shrinks to fit gear.
    - `armor.covers` builds a `Cover` for every shape of every hidden region: the same shape grown by the piece's `pad`, with the same weights. Same weights means the shell encloses the hidden shape in every pose. A cover uses the shape's coarser `cover` resolution, and the chord sag stays inside the pad.
    - Where a piece hides both sides of a hinge (`upper_arms` and `forearms`, `thighs` and `shins`), `armor.sleeves` replaces the capsule and band covers of both regions with one `Capsule` sleeve. Its rings bend through the joint and blend both bones over `BLEND`.
    - A piece that hides `thighs` blends the lower sides of its pelvis cover into the thighs (`HIPS`) and grows it by `HIP_EASE`. Its thigh covers start 8 mm outward and 5 mm shallower, so the two legs and the hips meet without a grazing cut.
    - A clavicle socket cover of a piece that hides `upper_arms` grows until the arm exits it at 40 degrees or steeper and it contains the upper-arm band.
    - A piece hides only regions its own slot owns, and weights every vertex only to bones of those regions. `check_pieces` refuses any other bone.
    - Pieces that hide nothing (`cloth_hood`, `leather_helm`, `prospector_helm`, `forester_cap`) are hollow `Wall` shells whose inner surface clears the visible head.
    - Where a piece meets an uncovered region, its grown capsule cap or socket ends around the pivot of that seam and overlaps the visible band, the same way the bare body's shapes meet.
    - Where two slots overlap beyond a seam (the plate fauld over the trousers, the robe skirt over the thighs, boot shafts over the shins), the outer piece is a hollow `Wall` whose inner surface clears the inner piece.
12. **Clipping check.** `art/check_clipping.py` imports the built `humanoid.glb` and `clips.glb`, poses every fifth `idle` frame and every `walk` and `swing` frame, and splits each mesh into its closed parts. For the bare body, each `sets.json` kit, and each piece worn alone it counts vertices buried more than 3 mm inside another shown part, by ray parity and nearest-surface depth:
    - (a) visible body and worn piece parts inside each other
    - (b) parts of two different worn pieces inside each other
    - (c) arm parts inside torso, head, or hips parts, and leg parts inside torso or head parts
    - A vertex is exempt within a ball around a seam joint for (a) and (b), and around a shoulder or hip for (c). Rule 11 permits overlap there.
    - (d) measures visible triangle pairs within one body region or one piece that cross at under 30 degrees, with their cut-line length. It counts a blended part that folds into itself, and it hides a crossing inside another shown part. No seam is exempt. Faceted surfaces that meet at a shallow angle render a jagged line, while steep crossings such as band edges render clean.
    - The ball radius is the band's rim reach grown by the worn pad, `hypot(far + pad, radius + pad)`. `far` is the distance from the joint to the farther band anchor, and `radius` is the band's larger radius. Bare reaches run from 48 mm at the wrist to 139 mm at the waist, down from joint radius plus 3 cm.
    - Islands weld only within one dominant bone, so mirrored parts that touch stay separate.
    - It also counts hidden body vertices outside every part of their piece that shares a bone.
    - (a), (b), (c), and the enclosure count allow zero. (d) allows 60 mm of cut line per kit and clip.
13. **Hand items.** `hand_items` maps each tool kind in `shared/sets.json` to a static glb under `client/assets/proto/items/`, generated by `art/items.py`. In the glb (Godot axes) the grip centre is the origin. The haft, blade, or bow limbs run along +Y toward the head or tip. The striking side faces +Z, the model front: the sword edge, the axe blade, the front pick point, the shield face, and the bow belly. The bow string sits at -Z. Grips are 16 mm to 18 mm in radius, sized to the mannequin hand. Socket scenes still author their own per-item transforms.
14. **Generator.** `art/build.py` regenerates the character glbs, `anim/clips.glb`, and the hand item glbs in headless Blender with pinned export settings and sorted iteration. `art/check_determinism.py` runs the build twice and fails unless every glb has the same SHA-256.

## Regenerate the prototype art

1. To change a rest orientation, update `rest_source`, then run `blender --background --factory-startup --python-exit-code 1 --python art/extract_rest.py`.
2. Edit the region shapes in `art/body.py`, the armor looks in `art/armor.py`, the hand items in `art/items.py`, the keyframes in `art/clips.py`, or the contract.
3. Run `blender --background --factory-startup --python-exit-code 1 --python art/check_determinism.py`. It rebuilds every glb twice.
4. Run `blender --background --factory-startup --python-exit-code 1 --python art/check_clipping.py`. It prints the per-kit, per-clip table and exits non-zero on any buried vertex.
5. Run `godot --headless --path client --import`, then run the headless suite.

## Swap in real skinned art

1. Rig the art on the 23 contract bones with the contract rest orientations. The armature in `characters/humanoid.glb` is a valid starting rig.
2. Split the body into the nine `region_<region>` meshes. Weight each mesh only to its own region's bones.
3. Model each armor piece as one mesh named by its item id, weighted only to bones of its slot's regions, and covering its hidden regions in every clip.
4. Export to the variant's `glb` path with the armature named `Rig`. Keep `animation/import=false` in its sidecar.
5. The weight checks in `client/tests/test_art_assets.gd` already accept weights blended across the bones a mesh owns. `check_clipping.py` needs closed parts, so it applies to generated art only.
6. Run the headless suite. `test_art_assets.tscn` checks the bone set, the rest orientations against the clip rig and `rest_source`, the region meshes, the pieces, and the hand items.
7. To add a clip, add rows to `clips` and `routes`, author the clip, and add its `settings/loop_mode` to the `clips.glb.import` sidecar.

## Consequences

- `client/tests/test_art_contract.gd` checks the contract invariants, including pieces and hand items against `shared/sets.json`, and names each violation. `client/tests/test_art_assets.tscn` checks the imported glbs against the contract, including the imp pelvis height under `motion_scale`.
- A change to rest orientations invalidates every authored clip.
- A change to `swing`, `idle`, `walk`, or a region shape can bury gear. Rerun `check_clipping.py`.
- The check measures the human only. The imp plays the same clips with thicker regions and is inspected by render.

## Non-goals

- Props and clips other than `idle`, `walk`, and `swing`.
- Wiring the art into `player_avatar.tscn`, NPC scenes, or `session.gd` (ARM-274).
- Deleting the Quaternius assets.
