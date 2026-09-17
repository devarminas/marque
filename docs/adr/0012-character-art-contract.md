# 0012. Character art contract

## Status

Accepted (Prototype art). Extended with the airborne and cast clips and the world props.

## Context

Prototype character art replaces the Quaternius and Bestiary stand-ins and must itself be replaceable by real skinned art later. Players and NPCs share animations: an imp swing plays the player swing clip. The Quaternius UAL2 clips key bone rotations plus only `pelvis` location, so a clip transfers between bodies that share bone names and rest orientations.

Armor must never clip through the body in any pose. Shrinking the body under gear was measured to squash limbs and still leak at joints, so gear replaces the body regions it covers instead.

The body is a base-mesh mannequin: capsule limbs, a lofted torso, pelvis, and feet, and thin joint bands in the seams. Rigid single-bone parts leave a notch at a bent seam unless both sides stay on a sphere around the pivot. Where faceted parts on neighbouring bones overlap along a surface, they cross at a shallow angle and render a jagged sawtooth line. A continuous surface that blends weights across its bones bends instead of cutting.

## Decision

1. **One contract file.** `client/assets/proto/art_contract.json` holds the bones, variants, regions, slot ownership, armor pieces, hand items, clips, and routes. `client/scripts/art_contract.gd` parses it for the client and collects every violation in `errors`. No client code reads the raw JSON past this parser.
2. **Bones.** The rig has 23 UE-named bones: `root`, `pelvis`, `spine_01` to `spine_03`, `neck_01`, `Head`, and `clavicle`, `upperarm`, `lowerarm`, `hand`, `thigh`, `calf`, `foot`, and `ball` on each side. The armature node is `Rig`, so Godot imports the skeleton at `Rig/Skeleton3D`.
3. **Rest source.** Each bone's rest head, tail, and roll in the contract are copied from `rest_source` (`UAL2_Standard.glb`). Clips authored on the contract rig drive Quaternius-rigged bodies with no retarget.
4. **Variants.** A variant scales every rest position by `scale`, so bone lengths change and rest orientations stay identical. `human` has scale 1.0 and a pelvis at 0.917 m. `imp` has scale 0.676, a pelvis at 0.62 m, and a height of about 1.2 m. `clip_rig` names the variant that clips are authored on. A skeleton of another variant sets `Skeleton3D.motion_scale` to `ArtContract.motion_scale(variant)`, so the `pelvis` position track lands at that variant's own height.
5. **Regions.** Nine regions partition every bone except `root`. Each region is one skinned `MeshInstance3D` named `region_<region>` under `Rig/Skeleton3D`. A vertex weighs only bones of its region, and its weights sum to 1. The torso blends `spine_01` to `spine_03`. Every other prototype body vertex weighs 100% to one bone.
6. **Body shapes.** Each region is built from these shapes:
    - A capsule is a limb or the neck. Its cap centres sit on the joints at both ends, so the limb holds a ball around each pivot.
    - A band is a short flat ring between two anchors on the child bone of a seam: `neck_01`, `spine_01`, `upperarm_*`, `lowerarm_*`, `hand_*`, `thigh_*`, `calf_*`, and `foot_*`. It stands 3 mm to 6 mm proud of the limb and carries the `joint` paint.
    - A socket is a sphere on `clavicle_*` centred on `upperarm_*`. The upper arm leaves the socket on a circle that stays fixed in every pose, and the band starts on that circle. The pelvis has no sockets: its loft encloses the thigh caps, so no hip sphere grazes the pelvis surface.
    - A loft spans a profile of cross sections. The torso is one loft along the spine. Each torso vertex is weighted by a smoothstep over 80 mm around each spine joint, so a twist bends the surface and never cuts it.
    - A superellipse sweep forms the head, the hand blocks, the thumb, the horns, and the tail.
    - The imp uses the human shapes with thicker radii per region, plus its own head, horns, and tail.
7. **Slot ownership.** `slot_regions` maps each armor slot to the regions it owns. No region belongs to two slots, and `hands` belongs to none.
8. **Clips.** `anim/clips.glb` is one clip library authored on the `clip_rig`. Each clip keys bone rotations plus one `pelvis` position track. The glb holds no constant per-bone position tracks, so a smaller variant keeps its own bone lengths. The `.import` sidecar imports `clips.glb` as an `AnimationLibrary` and sets each loop mode in `_subresources`. Clip names carry no `_Loop` suffix. The rig glbs import with `animation/import=false`. `swing` winds up with the right elbow out to the side and back, strikes forward and down across the front at frame 7, and follows through with the hand in front of the hips at frame 9. The arm stays lateral of the chest in every frame, which padded sleeves need.
    The library holds seven clips: `idle` (60 frames, loop), `walk` (30, loop), `swing` (12, one-shot), `jump_start` (8, one-shot), `fall` (18, loop), `cast_windup` (24, loop), and `cast_release` (12, one-shot). `jump_start` drops the hips, folds the knees, pitches the torso forward and swings the arms back, then extends the legs and carries the arms overhead and forward, so its first and last frames read as different silhouettes. `fall` cycles an airborne tuck with one knee high and the other trailing, arms out for balance. `cast_windup` holds both hands in front of the chest with the elbows outboard of the shoulders, and sways. `cast_release` drives the hands forward over a short step with a torso turn, then settles to rest.
    A clip keys only the bones its own poses turn. A mixer that accumulates onto the rest pose returns every unkeyed bone to rest, so a clip never inherits a limb from the clip before it. Measured in the client: `fall` holds `calf_l` 55 degrees off rest, and switching to `cast_windup`, which keys no leg bone, puts it back at 0.00 degrees.
9. **Routes.** Each `routes` row maps an `action` and a `key` to a clip. Every action has a row with `key: ""`. `ArtContract.clip_for` returns the exact row, else the `key: ""` row, so an actor with no special key plays the default clip. `cast_windup` and `cast_release` key on the ability id: `fireball` carries its own row and `heal` resolves through the `key: ""` row, so an ability needs a row only when it wants a clip of its own. Every other action carries the `key: ""` row alone.
10. **Armor pieces.** Each `pieces` row names an item id, its `slot`, and the regions it `hides`. The 16 rows match the armor that `shared/sets.json` ships, in both directions. Each piece is one skinned `MeshInstance3D` named by its item id under `Rig/Skeleton3D` of the `clip_rig` glb (`humanoid.glb`). Each piece has a pad, a paint, and styled extras.
11. **Replacement rules.** A worn piece shows its mesh and hides the `region_<region>` meshes in its `hides`.
    - The skeleton stays at scale 1.0. No body part shrinks to fit gear.
    - A piece covers every shape of every hidden region with the same shape grown by the piece's pad, with the same weights. Same weights means the shell encloses the hidden shape in every pose. A cover uses a coarser resolution than its shape, and the chord sag stays inside the pad.
    - Where a piece hides both sides of a hinge (`upper_arms` and `forearms`, `thighs` and `shins`), one capsule sleeve replaces the capsule and band covers of both regions. Its rings bend through the joint and blend both bones over 80 mm.
    - A piece that hides `thighs` blends the lower sides of its pelvis cover into `thigh_l` and `thigh_r` and grows that cover by a further 26 mm. Its thigh covers start 8 mm outward and 5 mm shallower, so the two legs and the hips meet without a grazing cut.
    - A clavicle socket cover of a piece that hides `upper_arms` grows until the arm exits it at 40 degrees or steeper and it contains the upper-arm band.
    - A piece hides only regions its own slot owns, and weights every vertex only to bones of those regions. `client/tests/test_art_assets.gd` fails on any other bone.
    - Pieces that hide nothing (`cloth_hood`, `leather_helm`, `prospector_helm`, `forester_cap`) are hollow shells whose inner surface clears the visible head.
    - Where a piece meets an uncovered region, its grown capsule cap or socket ends around the pivot of that seam and overlaps the visible band, the same way the bare body's shapes meet.
    - Where two slots overlap beyond a seam (the plate fauld over the trousers, the robe skirt over the thighs, boot shafts over the shins), the outer piece is a hollow shell whose inner surface clears the inner piece.
12. **Clipping properties.** The shipped `humanoid.glb` and `clips.glb` were measured at every fifth `idle` frame, every second `cast_windup` frame, and every frame of `walk`, `swing`, `jump_start`, `fall`, and `cast_release`, with each mesh split into its closed parts. Each clip is posed from rest, the way the client's mixer starts it. The measurement covers the bare body, each `sets.json` kit, and each piece worn alone. It counts vertices buried more than 3 mm inside another shown part, by ray parity and nearest-surface depth:
    - (a) visible body and worn piece parts inside each other
    - (b) parts of two different worn pieces inside each other
    - (c) arm parts inside torso, head, or hips parts, and leg parts inside torso or head parts
    - A vertex is exempt within a ball around a seam joint for (a) and (b), and around a shoulder or hip for (c). Rule 11 permits overlap there.
    - (d) measures visible triangle pairs within one body region or one piece that cross at under 30 degrees, with their cut-line length. It counts a blended part that folds into itself, and it hides a crossing inside another shown part. No seam is exempt. Faceted surfaces that meet at a shallow angle render a jagged line, while steep crossings such as band edges render clean.
    - The ball radius is the band's rim reach grown by the worn pad, `hypot(far + pad, radius + pad)`. `far` is the distance from the joint to the farther band anchor, and `radius` is the band's larger radius. Bare reaches run from 48 mm at the wrist to 139 mm at the waist.
    - Islands weld only within one dominant bone, so mirrored parts that touch stay separate.
    - The enclosure count is the number of hidden body vertices outside every part of their piece that shares a bone.
    - (a), (b), (c), and the enclosure count allow zero. (d) allows 60 mm of cut line per kit and clip.
    - Result: (a), (b), (c), and the enclosure count are 0 on every kit and piece in every clip. The worst (d) cut line is 0 mm for the bare body in every clip. Across the kits it is 18 mm in `idle`, 49 mm in `walk`, 36 mm in `swing`, 36 mm in `jump_start`, 41 mm in `fall`, 9 mm in `cast_windup`, and 30 mm in `cast_release`.
    - The covers bound the poses. Hip flexion past about 30 degrees drives a skirt cover through the robe hem, and knee bend past about 55 degrees folds a trouser cover into itself, so `jump_start` takes its crouch depth from the pelvis drop and the torso pitch rather than deeper flexion.
    - Negative control: with `plate_chest` built from rigid capsule covers plus a separate pauldron, (d) fails 6 rows at the elbow with up to 689 mm of cut line.
    - Negative control: with the `plate_chest` pad set to -20 mm, 10 rows fail. 48 neck vertices sit up to 51 mm inside the chest shell, and 1058 hidden body vertices sit outside the shell.
    - The measurement covers the human only.
13. **Hand items.** `hand_items` maps each tool kind in `shared/sets.json` to a static glb under `client/assets/proto/items/`. In the glb (Godot axes) the grip centre is the origin. The haft, blade, or bow limbs run along +Y toward the head or tip. The striking side faces +Z, the model front: the sword edge, the axe blade, the front pick point, the shield face, and the bow belly. The bow string sits at -Z. Grips are 16 mm to 18 mm in radius, sized to the mannequin hand. Socket scenes still author their own per-item transforms.
14. **Generator.** The glbs are generated by an external Blender toolchain kept outside the repo. Two consecutive builds produced byte-identical files for all fifteen glbs: the two character glbs, `anim/clips.glb`, the six hand items, and the six props.
15. **Props.** `props` maps each world kind to the static glb that draws it. A gatherable node kind carries a `full` row and a `depleted` row. A kind with one look carries a single `""` row that any state falls back to, so a station arriving in wire state `full` still resolves. `ArtContract.prop_for` returns the exact state row, else the `""` row.
    - The rows cover the node and station kinds that the client scripts and the server source both declare, plus the `dummy` NPC kind. `client/tests/test_art_contract.gd` reads both sides and fails when they drift apart.
    - Each prop is one static mesh with no skeleton, built from the same soft primitives, flat colors, and bevelled edges as the mannequin, and sized in meters: the tree 4.1 m, the stump 0.5 m, the ore rock 1.1 m, the depleted rock 0.45 m, the smelter 2.3 m, and the training dummy 1.7 m.
    - The origin is the ground contact point. The lowest vertex sits within 20 mm of `y = 0`, so a prop is placed by its ground position alone.
    - In the glb (Godot axes) +Y is up and the model front faces +Z, as hand items do. The smelter mouth and the dummy target face the model front.
    - The triangle budget is 300 to 3,000. The shipped props measure 1352, 1192, 864, 1312, 1288, and 1524 triangles.
    - The training dummy keeps a neutral sack color, so the faction tint the client applies to an NPC still reads on it.
    - `client/tests/test_art_assets.gd` checks each prop glb for one static mesh with no skeleton, its triangle budget, and its origin on the ground.

## Swap in real skinned art

1. Rig the art on the 23 contract bones with the contract rest orientations. The armature in `characters/humanoid.glb` is a valid starting rig.
2. Split the body into the nine `region_<region>` meshes. Weight each mesh only to its own region's bones.
3. Model each armor piece as one mesh named by its item id, weighted only to bones of its slot's regions, and covering its hidden regions in every clip.
4. Export to the variant's `glb` path with the armature named `Rig`. Keep `animation/import=false` in its sidecar.
5. The weight checks in `client/tests/test_art_assets.gd` already accept weights blended across the bones a mesh owns. The clipping measurement in rule 12 needs closed parts, so it applies to generated art only.
6. Run `godot --headless --path client --import`, then run the headless suite. `test_art_assets.tscn` checks the bone set, the rest orientations against the clip rig and `rest_source`, the region meshes, the pieces, and the hand items.
7. To add a clip, add rows to `clips` and `routes`, author the clip, and add its `settings/loop_mode` to the `clips.glb.import` sidecar.

## Consequences

- `client/tests/test_art_contract.gd` checks the contract invariants, including pieces and hand items against `shared/sets.json`, and names each violation. `client/tests/test_art_assets.tscn` checks the imported glbs against the contract, including the imp pelvis height under `motion_scale`.
- The repo holds no generator. A change to a body shape, an armor piece, a hand item, a clip, or a prop means regenerating the glbs outside the repo and committing the results.
- A change to rest orientations invalidates every authored clip.
- A change to `swing`, `idle`, `walk`, or a region shape can bury gear. The rule 12 properties must hold again for the new glbs.
- The imp plays the same clips with thicker regions and is inspected by render.

## Non-goals

- Clips beyond the seven the library holds, and props beyond the six the table maps.
- Deleting the Quaternius assets.
