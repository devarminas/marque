import bpy

from contract import Contract, Variant, Vec3


def scaled(point: Vec3, variant: Variant) -> Vec3:
    return (point[0] * variant.scale, point[1] * variant.scale, point[2] * variant.scale)


def build_rig(contract: Contract, variant: Variant) -> bpy.types.Object:
    data = bpy.data.armatures.new(contract.armature)
    rig = bpy.data.objects.new(contract.armature, data)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    for bone in contract.bones:
        edit = data.edit_bones.new(bone.name)
        edit.head = scaled(bone.head, variant)
        edit.tail = scaled(bone.tail, variant)
        edit.roll = bone.roll
        if bone.parent is not None:
            edit.parent = data.edit_bones[bone.parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return rig
