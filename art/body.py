import math
from dataclasses import dataclass, replace
from typing import ClassVar, Literal, NamedTuple

import bpy
from mathutils import Vector

from contract import Contract, ContractError, Variant, Vec3
from rig import scaled

FORWARD = Vector((0.0, -1.0, 0.0))
UP = Vector((0.0, 0.0, 1.0))
NO_OFFSET = (0.0, 0.0, 0.0)
SPHERE_ROUNDNESS = 2.0
DIGITS = 6

Paint = Literal["body", "joint", "horn"]


class Radii(NamedTuple):
    across: float
    deep: float


class Resolution(NamedTuple):
    sides: int
    rings: int


class Anchor(NamedTuple):
    along: float
    offset: Vec3 = NO_OFFSET


@dataclass(frozen=True)
class Segment:
    resolution: ClassVar[Resolution] = Resolution(16, 10)
    paint: ClassVar[Paint] = "body"

    bone: str
    start: Anchor
    end: Anchor
    start_radii: Radii
    end_radii: Radii
    roundness: float


@dataclass(frozen=True)
class Joint:
    resolution: ClassVar[Resolution] = Resolution(12, 8)
    paint: ClassVar[Paint] = "joint"

    bone: str
    radius: float


@dataclass(frozen=True)
class Detail:
    resolution: ClassVar[Resolution] = Resolution(8, 6)

    bone: str
    start: Anchor
    end: Anchor
    start_radius: float
    end_radius: float
    roundness: float
    paint: Paint = "body"


Shape = Segment | Joint | Detail


def _right(shape: Shape) -> Shape:
    bone = shape.bone[:-2] + "_r" if shape.bone.endswith("_l") else shape.bone
    if isinstance(shape, Joint):
        return replace(shape, bone=bone)
    return replace(shape, bone=bone, start=_mirror(shape.start), end=_mirror(shape.end))


def _mirror(anchor: Anchor) -> Anchor:
    return Anchor(anchor.along, (-anchor.offset[0], anchor.offset[1], anchor.offset[2]))


def _sides(shapes: tuple[Shape, ...]) -> tuple[Shape, ...]:
    return (*shapes, *(_right(shape) for shape in shapes))


HUMAN_SHAPES: dict[str, tuple[Shape, ...]] = {
    "feet": _sides((
        Joint("foot_l", 0.042),
        Segment("foot_l", Anchor(0.0, (0.0, 0.05, -0.064)), Anchor(1.0, (0.0, -0.085, 0.02)),
                Radii(0.042, 0.036), Radii(0.048, 0.03), 2.3),
    )),
    "forearms": _sides((
        Joint("lowerarm_l", 0.043),
        Segment("lowerarm_l", Anchor(0.1), Anchor(0.92), Radii(0.042, 0.044), Radii(0.032, 0.034), 2.6),
    )),
    "hands": _sides((
        Joint("hand_l", 0.032),
        Segment("hand_l", Anchor(0.45), Anchor(3.3), Radii(0.02, 0.04), Radii(0.018, 0.036), 2.4),
        Detail("hand_l", Anchor(0.9, (0.0, -0.028, 0.0)), Anchor(0.9, (0.035, -0.058, -0.006)), 0.014, 0.01, 2.2),
    )),
    "head": (
        Joint("neck_01", 0.05),
        Segment("neck_01", Anchor(0.1), Anchor(1.2), Radii(0.042, 0.042), Radii(0.04, 0.04), 4.0),
        Segment("Head", Anchor(-0.4, (0.0, -0.012, 0.0)), Anchor(3.0, (0.0, -0.012, 0.0)),
                Radii(0.07, 0.08), Radii(0.1, 0.11), 2.0),
    ),
    "hips": (
        Segment("pelvis", Anchor(-0.6), Anchor(1.2), Radii(0.13, 0.095), Radii(0.125, 0.09), 3.0),
    ),
    "shins": _sides((
        Joint("calf_l", 0.058),
        Segment("calf_l", Anchor(0.08), Anchor(0.93), Radii(0.058, 0.06), Radii(0.04, 0.042), 2.6),
    )),
    "thighs": _sides((
        Joint("thigh_l", 0.066),
        Segment("thigh_l", Anchor(0.1), Anchor(0.93), Radii(0.078, 0.08), Radii(0.056, 0.058), 2.6),
    )),
    "torso": (
        Joint("spine_01", 0.075),
        Segment("spine_01", Anchor(0.0), Anchor(1.3), Radii(0.085, 0.07), Radii(0.1, 0.075), 3.0),
        Segment("spine_03", Anchor(-0.9), Anchor(1.05), Radii(0.13, 0.095), Radii(0.17, 0.11), 4.0),
    ),
    "upper_arms": _sides((
        Joint("upperarm_l", 0.056),
        Segment("upperarm_l", Anchor(0.12), Anchor(0.9), Radii(0.05, 0.052), Radii(0.04, 0.042), 2.6),
    )),
}

IMP_GIRTH: dict[str, float] = {
    "feet": 1.0, "forearms": 0.95, "hands": 1.15, "hips": 1.15,
    "shins": 0.95, "thighs": 0.95, "torso": 1.2, "upper_arms": 0.95,
}

IMP_HEAD: tuple[Shape, ...] = (
    Joint("neck_01", 0.06),
    Segment("neck_01", Anchor(0.1), Anchor(1.2), Radii(0.05, 0.05), Radii(0.05, 0.05), 4.0),
    Segment("Head", Anchor(-0.6, (0.0, -0.02, 0.0)), Anchor(5.0, (0.0, -0.02, 0.0)),
            Radii(0.12, 0.13), Radii(0.17, 0.17), 2.0),
    *_sides((
        Detail("Head", Anchor(3.8, (0.1, 0.0, 0.0)), Anchor(3.8, (0.2, 0.03, 0.2)), 0.04, 0.006, 3.0, "horn"),
    )),
)

IMP_TAIL: tuple[Shape, ...] = (
    Detail("pelvis", Anchor(0.0, (0.0, 0.08, -0.02)), Anchor(0.0, (0.0, 0.32, -0.14)), 0.032, 0.027, 2.4),
    Detail("pelvis", Anchor(0.0, (0.0, 0.3, -0.13)), Anchor(0.0, (0.0, 0.54, -0.18)), 0.027, 0.021, 2.4),
    Detail("pelvis", Anchor(0.0, (0.0, 0.52, -0.18)), Anchor(0.0, (0.0, 0.7, -0.04)), 0.021, 0.004, 2.4),
)


def _thicker(radius: float, factor: float) -> float:
    return round(radius * factor, 4)


def _girth(shape: Shape, factor: float) -> Shape:
    match shape:
        case Joint():
            return replace(shape, radius=_thicker(shape.radius, factor))
        case Segment():
            return replace(
                shape,
                start_radii=Radii(*(_thicker(r, factor) for r in shape.start_radii)),
                end_radii=Radii(*(_thicker(r, factor) for r in shape.end_radii)),
            )
        case Detail():
            return replace(shape, start_radius=_thicker(shape.start_radius, factor),
                           end_radius=_thicker(shape.end_radius, factor))


IMP_SHAPES: dict[str, tuple[Shape, ...]] = {
    region: tuple(_girth(shape, IMP_GIRTH[region]) for shape in shapes)
    for region, shapes in HUMAN_SHAPES.items() if region != "head"
}
IMP_SHAPES["head"] = IMP_HEAD
IMP_SHAPES["hips"] = (*IMP_SHAPES["hips"], *IMP_TAIL)

SHAPES: dict[str, dict[str, tuple[Shape, ...]]] = {"human": HUMAN_SHAPES, "imp": IMP_SHAPES}

PALETTES: dict[str, dict[Paint, Vec3]] = {
    "human": {"body": (0.86, 0.47, 0.2), "joint": (0.4, 0.3, 0.52)},
    "imp": {"body": (0.66, 0.18, 0.13), "joint": (0.28, 0.08, 0.07), "horn": (0.86, 0.8, 0.62)},
}


def check_shapes(contract: Contract) -> None:
    for table in (SHAPES, PALETTES):
        if sorted(table) != sorted(contract.variants):
            raise ContractError(f"body tables cover variants {sorted(table)}, the contract declares {sorted(contract.variants)}")
    for variant, regions in SHAPES.items():
        if sorted(regions) != sorted(contract.regions):
            raise ContractError(f"{variant} shapes cover regions {sorted(regions)}, the contract declares {sorted(contract.regions)}")
        for region, shapes in regions.items():
            for shape in shapes:
                if shape.bone not in contract.regions[region]:
                    raise ContractError(f"{variant} region {region!r} weights a shape to {shape.bone!r}, outside the region")
                if shape.paint not in PALETTES[variant]:
                    raise ContractError(f"{variant} region {region!r} paints {shape.paint!r}, absent from its palette")


def build_regions(contract: Contract, rig: bpy.types.Object, variant: Variant) -> list[bpy.types.Object]:
    materials: dict[Paint, bpy.types.Material] = {}
    return [
        _region_object(contract, rig, variant, region, SHAPES[variant.name][region], materials)
        for region in sorted(SHAPES[variant.name])
    ]


def _region_object(contract, rig, variant, region, shapes, materials) -> bpy.types.Object:
    verts: list[Vec3] = []
    faces: list[tuple[int, ...]] = []
    face_paints: list[Paint] = []
    vertex_bones: list[str] = []
    for shape in shapes:
        shape_verts, shape_faces = _solid(contract, variant, shape)
        base = len(verts)
        verts.extend(shape_verts)
        faces.extend(tuple(base + i for i in face) for face in shape_faces)
        face_paints.extend([shape.paint] * len(shape_faces))
        vertex_bones.extend([shape.bone] * len(shape_verts))

    name = f"region_{region}"
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    paints = sorted(set(face_paints))
    for paint in paints:
        mesh.materials.append(_material(variant.name, paint, materials))
    mesh.polygons.foreach_set("material_index", [paints.index(p) for p in face_paints])
    mesh.polygons.foreach_set("use_smooth", [True] * len(faces))
    mesh.update()

    ob = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(ob)
    ob.parent = rig
    ob.modifiers.new("Armature", "ARMATURE").object = rig
    groups = {bone: ob.vertex_groups.new(name=bone) for bone in sorted(set(vertex_bones))}
    for index, bone in enumerate(vertex_bones):
        groups[bone].add([index], 1.0, "REPLACE")
    return ob


def _solid(contract: Contract, variant: Variant, shape: Shape) -> tuple[list[Vec3], list[tuple[int, ...]]]:
    bone = contract.bone(shape.bone)
    head = Vector(scaled(bone.head, variant))
    tail = Vector(scaled(bone.tail, variant))
    match shape:
        case Joint():
            reach = (tail - head).normalized() * (shape.radius * variant.scale)
            sphere = Radii(shape.radius, shape.radius)
            return _sweep(head - reach, head + reach, sphere, sphere, SPHERE_ROUNDNESS, shape.resolution, variant.scale)
        case Segment():
            return _sweep(_point(head, tail, shape.start, variant), _point(head, tail, shape.end, variant),
                          shape.start_radii, shape.end_radii, shape.roundness, shape.resolution, variant.scale)
        case Detail():
            return _sweep(_point(head, tail, shape.start, variant), _point(head, tail, shape.end, variant),
                          Radii(shape.start_radius, shape.start_radius), Radii(shape.end_radius, shape.end_radius),
                          shape.roundness, shape.resolution, variant.scale)


def _point(head: Vector, tail: Vector, anchor: Anchor, variant: Variant) -> Vector:
    return head + (tail - head) * anchor.along + Vector(scaled(anchor.offset, variant))


def _profile(t: float, roundness: float) -> float:
    return (1.0 - abs(2.0 * t - 1.0) ** roundness) ** (1.0 / roundness)


def _sweep(start: Vector, end: Vector, start_radii: Radii, end_radii: Radii, roundness: float,
           resolution: Resolution, scale: float) -> tuple[list[Vec3], list[tuple[int, ...]]]:
    axis = (end - start).normalized()
    reference = UP if abs(axis.dot(FORWARD)) > 0.9 else FORWARD
    across = axis.cross(reference).normalized()
    deep = axis.cross(across)

    sides, rings = resolution
    points = [start]
    for ring in range(1, rings):
        t = (1.0 - math.cos(math.pi * ring / rings)) / 2.0
        profile = _profile(t, roundness)
        centre = start.lerp(end, t)
        radius_across = (start_radii.across + (end_radii.across - start_radii.across) * t) * profile
        radius_deep = (start_radii.deep + (end_radii.deep - start_radii.deep) * t) * profile
        for side in range(sides):
            angle = 2.0 * math.pi * side / sides
            offset = across * (radius_across * math.cos(angle)) + deep * (radius_deep * math.sin(angle))
            points.append(centre + offset * scale)
    points.append(end)

    last = len(points) - 1
    faces: list[tuple[int, ...]] = []
    for side in range(sides):
        following = (side + 1) % sides
        faces.append((0, 1 + following, 1 + side))
        faces.append((last, last - sides + side, last - sides + following))
        for ring in range(rings - 2):
            lower = 1 + ring * sides
            upper = lower + sides
            faces.append((lower + side, lower + following, upper + following, upper + side))
    return [tuple(round(c, DIGITS) + 0.0 for c in point) for point in points], faces


def _material(variant: str, paint: Paint, materials: dict) -> bpy.types.Material:
    if paint not in materials:
        material = bpy.data.materials.new(f"{variant}_{paint}")
        rgb = PALETTES[variant][paint]
        material.diffuse_color = (*rgb, 1.0)
        principled = material.node_tree.nodes.get("Principled BSDF") if material.node_tree else None
        if principled is None:
            raise ContractError(f"material {material.name!r} has no Principled BSDF node to paint")
        principled.inputs["Base Color"].default_value = (*rgb, 1.0)
        principled.inputs["Roughness"].default_value = 0.9
        materials[paint] = material
    return materials[paint]
