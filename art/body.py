from dataclasses import dataclass
from typing import NamedTuple

import bpy
from mathutils import Vector

from contract import Contract, ContractError, Variant, Vec3
from rig import scaled

FORWARD = Vector((0.0, -1.0, 0.0))
UP = Vector((0.0, 0.0, 1.0))
NO_OFFSET = (0.0, 0.0, 0.0)


class Section(NamedTuple):
    width: float
    depth: float


@dataclass(frozen=True)
class Segment:
    bone: str
    start_along: float
    end_along: float
    start_section: Section
    end_section: Section
    start_offset: Vec3 = NO_OFFSET
    end_offset: Vec3 = NO_OFFSET
    paint: str = ""


PALETTE: dict[str, Vec3] = {
    "boot": (0.16, 0.12, 0.10),
    "horn": (0.86, 0.80, 0.62),
    "imp_claw": (0.22, 0.06, 0.05),
    "imp_dark": (0.46, 0.11, 0.08),
    "imp_skin": (0.66, 0.18, 0.13),
    "linen": (0.80, 0.75, 0.62),
    "linen_dark": (0.66, 0.61, 0.50),
    "skin": (0.84, 0.63, 0.48),
    "trouser": (0.38, 0.29, 0.21),
    "trouser_dark": (0.30, 0.23, 0.17),
}

HUMAN_SHAPES: dict[str, tuple[str, tuple[Segment, ...]]] = {
    "feet": ("boot", (
        Segment("foot_l", 0.0, 1.0, (0.09, 0.08), (0.10, 0.04), start_offset=(0.0, 0.03, -0.05)),
        Segment("foot_r", 0.0, 1.0, (0.09, 0.08), (0.10, 0.04), start_offset=(0.0, 0.03, -0.05)),
        Segment("ball_l", 0.0, 1.0, (0.10, 0.04), (0.09, 0.03)),
        Segment("ball_r", 0.0, 1.0, (0.10, 0.04), (0.09, 0.03)),
    )),
    "forearms": ("skin", (
        Segment("lowerarm_l", 0.0, 1.0, (0.085, 0.085), (0.065, 0.07)),
        Segment("lowerarm_r", 0.0, 1.0, (0.085, 0.085), (0.065, 0.07)),
    )),
    "hands": ("skin", (
        Segment("hand_l", 0.0, 3.2, (0.04, 0.09), (0.035, 0.08)),
        Segment("hand_r", 0.0, 3.2, (0.04, 0.09), (0.035, 0.08)),
    )),
    "head": ("skin", (
        Segment("neck_01", 0.0, 1.0, (0.10, 0.10), (0.10, 0.10)),
        Segment("Head", 0.0, 2.9, (0.17, 0.20), (0.21, 0.24)),
    )),
    "hips": ("trouser", (
        Segment("pelvis", -1.0, 1.3, (0.34, 0.22), (0.31, 0.20)),
    )),
    "shins": ("trouser_dark", (
        Segment("calf_l", 0.0, 1.0, (0.11, 0.12), (0.075, 0.085)),
        Segment("calf_r", 0.0, 1.0, (0.11, 0.12), (0.075, 0.085)),
    )),
    "thighs": ("trouser", (
        Segment("thigh_l", 0.0, 1.0, (0.15, 0.16), (0.11, 0.12)),
        Segment("thigh_r", 0.0, 1.0, (0.15, 0.16), (0.11, 0.12)),
    )),
    "torso": ("linen", (
        Segment("spine_01", 0.0, 1.0, (0.30, 0.20), (0.32, 0.21)),
        Segment("spine_02", 0.0, 1.0, (0.32, 0.21), (0.36, 0.23)),
        Segment("spine_03", 0.0, 1.1, (0.38, 0.23), (0.30, 0.20)),
        Segment("clavicle_l", 0.3, 1.0, (0.10, 0.12), (0.10, 0.12)),
        Segment("clavicle_r", 0.3, 1.0, (0.10, 0.12), (0.10, 0.12)),
    )),
    "upper_arms": ("linen_dark", (
        Segment("upperarm_l", -0.05, 1.0, (0.11, 0.11), (0.09, 0.09)),
        Segment("upperarm_r", -0.05, 1.0, (0.11, 0.11), (0.09, 0.09)),
    )),
}

IMP_SHAPES: dict[str, tuple[str, tuple[Segment, ...]]] = {
    "feet": ("imp_claw", (
        Segment("foot_l", 0.0, 1.0, (0.07, 0.06), (0.08, 0.03), start_offset=(0.0, 0.02, -0.03)),
        Segment("foot_r", 0.0, 1.0, (0.07, 0.06), (0.08, 0.03), start_offset=(0.0, 0.02, -0.03)),
        Segment("ball_l", 0.0, 1.4, (0.08, 0.03), (0.02, 0.015)),
        Segment("ball_r", 0.0, 1.4, (0.08, 0.03), (0.02, 0.015)),
    )),
    "forearms": ("imp_skin", (
        Segment("lowerarm_l", 0.0, 1.0, (0.05, 0.05), (0.045, 0.045)),
        Segment("lowerarm_r", 0.0, 1.0, (0.05, 0.05), (0.045, 0.045)),
    )),
    "hands": ("imp_claw", (
        Segment("hand_l", 0.0, 3.6, (0.03, 0.07), (0.015, 0.06)),
        Segment("hand_r", 0.0, 3.6, (0.03, 0.07), (0.015, 0.06)),
    )),
    "head": ("imp_skin", (
        Segment("neck_01", 0.0, 1.0, (0.07, 0.07), (0.07, 0.07)),
        Segment("Head", 0.0, 4.0, (0.22, 0.22), (0.26, 0.25)),
        Segment("Head", 3.2, 3.2, (0.05, 0.05), (0.012, 0.012),
             start_offset=(0.08, 0.02, 0.0), end_offset=(0.17, 0.05, 0.12), paint="horn"),
        Segment("Head", 3.2, 3.2, (0.05, 0.05), (0.012, 0.012),
             start_offset=(-0.08, 0.02, 0.0), end_offset=(-0.17, 0.05, 0.12), paint="horn"),
    )),
    "hips": ("imp_dark", (
        Segment("pelvis", -1.2, 1.3, (0.26, 0.20), (0.28, 0.22)),
        Segment("pelvis", 0.0, 0.0, (0.05, 0.05), (0.012, 0.012),
             start_offset=(0.0, 0.08, -0.02), end_offset=(0.0, 0.36, -0.24)),
    )),
    "shins": ("imp_skin", (
        Segment("calf_l", 0.0, 1.0, (0.065, 0.065), (0.05, 0.05)),
        Segment("calf_r", 0.0, 1.0, (0.065, 0.065), (0.05, 0.05)),
    )),
    "thighs": ("imp_dark", (
        Segment("thigh_l", 0.0, 1.0, (0.10, 0.10), (0.07, 0.07)),
        Segment("thigh_r", 0.0, 1.0, (0.10, 0.10), (0.07, 0.07)),
    )),
    "torso": ("imp_skin", (
        Segment("spine_01", 0.0, 1.0, (0.28, 0.24), (0.31, 0.27)),
        Segment("spine_02", 0.0, 1.0, (0.31, 0.27), (0.29, 0.23)),
        Segment("spine_03", 0.0, 1.1, (0.27, 0.20), (0.20, 0.16)),
        Segment("clavicle_l", 0.3, 1.0, (0.06, 0.07), (0.06, 0.07)),
        Segment("clavicle_r", 0.3, 1.0, (0.06, 0.07), (0.06, 0.07)),
    )),
    "upper_arms": ("imp_dark", (
        Segment("upperarm_l", -0.05, 1.0, (0.06, 0.06), (0.05, 0.05)),
        Segment("upperarm_r", -0.05, 1.0, (0.06, 0.06), (0.05, 0.05)),
    )),
}

SHAPES = {"human": HUMAN_SHAPES, "imp": IMP_SHAPES}


def check_shapes(contract: Contract) -> None:
    if sorted(SHAPES) != sorted(contract.variants):
        raise ContractError(f"body shapes cover variants {sorted(SHAPES)}, the contract declares {sorted(contract.variants)}")
    for variant, regions in SHAPES.items():
        if sorted(regions) != sorted(contract.regions):
            raise ContractError(f"{variant} shapes cover regions {sorted(regions)}, the contract declares {sorted(contract.regions)}")
        for region, (paint, segments) in regions.items():
            for segment in segments:
                if segment.bone not in contract.regions[region]:
                    raise ContractError(f"{variant} region {region!r} weights a segment to {segment.bone!r}, outside the region")
                for name in (paint, segment.paint or paint):
                    if name not in PALETTE:
                        raise ContractError(f"{variant} region {region!r} paints unknown colour {name!r}")


def build_regions(contract: Contract, rig: bpy.types.Object, variant: Variant) -> list[bpy.types.Object]:
    materials: dict[str, bpy.types.Material] = {}
    regions = []
    for region in sorted(SHAPES[variant.name]):
        paint, segments = SHAPES[variant.name][region]
        regions.append(_region_object(contract, rig, variant, f"region_{region}", paint, segments, materials))
    return regions


def _region_object(contract, rig, variant, name, paint, segments, materials) -> bpy.types.Object:
    verts: list[Vector] = []
    faces: list[tuple[int, ...]] = []
    face_paints: list[str] = []
    vertex_bones: list[str] = []
    for segment in segments:
        base = len(verts)
        verts.extend(_box_corners(contract, variant, segment))
        faces.extend(tuple(base + i for i in face) for face in BOX_FACES)
        face_paints.extend([segment.paint or paint] * len(BOX_FACES))
        vertex_bones.extend([segment.bone] * 8)

    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(v) for v in verts], [], faces)
    paints = sorted(set(face_paints))
    for paint_name in paints:
        mesh.materials.append(_material(paint_name, materials))
    mesh.polygons.foreach_set("material_index", [paints.index(p) for p in face_paints])
    mesh.polygons.foreach_set("use_smooth", [False] * len(faces))
    mesh.update()

    ob = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(ob)
    ob.parent = rig
    ob.modifiers.new("Armature", "ARMATURE").object = rig
    groups = {}
    for bone in sorted(set(vertex_bones)):
        groups[bone] = ob.vertex_groups.new(name=bone)
    for index, bone in enumerate(vertex_bones):
        groups[bone].add([index], 1.0, "REPLACE")
    return ob


BOX_FACES = ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7))


def _box_corners(contract: Contract, variant: Variant, segment: Segment) -> list[Vector]:
    bone = contract.bone(segment.bone)
    head = Vector(scaled(bone.head, variant))
    tail = Vector(scaled(bone.tail, variant))
    start = head + (tail - head) * segment.start_along + Vector(segment.start_offset)
    end = head + (tail - head) * segment.end_along + Vector(segment.end_offset)
    axis = (end - start).normalized()
    reference = UP if abs(axis.dot(FORWARD)) > 0.9 else FORWARD
    across = axis.cross(reference).normalized()
    deep = axis.cross(across)
    corners = []
    for centre, (width, depth) in ((start, segment.start_section), (end, segment.end_section)):
        for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            corners.append(centre + across * (su * width / 2) + deep * (sv * depth / 2))
    return corners


def _material(name: str, materials: dict) -> bpy.types.Material:
    if name not in materials:
        material = bpy.data.materials.new(name)
        rgb = PALETTE[name]
        material.diffuse_color = (*rgb, 1.0)
        principled = material.node_tree.nodes.get("Principled BSDF") if material.node_tree else None
        if principled is None:
            raise ContractError(f"material {name!r} has no Principled BSDF node to paint")
        principled.inputs["Base Color"].default_value = (*rgb, 1.0)
        principled.inputs["Roughness"].default_value = 0.9
        materials[name] = material
    return materials[name]
