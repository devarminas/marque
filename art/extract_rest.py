"""blender --background --factory-startup --python-exit-code 1 --python art/extract_rest.py"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy

from contract import ContractError, read_raw, res_to_path, write_raw

DIGITS = 5
ROLL_DIGITS = 6


def main() -> None:
    raw = read_raw()
    source = res_to_path(raw["rest_source"])
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(source), bone_heuristic="BLENDER", guess_original_bind_pose=False)
    armatures = [ob for ob in bpy.data.objects if ob.type == "ARMATURE"]
    if len(armatures) != 1:
        raise ContractError(f"{source} holds {len(armatures)} armatures, expected 1")
    rig = armatures[0]
    if rig.matrix_world != rig.matrix_world.Identity(4):
        raise ContractError(f"{source} armature {rig.name!r} is not at the identity transform")

    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    rows = []
    for row in raw["bones"]:
        name = row["name"]
        edit = rig.data.edit_bones.get(name)
        if edit is None:
            raise ContractError(f"{source} has no bone {name!r}")
        parent = edit.parent.name if edit.parent else None
        if parent != row["parent"]:
            raise ContractError(f"{source} parents {name!r} to {parent!r}, the contract says {row['parent']!r}")
        rows.append({
            "name": name,
            "parent": row["parent"],
            "head": [round(v, DIGITS) + 0.0 for v in edit.head],
            "tail": [round(v, DIGITS) + 0.0 for v in edit.tail],
            "roll": round(edit.roll, ROLL_DIGITS) + 0.0,
        })
    bpy.ops.object.mode_set(mode="OBJECT")
    raw["bones"] = rows
    write_raw(raw)
    print(f"extract_rest: wrote {len(rows)} bone rests from {source.name}")


main()
