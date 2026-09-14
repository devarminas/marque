"""blender --background --factory-startup --python-exit-code 1 --python art/build.py"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy

from body import build_regions, check_shapes
from clips import build_actions, check_clips
from contract import load, res_to_path
from rig import build_rig

EXPORT = dict(
    export_format="GLB",
    use_selection=True,
    export_yup=True,
    export_apply=False,
    export_skins=True,
    export_def_bones=False,
    export_leaf_bone=False,
    export_materials="EXPORT",
    export_extras=False,
    export_morph=False,
    export_attributes=False,
    export_animation_mode="ACTIONS",
    export_force_sampling=True,
    export_optimize_animation_size=True,
    export_optimize_animation_keep_anim_armature=False,
    export_reset_pose_bones=True,
)


def reset(fps: int) -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = fps
    bpy.context.scene.frame_start = 0


def export(path: Path, objects: list[bpy.types.Object], animations: bool) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    for ob in sorted(objects, key=lambda ob: ob.name):
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(path), export_animations=animations, **EXPORT)
    print(f"build: wrote {path.name}")


def main() -> None:
    contract = load()
    check_shapes(contract)
    check_clips(contract)
    for name in sorted(contract.variants):
        variant = contract.variants[name]
        reset(contract.fps)
        rig = build_rig(contract, variant)
        export(res_to_path(variant.glb), [rig, *build_regions(contract, rig, variant)], animations=False)
    reset(contract.fps)
    rig = build_rig(contract, contract.variants[contract.clip_rig])
    build_actions(contract, rig)
    export(res_to_path(contract.clips_glb), [rig], animations=True)


main()
