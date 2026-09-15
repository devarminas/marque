import math
from dataclasses import dataclass, replace

import bpy
from mathutils import Vector

from body import (HEAD, HIPS, HUMAN_SHAPES, PELVIS, SPINE, Anchor, Band, Capsule, Ends, Loft, Radii, Resolution, Shape,
                  Socket, anchor_point, both_sides, grown, material, ring, rounded, skin, skinned, solid, sweep)
from contract import Contract, ContractError, Variant, Vec3
from rig import scaled

SOLID = Resolution(12, 7)
WALL = Resolution(16, 6)
BAND = Resolution(16, 2)
EXIT_COSINE = math.cos(math.radians(40.0))
BAND_CLEARANCE = 0.008
HIP_EASE = 0.026
INSEAM = 0.008
INSEAM_DEPTH = 0.005


@dataclass(frozen=True)
class Solid:
    bone: str
    start: Anchor
    end: Anchor
    start_radii: Radii
    end_radii: Radii
    roundness: float
    paint: str
    grow: float = 0.0
    resolution: Resolution = SOLID
    chain: tuple[str, ...] = ()


@dataclass(frozen=True)
class Cover:
    shape: Shape
    grow: float
    paint: str

    @property
    def bone(self) -> str:
        return self.shape.bone


@dataclass(frozen=True)
class Wall:
    bone: str
    start: Anchor
    end: Anchor
    start_radii: Radii
    end_radii: Radii
    roundness: float
    paint: str
    thickness: float
    keep: tuple[float, float]
    grow: float = 0.0
    resolution: Resolution = WALL


Part = Solid | Cover | Wall


@dataclass(frozen=True)
class Look:
    pad: float
    paint: str
    extras: tuple[Part, ...] = ()
    region_paints: tuple[tuple[str, str], ...] = ()


GEAR_PALETTE: dict[str, Vec3] = {
    "boot": (0.28, 0.18, 0.1),
    "cloth": (0.44, 0.22, 0.6),
    "cloth_trim": (0.86, 0.7, 0.3),
    "green": (0.27, 0.5, 0.24),
    "green_dark": (0.15, 0.3, 0.15),
    "lamp": (1.0, 0.93, 0.55),
    "leather": (0.5, 0.31, 0.16),
    "linen": (0.86, 0.8, 0.66),
    "ochre": (0.84, 0.6, 0.2),
    "ochre_dark": (0.5, 0.36, 0.14),
    "steel": (0.66, 0.69, 0.73),
    "steel_dark": (0.32, 0.34, 0.38),
    "strap": (0.22, 0.13, 0.07),
}

def dome(keep: tuple[float, float], paint: str, thickness: float = 0.014, gap: float = 0.012,
         resolution: Resolution = WALL) -> Wall:
    return Wall("Head", HEAD.start, HEAD.end, HEAD.start_radii, HEAD.end_radii, HEAD.roundness, paint,
                thickness, keep, gap, resolution)


LOOKS: dict[str, Look] = {
    "plate_helm": Look(0.022, "steel", (
        Solid("Head", Anchor(1.3, (-0.07, -0.122, 0.0)), Anchor(1.3, (0.07, -0.122, 0.0)),
              Radii(0.014, 0.014), Radii(0.014, 0.014), 3.0, "steel_dark"),
    )),
    "plate_chest": Look(0.016, "steel", (
        Wall("spine_01", Anchor(-1.1, (0.0, 0.012, 0.0)), Anchor(1.6), Radii(0.27, 0.22), Radii(0.18, 0.15), 8.0,
             "steel_dark", thickness=0.012, keep=(0.18, 1.0), resolution=Resolution(14, 5)),
    )),
    "plate_legs": Look(0.016, "steel", both_sides((
        Solid("calf_l", Anchor(-0.1, (0.0, -0.07, 0.0)), Anchor(0.12, (0.0, -0.065, 0.0)),
              Radii(0.075, 0.05), Radii(0.06, 0.045), 2.4, "steel_dark"),
    ))),
    "cloth_hood": Look(0.0, "cloth", (
        Wall("Head", Anchor(-0.9, (0.0, -0.06, 0.0)), Anchor(3.6, (0.0, 0.07, 0.0)), Radii(0.105, 0.11),
             Radii(0.125, 0.135), 2.2, "cloth", thickness=0.012, keep=(0.3, 1.0)),
        Solid("Head", Anchor(3.75, (0.0, 0.085, 0.0)), Anchor(4.9, (0.0, 0.2, -0.04)),
              Radii(0.045, 0.045), Radii(0.006, 0.006), 2.2, "cloth"),
    )),
    "cloth_robe": Look(0.016, "cloth", (
        *both_sides((
            Wall("lowerarm_l", Anchor(0.3), Anchor(1.12), Radii(0.07, 0.07), Radii(0.1, 0.1), 8.0, "cloth",
                 thickness=0.01, keep=(0.0, 0.95), resolution=Resolution(12, 4)),
        )),
        Wall("spine_01", Anchor(-3.0, (0.0, -0.045, 0.0)), Anchor(1.2), Radii(0.315, 0.365), Radii(0.17, 0.14), 5.0,
             "cloth", thickness=0.012, keep=(0.04, 1.0), resolution=Resolution(14, 4)),
        Wall("spine_01", Anchor(-3.0, (0.0, -0.045, 0.0)), Anchor(1.2), Radii(0.315, 0.365), Radii(0.17, 0.14), 5.0,
             "cloth_trim", thickness=0.012, keep=(0.04, 0.1), grow=0.016, resolution=Resolution(14, 1)),
    )),
    "cloth_skirt": Look(0.016, "cloth", (
        Cover(Loft("pelvis", PELVIS, (0.985, 0.985)), 0.05, "cloth_trim"),
    )),
    "leather_helm": Look(0.0, "leather", (
        dome((0.5, 1.0), "leather"),
        dome((0.48, 0.58), "strap", thickness=0.024, gap=0.008, resolution=BAND),
        Solid("Head", Anchor(3.45, (0.0, -0.075, 0.0)), Anchor(3.3, (0.0, 0.085, 0.0)),
              Radii(0.012, 0.02), Radii(0.012, 0.02), 2.6, "strap"),
    )),
    "leather_chest": Look(0.014, "leather", (
        Solid("spine_03", Anchor(0.77, (0.1, -0.125, 0.0)), Anchor(-0.05, (-0.0065, -0.14, 0.0)),
              Radii(0.018, 0.008), Radii(0.018, 0.008), 6.0, "strap", chain=SPINE),
        Solid("spine_03", Anchor(0.0, (0.0, -0.14, 0.0)), Anchor(-0.77, (-0.1, -0.11, 0.0)),
              Radii(0.021, 0.012), Radii(0.021, 0.012), 6.0, "strap", chain=SPINE),
    )),
    "leather_legs": Look(0.013, "leather", (
        Cover(Loft("pelvis", PELVIS, (0.985, 0.985)), 0.047, "strap"),
    )),
    "prospector_helm": Look(0.0, "ochre", (
        dome((0.52, 1.0), "ochre"),
        dome((0.52, 0.6), "ochre_dark", thickness=0.05, resolution=Resolution(20, 2)),
        Solid("Head", Anchor(2.5, (0.0, -0.123, 0.0)), Anchor(2.5, (0.0, -0.165, 0.0)),
              Radii(0.03, 0.03), Radii(0.028, 0.028), 12.0, "lamp"),
    )),
    "prospector_jacket": Look(0.018, "ochre", (
        Solid("spine_01", Anchor(0.1, (0.0, -0.012, 0.0)), Anchor(0.42, (0.0, -0.014, 0.0)),
              Radii(0.13, 0.108), Radii(0.132, 0.11), 3.0, "ochre_dark"),
    )),
    "prospector_legs": Look(0.016, "ochre_dark", both_sides((
        Solid("calf_l", Anchor(-0.08, (0.0, -0.072, 0.0)), Anchor(0.14, (0.0, -0.066, 0.0)),
              Radii(0.07, 0.045), Radii(0.062, 0.042), 2.6, "ochre"),
    ))),
    "prospector_boots": Look(0.02, "boot", both_sides((
        Wall("foot_l", Anchor(0.0, (0.0, -0.008, -0.04)), Anchor(0.0, (0.0, -0.008, 0.14)), Radii(0.078, 0.105),
             Radii(0.08, 0.11), 8.0, "boot", thickness=0.009, keep=(0.0, 0.9)),
    ))),
    "forester_cap": Look(0.0, "green", (
        dome((0.6, 1.0), "green", gap=0.014),
        dome((0.6, 0.66), "green_dark", thickness=0.02, gap=0.01, resolution=BAND),
        Solid("Head", Anchor(1.8, (0.0, -0.118, 0.0)), Anchor(1.75, (0.0, -0.195, -0.015)),
              Radii(0.065, 0.012), Radii(0.05, 0.01), 2.5, "green_dark"),
    )),
    "forester_shirt": Look(0.014, "green", both_sides((
        Solid("lowerarm_l", Anchor(0.62), Anchor(0.86), Radii(0.066, 0.068), Radii(0.062, 0.064), 3.0, "green_dark"),
    )), region_paints=(("forearms", "linen"),)),
    "forester_trousers": Look(0.013, "green_dark", both_sides((
        Solid("calf_l", Anchor(0.8), Anchor(0.93), Radii(0.074, 0.076), Radii(0.07, 0.072), 3.0, "linen"),
    ))),
}


def covers(contract: Contract, region: str, look: Look, hides: tuple[str, ...]) -> tuple[Part, ...]:
    paint = dict(look.region_paints).get(region, look.paint)
    return tuple(Cover(_inseam(shape), _cover_grow(contract, shape, look.pad, hides), paint)
                 for shape in HUMAN_SHAPES[region])


def _inseam(shape: Shape) -> Shape:
    if not (isinstance(shape, (Capsule, Band)) and shape.bone.startswith("thigh_")):
        return shape
    outward = (INSEAM if shape.bone.endswith("_l") else -INSEAM, 0.0, 0.0)
    if isinstance(shape, Band):
        return replace(shape, start=Anchor(shape.start.along, outward), end=Anchor(shape.end.along, outward),
                       radii=Radii(shape.radii.across, shape.radii.deep - INSEAM_DEPTH))
    return replace(shape, start=Anchor(shape.start.along, outward),
                   start_radii=Radii(shape.start_radii.across, shape.start_radii.deep - INSEAM_DEPTH))


def _cover_grow(contract: Contract, shape: Shape, pad: float, hides: tuple[str, ...]) -> float:
    if _shorts(shape, hides):
        return pad + HIP_EASE
    if not isinstance(shape, Socket) or not any(shape.joint in contract.regions[region] for region in hides):
        return pad
    joint = contract.bone(shape.joint)
    length = (Vector(joint.tail) - Vector(joint.head)).length
    limb = [other for shapes in HUMAN_SHAPES.values() for other in shapes if other.bone == shape.joint]
    exit_radius = max((max(other.start_radii) + pad) / EXIT_COSINE for other in limb if isinstance(other, Capsule))
    band_reach = max((math.hypot(max(abs(other.start.along), abs(other.end.along)) * length, max(other.radii) + pad)
                      + BAND_CLEARANCE for other in limb if isinstance(other, Band)), default=0.0)
    return max(pad, exit_radius - shape.radius, band_reach - shape.radius)


HINGES = (("upper_arms", "forearms"), ("thighs", "shins"))
SLEEVE_STEP = 0.017
SLEEVE_RINGS = 5


def parts(contract: Contract, item: str) -> tuple[Part, ...]:
    look = LOOKS[item]
    hides = contract.pieces[item].hides
    joined = [pair for pair in HINGES if pair[0] in hides and pair[1] in hides]
    merged = {region for pair in joined for region in pair}
    kept = tuple(Cover(replace(part.shape, chain=HIPS), part.grow, part.paint) if _shorts(part.shape, hides) else part
                 for region in hides for part in covers(contract, region, look, hides)
                 if not (region in merged and isinstance(part.shape, (Capsule, Band))))
    return (*kept, *(part for pair in joined for part in sleeves(contract, pair, look)), *look.extras)


def _shorts(shape: Shape, hides: tuple[str, ...]) -> bool:
    return "thighs" in hides and isinstance(shape, Loft) and shape.bone == "pelvis"


def sleeves(contract: Contract, pair: tuple[str, str], look: Look) -> tuple[Part, ...]:
    capsules = {shape.bone: shape for region in pair for shape in HUMAN_SHAPES[region] if isinstance(shape, Capsule)}
    result = []
    for child in contract.regions[pair[1]]:
        rest = contract.bone(child)
        parent = contract.bone(rest.parent)
        head, tail, far = Vector(parent.head), Vector(parent.tail), Vector(rest.tail)
        length = (tail - head).length
        axis = (tail - head) / length
        along = (far - head).dot(axis) / length
        offset = far - (head + axis * (along * length))
        span = along * length
        joint = (Vector(rest.head) - head).dot(axis) / span
        bend = Vector(rest.head) - (head + axis * (joint * span))
        rings = tuple(round(joint + SLEEVE_STEP * k / span, 4) for k in range(-SLEEVE_RINGS, SLEEVE_RINGS + 1))
        root = _inseam(capsules[rest.parent])
        shape = Capsule(rest.parent, root.start, Anchor(along, (offset.x, offset.y, offset.z)),
                        root.start_radii, capsules[child].end_radii,
                        chain=(rest.parent, child), rings=rings,
                        bend=Anchor(joint * span / length, (bend.x, bend.y, bend.z)))
        result.append(Cover(shape, look.pad, dict(look.region_paints).get(pair[1], look.paint)))
    return tuple(result)


def check_pieces(contract: Contract) -> None:
    if sorted(LOOKS) != sorted(contract.pieces):
        raise ContractError(f"armor looks cover {sorted(LOOKS)}, the contract declares {sorted(contract.pieces)}")
    for item, piece in contract.pieces.items():
        owned = {bone for region in contract.slot_regions[piece.slot] for bone in contract.regions[region]}
        for part in parts(contract, item):
            if part.bone not in owned:
                raise ContractError(f"piece {item!r} weights a part to {part.bone!r}, outside slot {piece.slot!r}")
            if part.paint not in GEAR_PALETTE:
                raise ContractError(f"piece {item!r} paints {part.paint!r}, absent from the gear palette")


def build_pieces(contract: Contract, rig: bpy.types.Object) -> list[bpy.types.Object]:
    variant = contract.variants[contract.clip_rig]
    materials: dict[str, bpy.types.Material] = {}
    return [
        skinned(item, rig, [
            (*_geometry(contract, variant, part), material(f"gear_{part.paint}", GEAR_PALETTE[part.paint], materials),
             skin(part.shape if isinstance(part, Cover) else part))
            for part in parts(contract, item)
        ])
        for item in sorted(contract.pieces)
    ]


def _geometry(contract: Contract, variant: Variant, part: Part) -> tuple[list[Vec3], list[tuple[int, ...]]]:
    if isinstance(part, Cover):
        return solid(contract, variant, part.shape, part.grow, cover=True)
    bone = contract.bone(part.bone)
    head = Vector(scaled(bone.head, variant))
    tail = Vector(scaled(bone.tail, variant))
    ends = grown((anchor_point(head, tail, part.start, variant), anchor_point(head, tail, part.end, variant),
                  part.start_radii, part.end_radii), part.grow, variant.scale)
    match part:
        case Solid():
            return sweep(*ends, part.roundness, part.resolution, variant.scale)
        case Wall():
            return _wall(ends, grown(ends, part.thickness, variant.scale), part.roundness, part.keep,
                         part.resolution, variant.scale)


def _wall(inner: Ends, outer: Ends, roundness: float, keep: tuple[float, float], resolution: Resolution,
          scale: float) -> tuple[list[Vec3], list[tuple[int, ...]]]:
    sides, rings = resolution
    low, high = keep
    ts = [high if index == rings else low + (high - low) * (1.0 - math.cos(math.pi * index / rings)) / 2.0
          for index in range(rings + 1)]
    points: list[Vector] = []
    layers: list[list[list[int]]] = []
    for start, end, start_radii, end_radii in (inner, outer):
        layer = []
        for t in ts:
            base = len(points)
            if t <= 0.0 or t >= 1.0:
                points.append(start if t <= 0.0 else end)
                layer.append([base])
            else:
                points.extend(ring(start, end, start_radii, end_radii, roundness, sides, t, scale))
                layer.append(list(range(base, base + sides)))
        layers.append(layer)

    faces: list[tuple[int, ...]] = []
    for layer, inward in ((layers[0], True), (layers[1], False)):
        for lower, upper in zip(layer, layer[1:]):
            faces.extend(face[::-1] if inward else face for face in _band(lower, upper, sides))
    for index, low_end in ((0, True), (-1, False)):
        if len(layers[0][index]) > 1:
            faces.extend(face if low_end else face[::-1] for face in _band(layers[0][index], layers[1][index], sides))
    return rounded(points), faces


def _band(lower: list[int], upper: list[int], sides: int) -> list[tuple[int, ...]]:
    faces = []
    for side in range(sides):
        following = (side + 1) % sides
        if len(lower) == 1:
            faces.append((lower[0], upper[following], upper[side]))
        elif len(upper) == 1:
            faces.append((upper[0], lower[side], lower[following]))
        else:
            faces.append((lower[side], lower[following], upper[following], upper[side]))
    return faces
