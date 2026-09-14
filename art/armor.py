import math
from dataclasses import dataclass

import bpy
from mathutils import Vector

from body import (HUMAN_SHAPES, SPHERE_ROUNDNESS, Anchor, Detail, Joint, Radii, Resolution, Segment,
                  anchor_point, both_sides, material, ring, rounded, skinned, sweep)
from contract import Contract, ContractError, Variant, Vec3
from rig import scaled

SOLID = Resolution(12, 7)
BALL = Resolution(10, 5)
WALL = Resolution(16, 6)
BAND = Resolution(16, 2)


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


@dataclass(frozen=True)
class Ball:
    bone: str
    radius: float
    paint: str
    resolution: Resolution = BALL


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


Part = Solid | Ball | Wall


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

HEAD = next(shape for shape in HUMAN_SHAPES["head"] if isinstance(shape, Segment) and shape.bone == "Head")


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
        *both_sides((
            Solid("upperarm_l", Anchor(-0.3), Anchor(0.3), Radii(0.116, 0.116), Radii(0.116, 0.116), 2.0, "steel_dark"),
        )),
        Wall("spine_01", Anchor(-1.1, (0.0, 0.012, 0.0)), Anchor(1.6), Radii(0.23, 0.18), Radii(0.14, 0.11), 8.0,
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
        Wall("spine_01", Anchor(-3.0, (0.0, -0.045, 0.0)), Anchor(1.2), Radii(0.29, 0.34), Radii(0.15, 0.12), 5.0,
             "cloth", thickness=0.012, keep=(0.04, 1.0), resolution=Resolution(14, 4)),
        Wall("spine_01", Anchor(-3.0, (0.0, -0.045, 0.0)), Anchor(1.2), Radii(0.29, 0.34), Radii(0.15, 0.12), 5.0,
             "cloth_trim", thickness=0.016, keep=(0.04, 0.1), grow=0.004, resolution=Resolution(14, 1)),
    )),
    "cloth_skirt": Look(0.016, "cloth", (
        Solid("pelvis", Anchor(0.5, (0.0, -0.004, 0.0)), Anchor(0.85, (0.0, -0.006, 0.0)),
              Radii(0.178, 0.132), Radii(0.174, 0.128), 6.0, "cloth_trim"),
    )),
    "leather_helm": Look(0.0, "leather", (
        dome((0.5, 1.0), "leather"),
        dome((0.48, 0.58), "strap", thickness=0.024, resolution=BAND),
        Solid("Head", Anchor(3.45, (0.0, -0.075, 0.0)), Anchor(3.3, (0.0, 0.085, 0.0)),
              Radii(0.012, 0.02), Radii(0.012, 0.02), 2.6, "strap"),
    )),
    "leather_chest": Look(0.014, "leather", (
        Solid("spine_03", Anchor(0.77, (0.1, -0.108, 0.0)), Anchor(0.0, (0.0, -0.14, 0.0)),
              Radii(0.018, 0.008), Radii(0.018, 0.008), 2.0, "strap"),
        Solid("spine_03", Anchor(0.0, (0.0, -0.14, 0.0)), Anchor(-0.77, (-0.1, -0.075, 0.0)),
              Radii(0.018, 0.008), Radii(0.018, 0.008), 2.0, "strap"),
    )),
    "leather_legs": Look(0.013, "leather", (
        Solid("pelvis", Anchor(0.5, (0.0, -0.004, 0.0)), Anchor(0.8, (0.0, -0.006, 0.0)),
              Radii(0.174, 0.13), Radii(0.17, 0.126), 6.0, "strap"),
    )),
    "prospector_helm": Look(0.0, "ochre", (
        dome((0.52, 1.0), "ochre"),
        dome((0.52, 0.6), "ochre_dark", thickness=0.05, resolution=Resolution(20, 2)),
        Solid("Head", Anchor(2.15, (0.0, -0.118, 0.0)), Anchor(2.15, (0.0, -0.165, 0.0)),
              Radii(0.03, 0.03), Radii(0.028, 0.028), 6.0, "lamp"),
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
        Wall("foot_l", Anchor(0.0, (0.0, -0.008, -0.04)), Anchor(0.0, (0.0, -0.008, 0.14)), Radii(0.078, 0.09),
             Radii(0.08, 0.094), 8.0, "boot", thickness=0.009, keep=(0.0, 0.9)),
    ))),
    "forester_cap": Look(0.0, "green", (
        dome((0.6, 1.0), "green", gap=0.014),
        dome((0.6, 0.66), "green_dark", thickness=0.02, gap=0.014, resolution=BAND),
        Solid("Head", Anchor(1.8, (0.0, -0.118, 0.0)), Anchor(1.75, (0.0, -0.195, -0.015)),
              Radii(0.065, 0.012), Radii(0.05, 0.01), 2.5, "green_dark"),
    )),
    "forester_shirt": Look(0.014, "green", both_sides((
        Solid("lowerarm_l", Anchor(0.06), Anchor(0.3), Radii(0.086, 0.088), Radii(0.08, 0.082), 3.0, "green_dark"),
    )), region_paints=(("forearms", "linen"),)),
    "forester_trousers": Look(0.013, "green_dark", both_sides((
        Solid("calf_l", Anchor(0.8), Anchor(0.93), Radii(0.074, 0.076), Radii(0.07, 0.072), 3.0, "linen"),
    ))),
}


def covers(region: str, look: Look) -> tuple[Part, ...]:
    paint = dict(look.region_paints).get(region, look.paint)
    parts: list[Part] = []
    for shape in HUMAN_SHAPES[region]:
        match shape:
            case Joint():
                parts.append(Ball(shape.bone, shape.radius + look.pad, paint))
            case Segment():
                parts.append(Solid(shape.bone, shape.start, shape.end, shape.start_radii, shape.end_radii,
                                   shape.roundness, paint, look.pad))
            case Detail():
                parts.append(Solid(shape.bone, shape.start, shape.end, Radii(shape.start_radius, shape.start_radius),
                                   Radii(shape.end_radius, shape.end_radius), shape.roundness, paint, look.pad))
    return tuple(parts)


def parts(contract: Contract, item: str) -> tuple[Part, ...]:
    look = LOOKS[item]
    return (*(part for region in contract.pieces[item].hides for part in covers(region, look)), *look.extras)


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
             part.bone)
            for part in parts(contract, item)
        ])
        for item in sorted(contract.pieces)
    ]


Ends = tuple[Vector, Vector, Radii, Radii]


def _geometry(contract: Contract, variant: Variant, part: Part) -> tuple[list[Vec3], list[tuple[int, ...]]]:
    bone = contract.bone(part.bone)
    head = Vector(scaled(bone.head, variant))
    tail = Vector(scaled(bone.tail, variant))
    match part:
        case Ball():
            reach = (tail - head).normalized() * (part.radius * variant.scale)
            sphere = Radii(part.radius, part.radius)
            return sweep(head - reach, head + reach, sphere, sphere, SPHERE_ROUNDNESS, part.resolution, variant.scale)
        case Solid():
            ends = _grown((anchor_point(head, tail, part.start, variant), anchor_point(head, tail, part.end, variant),
                           part.start_radii, part.end_radii), part.grow, variant.scale)
            return sweep(*ends, part.roundness, part.resolution, variant.scale)
        case Wall():
            inner = _grown((anchor_point(head, tail, part.start, variant), anchor_point(head, tail, part.end, variant),
                            part.start_radii, part.end_radii), part.grow, variant.scale)
            return _wall(inner, _grown(inner, part.thickness, variant.scale), part.roundness, part.keep,
                         part.resolution, variant.scale)


def _grown(ends: Ends, amount: float, scale: float) -> Ends:
    start, end, start_radii, end_radii = ends
    reach = (end - start).normalized() * (amount * scale)
    return (start - reach, end + reach, Radii(start_radii.across + amount, start_radii.deep + amount),
            Radii(end_radii.across + amount, end_radii.deep + amount))


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
