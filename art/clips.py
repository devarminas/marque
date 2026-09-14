import math
from dataclasses import dataclass, field
from typing import NamedTuple

import bpy
from mathutils import Matrix, Quaternion, Vector

from contract import Contract, ContractError, Vec3

X = (1.0, 0.0, 0.0)
Y = (0.0, 1.0, 0.0)
Z = (0.0, 0.0, 1.0)
LOCATION_BONE = "pelvis"


class Turn(NamedTuple):
    armature_axis: Vec3
    degrees: float


@dataclass(frozen=True)
class Pose:
    turns: dict[str, tuple[Turn, ...]] = field(default_factory=dict)
    lift: Vec3 = (0.0, 0.0, 0.0)


BASE: dict[str, tuple[Turn, ...]] = {
    "upperarm_l": ((Y, 72.0),),
    "upperarm_r": ((Y, -72.0),),
    "lowerarm_l": ((Z, -15.0),),
    "lowerarm_r": ((Z, 15.0),),
}


def pose(lift: Vec3 = (0.0, 0.0, 0.0), **turns: tuple[Turn, ...]) -> Pose:
    return Pose({**BASE, **turns}, lift)


def stride(lead: str, trail: str, arm_lead: str, arm_trail: str, lift: float) -> Pose:
    return pose(
        (0.0, 0.0, lift),
        **{
            f"thigh_{lead}": ((X, -26.0),),
            f"thigh_{trail}": ((X, 22.0),),
            f"calf_{trail}": ((X, 18.0),),
            f"upperarm_{arm_lead}": (*BASE[f"upperarm_{arm_lead}"], (X, -22.0)),
            f"upperarm_{arm_trail}": (*BASE[f"upperarm_{arm_trail}"], (X, 22.0)),
        },
    )


def passing(swing: str, plant: str, lift: float) -> Pose:
    return pose(
        (0.0, 0.0, lift),
        **{
            f"thigh_{swing}": ((X, -8.0),),
            f"calf_{swing}": ((X, 42.0),),
            f"thigh_{plant}": ((X, 4.0),),
        },
    )


REST = pose()
BREATH = pose((0.0, 0.0, -0.012), spine_02=((X, 3.0),), spine_03=((X, 2.0),),
              upperarm_l=((Y, 69.0),), upperarm_r=((Y, -69.0),))
WINDUP = pose(
    (0.0, 0.0, 0.0),
    upperarm_r=((Y, 90.0), (X, -25.0)),
    lowerarm_r=((Z, 70.0),),
    spine_02=((Z, -14.0),),
    spine_03=((Z, -10.0), (X, -6.0)),
)
CONTACT = pose(
    (0.0, 0.0, -0.035),
    upperarm_r=((Y, 90.0), (X, 112.0)),
    lowerarm_r=((Z, 8.0),),
    spine_02=((Z, 12.0), (X, 10.0)),
    spine_03=((Z, 10.0), (X, 8.0)),
    thigh_l=((X, -14.0),),
    calf_l=((X, 12.0),),
)

SPECS: dict[str, tuple[tuple[int, Pose], ...]] = {
    "idle": ((0, REST), (30, BREATH), (60, REST)),
    "walk": (
        (0, stride("l", "r", "r", "l", -0.03)),
        (8, passing("r", "l", 0.012)),
        (15, stride("r", "l", "l", "r", -0.03)),
        (23, passing("l", "r", 0.012)),
        (30, stride("l", "r", "r", "l", -0.03)),
    ),
    "swing": ((0, REST), (4, WINDUP), (7, CONTACT), (12, REST)),
}


def check_clips(contract: Contract) -> None:
    if sorted(SPECS) != sorted(contract.clips):
        raise ContractError(f"clip specs cover {sorted(SPECS)}, the contract declares {sorted(contract.clips)}")
    names = {bone.name for bone in contract.bones}
    for clip, keys in SPECS.items():
        frames = [frame for frame, _ in keys]
        if frames[0] != 0 or frames[-1] != contract.clips[clip].frames or frames != sorted(set(frames)):
            raise ContractError(f"clip {clip!r} keys frames {frames}, expected ascending from 0 to {contract.clips[clip].frames}")
        if contract.clips[clip].loop and keys[0][1] != keys[-1][1]:
            raise ContractError(f"looping clip {clip!r} ends on a different pose than it starts")
        for _, key in keys:
            unknown = sorted(set(key.turns) - names)
            if unknown:
                raise ContractError(f"clip {clip!r} turns unknown bones {unknown}")


def build_actions(contract: Contract, rig: bpy.types.Object) -> None:
    rig.animation_data_create()
    for clip in sorted(SPECS):
        _build_action(rig, clip, SPECS[clip], contract.clips[clip].frames)
    rig.animation_data.action = None
    for clip in sorted(SPECS):
        track = rig.animation_data.nla_tracks.new()
        track.name = clip
        track.strips.new(clip, 0, bpy.data.actions[clip])


def _build_action(rig: bpy.types.Object, clip: str, keys: tuple[tuple[int, Pose], ...], frames: int) -> None:
    rig.animation_data.action = None
    bones = sorted({bone for _, key in keys for bone in key.turns})
    previous: dict[str, Quaternion] = {}
    for frame, key in keys:
        for bone in bones:
            pose_bone = rig.pose.bones[bone]
            pose_bone.rotation_mode = "QUATERNION"
            local = _local_rotation(pose_bone.bone.matrix_local, key.turns.get(bone, ()))
            if bone in previous and previous[bone].dot(local) < 0.0:
                local.negate()
            previous[bone] = local
            pose_bone.rotation_quaternion = local
            pose_bone.keyframe_insert("rotation_quaternion", frame=frame)
        pelvis = rig.pose.bones[LOCATION_BONE]
        pelvis.location = pelvis.bone.matrix_local.to_3x3().inverted() @ Vector(key.lift)
        pelvis.keyframe_insert("location", frame=frame)
    action = rig.animation_data.action
    action.name = clip
    action.use_frame_range = True
    action.frame_start = 0
    action.frame_end = frames
    action.use_fake_user = True


def _local_rotation(rest: Matrix, turns: tuple[Turn, ...]) -> Quaternion:
    world = Quaternion()
    for armature_axis, degrees in turns:
        world = Quaternion(Vector(armature_axis), math.radians(degrees)) @ world
    rest_rotation = rest.to_quaternion()
    return rest_rotation.inverted() @ world @ rest_rotation
