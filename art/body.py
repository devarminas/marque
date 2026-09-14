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
Chunk = tuple[list[Vec3], list[tuple[int, ...]], bpy.types.Material, str]


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


def _right(shape):
    bone = shape.bone[:-2] + "_r" if shape.bone.endswith("_l") else shape.bone
    if isinstance(shape, Joint):
        return replace(shape, bone=bone)
    return replace(shape, bone=bone, start=_mirror(shape.start), end=_mirror(shape.end))


def _mirror(anchor: Anchor) -> Anchor:
    return Anchor(anchor.along, (-anchor.offset[0], anchor.offset[1], anchor.offset[2]))


def both_sides(shapes: tuple) -> tuple:
    return (*shapes, *(_right(shape) for shape in shapes))


HUMAN_SHAPES: dict[str, tuple[Shape, ...]] = {
    "feet": both_sides((
        Joint("foot_l", 0.058),
        Segment("foot_l", Anchor(0.0, (0.0, 0.1, -0.058)), Anchor(1.0, (0.0, -0.2, 0.024)),
                Radii(0.063, 0.045), Radii(0.072, 0.036), 2.6),
    )),
    "forearms": both_sides((
        Joint("lowerarm_l", 0.063),
        Segment("lowerarm_l", Anchor(0.1), Anchor(0.92), Radii(0.057, 0.06), Radii(0.044, 0.046), 2.6),
    )),
    "hands": both_sides((
        Joint("hand_l", 0.048),
        Segment("hand_l", Anchor(0.45), Anchor(3.3), Radii(0.04, 0.048), Radii(0.036, 0.044), 2.4),
        Detail("hand_l", Anchor(0.9, (0.0, -0.035, 0.0)), Anchor(0.9, (0.04, -0.085, -0.01)), 0.02, 0.015, 2.2),
    )),
    "head": (
        Joint("neck_01", 0.05),
        Segment("neck_01", Anchor(0.1), Anchor(1.2), Radii(0.042, 0.042), Radii(0.04, 0.04), 4.0),
        Segment("Head", Anchor(-0.4, (0.0, -0.012, 0.0)), Anchor(3.0, (0.0, -0.012, 0.0)),
                Radii(0.07, 0.08), Radii(0.1, 0.11), 2.0),
    ),
    "hips": (
        Segment("pelvis", Anchor(-0.6), Anchor(1.2), Radii(0.15, 0.105), Radii(0.14, 0.1), 3.0),
    ),
    "shins": both_sides((
        Joint("calf_l", 0.08),
        Segment("calf_l", Anchor(0.08), Anchor(0.93), Radii(0.078, 0.081), Radii(0.054, 0.057), 2.6),
    )),
    "thighs": both_sides((
        Joint("thigh_l", 0.08),
        Segment("thigh_l", Anchor(0.1, (0.014, 0.0, 0.0)), Anchor(0.93, (0.004, 0.0, 0.0)),
                Radii(0.1, 0.102), Radii(0.072, 0.074), 2.6),
    )),
    "torso": (
        Joint("spine_01", 0.075),
        Segment("spine_01", Anchor(0.0), Anchor(1.3), Radii(0.085, 0.07), Radii(0.1, 0.075), 3.0),
        Segment("spine_03", Anchor(-0.9), Anchor(1.05), Radii(0.13, 0.095), Radii(0.17, 0.11), 4.0),
    ),
    "upper_arms": both_sides((
        Joint("upperarm_l", 0.075),
        Segment("upperarm_l", Anchor(0.12), Anchor(0.9), Radii(0.068, 0.07), Radii(0.055, 0.057), 2.6),
    )),
}

IMP_GIRTH: dict[str, float] = {
    "feet": 1.05, "forearms": 1.08, "hands": 1.2, "hips": 1.2,
    "shins": 1.08, "thighs": 1.08, "torso": 1.25, "upper_arms": 1.08,
}

IMP_HEAD: tuple[Shape, ...] = (
    Joint("neck_01", 0.06),
    Segment("neck_01", Anchor(0.1), Anchor(1.2), Radii(0.05, 0.05), Radii(0.05, 0.05), 4.0),
    Segment("Head", Anchor(-0.6, (0.0, -0.02, 0.0)), Anchor(5.0, (0.0, -0.02, 0.0)),
            Radii(0.12, 0.13), Radii(0.17, 0.17), 2.0),
    *both_sides((
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
    "imp": {"body": (0.66, 0.18, 0.13), "joint": (0.1, 0.05, 0.12), "horn": (0.86, 0.8, 0.62)},
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
    materials: dict[str, bpy.types.Material] = {}
    palette = PALETTES[variant.name]
    return [
        skinned(f"region_{region}", rig, [
            (*_solid(contract, variant, shape),
             material(f"{variant.name}_{shape.paint}", palette[shape.paint], materials), shape.bone)
            for shape in SHAPES[variant.name][region]
        ])
        for region in sorted(SHAPES[variant.name])
    ]


def skinned(name: str, rig: bpy.types.Object, chunks: list[Chunk]) -> bpy.types.Object:
    verts: list[Vec3] = []
    faces: list[tuple[int, ...]] = []
    face_materials: list[str] = []
    vertex_bones: list[str] = []
    by_name: dict[str, bpy.types.Material] = {}
    for chunk_verts, chunk_faces, chunk_material, bone in chunks:
        base = len(verts)
        verts.extend(chunk_verts)
        faces.extend(tuple(base + i for i in face) for face in chunk_faces)
        face_materials.extend([chunk_material.name] * len(chunk_faces))
        vertex_bones.extend([bone] * len(chunk_verts))
        by_name[chunk_material.name] = chunk_material

    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    used = sorted(by_name)
    for material_name in used:
        mesh.materials.append(by_name[material_name])
    mesh.polygons.foreach_set("material_index", [used.index(m) for m in face_materials])
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
            return sweep(head - reach, head + reach, sphere, sphere, SPHERE_ROUNDNESS, shape.resolution, variant.scale)
        case Segment():
            return sweep(anchor_point(head, tail, shape.start, variant), anchor_point(head, tail, shape.end, variant),
                         shape.start_radii, shape.end_radii, shape.roundness, shape.resolution, variant.scale)
        case Detail():
            return sweep(anchor_point(head, tail, shape.start, variant), anchor_point(head, tail, shape.end, variant),
                         Radii(shape.start_radius, shape.start_radius), Radii(shape.end_radius, shape.end_radius),
                         shape.roundness, shape.resolution, variant.scale)


def anchor_point(head: Vector, tail: Vector, anchor: Anchor, variant: Variant) -> Vector:
    return head + (tail - head) * anchor.along + Vector(scaled(anchor.offset, variant))


def _profile(t: float, roundness: float) -> float:
    return (1.0 - abs(2.0 * t - 1.0) ** roundness) ** (1.0 / roundness)


def ring(start: Vector, end: Vector, start_radii: Radii, end_radii: Radii, roundness: float,
         sides: int, t: float, scale: float) -> list[Vector]:
    axis = (end - start).normalized()
    reference = UP if abs(axis.dot(FORWARD)) > 0.9 else FORWARD
    across = axis.cross(reference).normalized()
    deep = axis.cross(across)
    profile = _profile(t, roundness)
    centre = start.lerp(end, t)
    radius_across = (start_radii.across + (end_radii.across - start_radii.across) * t) * profile
    radius_deep = (start_radii.deep + (end_radii.deep - start_radii.deep) * t) * profile
    points = []
    for side in range(sides):
        angle = 2.0 * math.pi * side / sides
        offset = across * (radius_across * math.cos(angle)) + deep * (radius_deep * math.sin(angle))
        points.append(centre + offset * scale)
    return points


def sweep(start: Vector, end: Vector, start_radii: Radii, end_radii: Radii, roundness: float,
          resolution: Resolution, scale: float) -> tuple[list[Vec3], list[tuple[int, ...]]]:
    sides, rings = resolution
    points = [start]
    for index in range(1, rings):
        t = (1.0 - math.cos(math.pi * index / rings)) / 2.0
        points.extend(ring(start, end, start_radii, end_radii, roundness, sides, t, scale))
    points.append(end)

    last = len(points) - 1
    faces: list[tuple[int, ...]] = []
    for side in range(sides):
        following = (side + 1) % sides
        faces.append((0, 1 + following, 1 + side))
        faces.append((last, last - sides + side, last - sides + following))
        for band in range(rings - 2):
            lower = 1 + band * sides
            upper = lower + sides
            faces.append((lower + side, lower + following, upper + following, upper + side))
    return rounded(points), faces


def rounded(points: list[Vector]) -> list[Vec3]:
    return [tuple(round(c, DIGITS) + 0.0 for c in point) for point in points]


def material(name: str, rgb: Vec3, cache: dict[str, bpy.types.Material]) -> bpy.types.Material:
    if name not in cache:
        created = bpy.data.materials.new(name)
        created.diffuse_color = (*rgb, 1.0)
        principled = created.node_tree.nodes.get("Principled BSDF") if created.node_tree else None
        if principled is None:
            raise ContractError(f"material {created.name!r} has no Principled BSDF node to paint")
        principled.inputs["Base Color"].default_value = (*rgb, 1.0)
        principled.inputs["Roughness"].default_value = 0.9
        cache[name] = created
    return cache[name]
