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
BAND_ROUNDNESS = 6.0
SPHERE_ROUNDNESS = 2.0
LOFT_SPACING = 0.025
COVER_SPACING = 0.04
BLEND = 0.08
HIPS = ("pelvis", "thigh_l", "thigh_r")
SPINE = ("spine_01", "spine_02", "spine_03")
HIP_TOP = 0.03
HIP_DROP = 0.08
HIP_SPLIT = 0.04
DIGITS = 6

Paint = Literal["body", "joint", "horn"]
Chunk = tuple[list[Vec3], list[tuple[int, ...]], bpy.types.Material, str]
Mesh = tuple[list[Vec3], list[tuple[int, ...]]]


class Radii(NamedTuple):
    across: float
    deep: float


class Resolution(NamedTuple):
    sides: int
    rings: int


class Anchor(NamedTuple):
    along: float
    offset: Vec3 = NO_OFFSET


class Station(NamedTuple):
    centre: Vec3
    across: float
    front: float
    back: float
    squareness: float


@dataclass(frozen=True)
class Profile:
    axis: Vec3
    facing: Vec3
    stations: tuple[Station, ...]


@dataclass(frozen=True)
class Capsule:
    resolution: ClassVar[Resolution] = Resolution(16, 3)
    cover: ClassVar[Resolution] = Resolution(10, 2)
    paint: ClassVar[Paint] = "body"

    bone: str
    start: Anchor
    end: Anchor
    start_radii: Radii
    end_radii: Radii
    chain: tuple[str, ...] = ()
    rings: tuple[float, ...] = ()
    bend: Anchor | None = None


@dataclass(frozen=True)
class Band:
    resolution: ClassVar[Resolution] = Resolution(16, 4)
    cover: ClassVar[Resolution] = Resolution(10, 3)
    paint: ClassVar[Paint] = "joint"

    bone: str
    start: Anchor
    end: Anchor
    radii: Radii


@dataclass(frozen=True)
class Socket:
    resolution: ClassVar[Resolution] = Resolution(16, 6)
    cover: ClassVar[Resolution] = Resolution(14, 5)
    paint: ClassVar[Paint] = "body"

    bone: str
    joint: str
    radius: float


@dataclass(frozen=True)
class Loft:
    cover_sides: ClassVar[int] = 12
    paint: ClassVar[Paint] = "body"

    bone: str
    profile: Profile
    span: tuple[float, float]
    sides: int = 24
    chain: tuple[str, ...] = ()


@dataclass(frozen=True)
class Segment:
    paint: ClassVar[Paint] = "body"

    bone: str
    start: Anchor
    end: Anchor
    start_radii: Radii
    end_radii: Radii
    roundness: float
    resolution: Resolution = Resolution(16, 10)


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


Shape = Capsule | Band | Socket | Loft | Segment | Detail


def _side(bone: str) -> str:
    return bone[:-2] + "_r" if bone.endswith("_l") else bone


def _mirror(anchor: Anchor) -> Anchor:
    return Anchor(anchor.along, (-anchor.offset[0], anchor.offset[1], anchor.offset[2]))


def _right(shape: Shape) -> Shape:
    match shape:
        case Socket():
            return replace(shape, bone=_side(shape.bone), joint=_side(shape.joint))
        case Loft():
            stations = tuple(station._replace(centre=(-station.centre[0], *station.centre[1:]))
                             for station in shape.profile.stations)
            return replace(shape, bone=_side(shape.bone), profile=replace(shape.profile, stations=stations))
        case _:
            return replace(shape, bone=_side(shape.bone), start=_mirror(shape.start), end=_mirror(shape.end))


def both_sides(shapes: tuple) -> tuple:
    return (*shapes, *(_right(shape) for shape in shapes))


FOOT = Profile((0.0, -1.0, 0.0), (0.0, 0.0, 1.0), (
    Station((0.089, 0.098, 0.045), 0.012, 0.012, 0.02, 2.0),
    Station((0.089, 0.085, 0.05), 0.036, 0.04, 0.05, 2.4),
    Station((0.089, 0.045, 0.06), 0.046, 0.06, 0.06, 2.8),
    Station((0.089, -0.02, 0.05), 0.05, 0.045, 0.05, 2.8),
    Station((0.089, -0.1, 0.034), 0.052, 0.03, 0.034, 2.8),
    Station((0.089, -0.175, 0.024), 0.046, 0.018, 0.024, 2.6),
    Station((0.089, -0.205, 0.02), 0.03, 0.012, 0.02, 2.2),
    Station((0.089, -0.214, 0.02), 0.01, 0.006, 0.012, 2.0),
))

PELVIS = Profile((0.0, 0.0, 1.0), (0.0, -1.0, 0.0), (
    Station((0.0, 0.015, 0.86), 0.09, 0.06, 0.07, 2.2),
    Station((0.0, 0.015, 0.905), 0.168, 0.1, 0.11, 2.6),
    Station((0.0, 0.015, 0.95), 0.186, 0.113, 0.123, 2.8),
    Station((0.0, 0.015, 1.0), 0.165, 0.097, 0.107, 2.6),
    Station((0.0, 0.02, 1.05), 0.128, 0.086, 0.09, 2.4),
))

TORSO = Profile((0.0, 0.0, 1.0), (0.0, -1.0, 0.0), (
    Station((0.0, 0.02, 1.02), 0.118, 0.08, 0.084, 2.2),
    Station((0.0, 0.02, 1.07), 0.12, 0.084, 0.086, 2.2),
    Station((0.0, 0.015, 1.17), 0.12, 0.105, 0.1, 2.2),
    Station((0.0, 0.01, 1.24), 0.14, 0.108, 0.095, 2.4),
    Station((0.0, 0.012, 1.315), 0.136, 0.115, 0.105, 2.4),
    Station((0.0, 0.02, 1.38), 0.16, 0.105, 0.092, 2.6),
    Station((0.0, 0.03, 1.44), 0.168, 0.09, 0.085, 2.5),
    Station((0.0, 0.035, 1.48), 0.138, 0.074, 0.072, 2.3),
    Station((0.0, 0.035, 1.51), 0.085, 0.05, 0.05, 2.1),
    Station((0.0, 0.035, 1.525), 0.045, 0.04, 0.04, 2.0),
))

HEAD = Segment("Head", Anchor(-0.4, (0.0, -0.012, 0.0)), Anchor(3.0, (0.0, -0.012, 0.0)),
               Radii(0.07, 0.08), Radii(0.1, 0.11), 2.0)

HUMAN_SHAPES: dict[str, tuple[Shape, ...]] = {
    "feet": both_sides((
        Band("foot_l", Anchor(0.0, (0.0, 0.0, 0.03)), Anchor(0.0, (0.0, 0.0, 0.066)), Radii(0.047, 0.048)),
        Loft("foot_l", FOOT, (-0.098, 0.214), sides=16),
    )),
    "forearms": both_sides((
        Band("lowerarm_l", Anchor(0.0), Anchor(0.14), Radii(0.053, 0.054)),
        Capsule("lowerarm_l", Anchor(0.0), Anchor(1.0), Radii(0.049, 0.05), Radii(0.037, 0.038)),
    )),
    "hands": both_sides((
        Band("hand_l", Anchor(-0.1), Anchor(0.5), Radii(0.04, 0.041)),
        Segment("hand_l", Anchor(0.2), Anchor(2.1), Radii(0.021, 0.042), Radii(0.018, 0.046), 3.0, Resolution(12, 6)),
        Segment("hand_l", Anchor(1.9), Anchor(3.8), Radii(0.014, 0.04), Radii(0.011, 0.034), 2.6, Resolution(12, 6)),
        Detail("hand_l", Anchor(0.9, (0.0, -0.03, 0.0)), Anchor(1.8, (0.0, -0.072, -0.004)), 0.013, 0.01, 2.2),
    )),
    "head": (
        Band("neck_01", Anchor(0.08), Anchor(0.5), Radii(0.047, 0.047)),
        Capsule("neck_01", Anchor(0.0), Anchor(1.0), Radii(0.043, 0.043), Radii(0.04, 0.04)),
        HEAD,
    ),
    "hips": (
        Loft("pelvis", PELVIS, (0.86, 1.05)),
    ),
    "shins": both_sides((
        Band("calf_l", Anchor(0.03), Anchor(0.13), Radii(0.064, 0.065)),
        Capsule("calf_l", Anchor(0.0), Anchor(1.0), Radii(0.06, 0.062), Radii(0.044, 0.045)),
    )),
    "thighs": both_sides((
        Band("thigh_l", Anchor(0.095), Anchor(0.21), Radii(0.088, 0.09)),
        Capsule("thigh_l", Anchor(0.0), Anchor(1.0), Radii(0.086, 0.088), Radii(0.063, 0.065)),
    )),
    "torso": (
        Band("spine_01", Anchor(-0.18), Anchor(0.18), Radii(0.137, 0.106)),
        Loft("spine_01", TORSO, (1.02, 1.525), chain=SPINE),
        *both_sides((Socket("clavicle_l", "upperarm_l", 0.07),)),
    ),
    "upper_arms": both_sides((
        Band("upperarm_l", Anchor(0.105), Anchor(0.25), Radii(0.064, 0.066)),
        Capsule("upperarm_l", Anchor(0.0), Anchor(1.0), Radii(0.062, 0.064), Radii(0.05, 0.051)),
    )),
}

IMP_GIRTH: dict[str, float] = {
    "feet": 1.05, "forearms": 1.08, "hands": 1.2, "hips": 1.2,
    "shins": 1.08, "thighs": 1.08, "torso": 1.25, "upper_arms": 1.08,
}

IMP_HEAD: tuple[Shape, ...] = (
    Band("neck_01", Anchor(0.08), Anchor(0.5), Radii(0.056, 0.056)),
    Capsule("neck_01", Anchor(0.0), Anchor(1.0), Radii(0.052, 0.052), Radii(0.05, 0.05)),
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


def _thicker_radii(radii: Radii, factor: float) -> Radii:
    return Radii(*(_thicker(r, factor) for r in radii))


def _girth(shape: Shape, factor: float) -> Shape:
    match shape:
        case Capsule() | Segment():
            return replace(shape, start_radii=_thicker_radii(shape.start_radii, factor),
                           end_radii=_thicker_radii(shape.end_radii, factor))
        case Band():
            return replace(shape, radii=_thicker_radii(shape.radii, factor))
        case Socket():
            return replace(shape, radius=_thicker(shape.radius, factor))
        case Loft():
            stations = tuple(station._replace(across=_thicker(station.across, factor),
                                              front=_thicker(station.front, factor),
                                              back=_thicker(station.back, factor))
                             for station in shape.profile.stations)
            return replace(shape, profile=replace(shape.profile, stations=stations))
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
    "human": {"body": (0.815, 0.361, 0.044), "joint": (0.332, 0.198, 0.672)},
    "imp": {"body": (0.66, 0.18, 0.13), "joint": (0.1, 0.05, 0.12), "horn": (0.86, 0.8, 0.62)},
}


def check_shapes(contract: Contract) -> None:
    for table in (SHAPES, PALETTES):
        if sorted(table) != sorted(contract.variants):
            raise ContractError(f"body tables cover variants {sorted(table)}, the contract declares {sorted(contract.variants)}")
    names = {bone.name for bone in contract.bones}
    for variant, regions in SHAPES.items():
        if sorted(regions) != sorted(contract.regions):
            raise ContractError(f"{variant} shapes cover regions {sorted(regions)}, the contract declares {sorted(contract.regions)}")
        for region, shapes in regions.items():
            for shape in shapes:
                if shape.bone not in contract.regions[region]:
                    raise ContractError(f"{variant} region {region!r} weights a shape to {shape.bone!r}, outside the region")
                if shape.paint not in PALETTES[variant]:
                    raise ContractError(f"{variant} region {region!r} paints {shape.paint!r}, absent from its palette")
                if isinstance(shape, Socket) and shape.joint not in names:
                    raise ContractError(f"{variant} region {region!r} centres a socket on unknown bone {shape.joint!r}")


def build_regions(contract: Contract, rig: bpy.types.Object, variant: Variant) -> list[bpy.types.Object]:
    materials: dict[str, bpy.types.Material] = {}
    palette = PALETTES[variant.name]
    return [
        skinned(f"region_{region}", rig, [
            (*solid(contract, variant, shape),
             material(f"{variant.name}_{shape.paint}", palette[shape.paint], materials), skin(shape))
            for shape in SHAPES[variant.name][region]
        ])
        for region in sorted(SHAPES[variant.name])
    ]


def skinned(name: str, rig: bpy.types.Object, chunks: list[Chunk]) -> bpy.types.Object:
    verts: list[Vec3] = []
    faces: list[tuple[int, ...]] = []
    face_materials: list[str] = []
    vertex_weights: list[tuple[tuple[str, float], ...]] = []
    by_name: dict[str, bpy.types.Material] = {}
    for chunk_verts, chunk_faces, chunk_material, bone in chunks:
        base = len(verts)
        verts.extend(chunk_verts)
        faces.extend(tuple(base + i for i in face) for face in chunk_faces)
        face_materials.extend([chunk_material.name] * len(chunk_faces))
        vertex_weights.extend(blend(rig, bone, vertex) for vertex in chunk_verts)
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
    names = sorted({name for weights in vertex_weights for name, _ in weights})
    groups = {name: ob.vertex_groups.new(name=name) for name in names}
    for index, weights in enumerate(vertex_weights):
        for name, weight in weights:
            groups[name].add([index], weight, "REPLACE")
    return ob


def skin(shape: Shape) -> str | tuple[str, ...]:
    return getattr(shape, "chain", ()) or shape.bone


def _smooth(value: float) -> float:
    value = min(max(value, 0.0), 1.0)
    return value * value * (3.0 - 2.0 * value)


def _hips(rig: bpy.types.Object, point: Vector) -> tuple[tuple[str, float], ...]:
    hip = rig.data.bones["thigh_l"].head_local
    leg = round(_smooth((hip.z - HIP_TOP - point.z) / HIP_DROP) * _smooth(abs(point.x) / HIP_SPLIT), 4)
    thigh = "thigh_l" if point.x > 0.0 else "thigh_r"
    if leg <= 0.0:
        return (("pelvis", 1.0),)
    if leg >= 1.0:
        return ((thigh, 1.0),)
    return (("pelvis", 1.0 - leg), (thigh, leg))


def blend(rig: bpy.types.Object, bones: str | tuple[str, ...], point: Vec3) -> tuple[tuple[str, float], ...]:
    if isinstance(bones, str):
        return ((bones, 1.0),)
    if bones == HIPS:
        return _hips(rig, Vector(point))
    reach = [1.0]
    for child in bones[1:]:
        bone = rig.data.bones[child]
        axis = (bone.tail_local - bone.head_local).normalized()
        reach.append(_smooth(((Vector(point) - bone.head_local).dot(axis) + BLEND) / (2.0 * BLEND)))
    reach.append(0.0)
    kept = [(name, round(reach[i] - reach[i + 1], 4)) for i, name in enumerate(bones)]
    kept = [(name, weight) for name, weight in kept if weight > 0.0]
    total = sum(weight for _, weight in kept)
    return tuple((name, weight / total) for name, weight in kept)


Ends = tuple[Vector, Vector, Radii, Radii]


def grown(ends: Ends, amount: float, scale: float) -> Ends:
    start, end, start_radii, end_radii = ends
    reach = (end - start).normalized() * (amount * scale)
    return (start - reach, end + reach, Radii(start_radii.across + amount, start_radii.deep + amount),
            Radii(end_radii.across + amount, end_radii.deep + amount))


def solid(contract: Contract, variant: Variant, shape: Shape, grow: float = 0.0, cover: bool = False) -> Mesh:
    bone = contract.bone(shape.bone)
    head = Vector(scaled(bone.head, variant))
    tail = Vector(scaled(bone.tail, variant))
    match shape:
        case Capsule():
            return capsule(anchor_point(head, tail, shape.start, variant), anchor_point(head, tail, shape.end, variant),
                           _plus(shape.start_radii, grow), _plus(shape.end_radii, grow),
                           shape.cover if cover else shape.resolution, variant.scale, shape.rings,
                           None if shape.bend is None else anchor_point(head, tail, shape.bend, variant))
        case Band():
            ends = grown((anchor_point(head, tail, shape.start, variant), anchor_point(head, tail, shape.end, variant),
                          shape.radii, shape.radii), grow, variant.scale)
            return sweep(*ends, BAND_ROUNDNESS, shape.cover if cover else shape.resolution, variant.scale)
        case Socket():
            joint = contract.bone(shape.joint)
            centre = Vector(scaled(joint.head, variant))
            radius = shape.radius + grow
            reach = (Vector(joint.tail) - Vector(joint.head)).normalized() * (radius * variant.scale)
            sphere = Radii(radius, radius)
            return sweep(centre - reach, centre + reach, sphere, sphere, SPHERE_ROUNDNESS,
                         shape.cover if cover else shape.resolution, variant.scale)
        case Loft():
            return loft(shape, grow, variant.scale, *((shape.cover_sides, COVER_SPACING) if cover else
                                                      (shape.sides, LOFT_SPACING)))
        case Segment():
            ends = grown((anchor_point(head, tail, shape.start, variant), anchor_point(head, tail, shape.end, variant),
                          shape.start_radii, shape.end_radii), grow, variant.scale)
            return sweep(*ends, shape.roundness, shape.resolution, variant.scale)
        case Detail():
            ends = grown((anchor_point(head, tail, shape.start, variant), anchor_point(head, tail, shape.end, variant),
                          Radii(shape.start_radius, shape.start_radius), Radii(shape.end_radius, shape.end_radius)),
                         grow, variant.scale)
            return sweep(*ends, shape.roundness, shape.resolution, variant.scale)


def _plus(radii: Radii, amount: float) -> Radii:
    return Radii(radii.across + amount, radii.deep + amount)


def anchor_point(head: Vector, tail: Vector, anchor: Anchor, variant: Variant) -> Vector:
    return head + (tail - head) * anchor.along + Vector(scaled(anchor.offset, variant))


def _profile(t: float, roundness: float) -> float:
    return (1.0 - abs(2.0 * t - 1.0) ** roundness) ** (1.0 / roundness)


def frame(axis: Vector) -> tuple[Vector, Vector]:
    reference = UP if abs(axis.dot(FORWARD)) > 0.9 else FORWARD
    across = axis.cross(reference).normalized()
    return across, axis.cross(across)


def _ellipse(centre: Vector, across: Vector, deep: Vector, radii: Radii, sides: int, scale: float) -> list[Vector]:
    points = []
    for side in range(sides):
        angle = 2.0 * math.pi * side / sides
        offset = across * (radii.across * math.cos(angle)) + deep * (radii.deep * math.sin(angle))
        points.append(centre + offset * scale)
    return points


def ring(start: Vector, end: Vector, start_radii: Radii, end_radii: Radii, roundness: float,
         sides: int, t: float, scale: float) -> list[Vector]:
    across, deep = frame((end - start).normalized())
    profile = _profile(t, roundness)
    radii = Radii((start_radii.across + (end_radii.across - start_radii.across) * t) * profile,
                  (start_radii.deep + (end_radii.deep - start_radii.deep) * t) * profile)
    return _ellipse(start.lerp(end, t), across, deep, radii, sides, scale)


def sweep(start: Vector, end: Vector, start_radii: Radii, end_radii: Radii, roundness: float,
          resolution: Resolution, scale: float) -> Mesh:
    sides, rings = resolution
    layers = [ring(start, end, start_radii, end_radii, roundness, sides, (1.0 - math.cos(math.pi * index / rings)) / 2.0,
                   scale) for index in range(1, rings)]
    return tube(start, layers, end)


def _polyline(start: Vector, bend: Vector | None, end: Vector, fraction: float) -> Vector:
    if bend is None:
        return start.lerp(end, fraction)
    first = (bend - start).length
    reach = fraction * (first + (end - bend).length)
    if reach <= first:
        return start.lerp(bend, reach / first)
    return bend.lerp(end, (reach - first) / (end - bend).length)


def capsule(start: Vector, end: Vector, start_radii: Radii, end_radii: Radii, resolution: Resolution,
            scale: float, rings: tuple[float, ...] = (), bend: Vector | None = None) -> Mesh:
    sides, cap_rings = resolution
    axis = (end - start).normalized()
    across, deep = frame(axis)
    reaches = (sum(start_radii) / 2.0 * scale, sum(end_radii) / 2.0 * scale)
    angles = [math.pi / 2.0 * index / cap_rings for index in range(1, cap_rings + 1)]
    layers = [_ellipse(start - axis * (reaches[0] * math.cos(a)), across, deep,
                       Radii(start_radii.across * math.sin(a), start_radii.deep * math.sin(a)), sides, scale)
              for a in angles]
    layers.extend(_ellipse(_polyline(start, bend, end, f), across, deep,
                           Radii(start_radii.across + (end_radii.across - start_radii.across) * f,
                                 start_radii.deep + (end_radii.deep - start_radii.deep) * f), sides, scale)
                  for f in rings)
    layers.extend(_ellipse(end + axis * (reaches[1] * math.cos(a)), across, deep,
                           Radii(end_radii.across * math.sin(a), end_radii.deep * math.sin(a)), sides, scale)
                  for a in reversed(angles))
    return tube(start - axis * reaches[0], layers, end + axis * reaches[1])


def _hermite(stations: tuple[Station, ...], keys: list[float], s: float) -> Station:
    s = min(max(s, keys[0]), keys[-1])
    index = max(i for i in range(len(keys) - 1) if keys[i] <= s) if s < keys[-1] else len(keys) - 2
    width = keys[index + 1] - keys[index]
    u = (s - keys[index]) / width

    def tangent(i: int) -> list[float]:
        low, high = max(i - 1, 0), min(i + 1, len(keys) - 1)
        rate = [(b - a) / (keys[high] - keys[low]) for a, b in zip(_flat(stations[low]), _flat(stations[high]))]
        return [r * width for r in rate]

    h00, h10, h01, h11 = 2 * u**3 - 3 * u**2 + 1, u**3 - 2 * u**2 + u, -2 * u**3 + 3 * u**2, u**3 - u**2
    values = [h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1 for p0, m0, p1, m1 in
              zip(_flat(stations[index]), tangent(index), _flat(stations[index + 1]), tangent(index + 1))]
    return Station(tuple(values[:3]), *values[3:])


def _flat(station: Station) -> list[float]:
    return [*station.centre, station.across, station.front, station.back, station.squareness]


def loft(shape: Loft, grow: float, scale: float, sides: int, spacing: float) -> Mesh:
    profile = shape.profile
    axis = Vector(profile.axis)
    side = axis.cross(Vector(profile.facing))
    deep = axis.cross(side)
    keys = [Vector(station.centre).dot(axis) for station in profile.stations]
    low, high = shape.span[0] - grow, shape.span[1] + grow
    count = max(1, round((high - low) / spacing))
    samples = [low + (high - low) * index / count for index in range(count + 1)]

    centres: list[Vector] = []
    layers: list[list[Vector]] = []
    for s in samples:
        station = _hermite(profile.stations, keys, s)
        centre = Vector(station.centre)
        centre = (centre + axis * (s - centre.dot(axis))) * scale
        exponent = 2.0 / station.squareness
        points = []
        for index in range(sides):
            angle = 2.0 * math.pi * index / sides
            c, n = math.cos(angle), math.sin(angle)
            x = math.copysign(abs(c) ** exponent, c) * (station.across + grow)
            y = math.copysign(abs(n) ** exponent, n) * ((station.back if n > 0.0 else station.front) + grow)
            points.append(centre + (side * x + deep * y) * scale)
        centres.append(centre)
        layers.append(points)
    return tube(centres[0], layers, centres[-1])


def tube(start: Vector, layers: list[list[Vector]], end: Vector) -> Mesh:
    sides = len(layers[0])
    points = [start, *(point for layer in layers for point in layer), end]
    last = len(points) - 1
    faces: list[tuple[int, ...]] = []
    for side in range(sides):
        following = (side + 1) % sides
        faces.append((0, 1 + following, 1 + side))
        faces.append((last, last - sides + side, last - sides + following))
        for band in range(len(layers) - 1):
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
