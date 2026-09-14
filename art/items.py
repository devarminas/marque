from dataclasses import dataclass

import bpy
from mathutils import Vector

from body import Radii, Resolution, material, sweep
from contract import Contract, ContractError, Vec3

PROP = Resolution(12, 8)
HAFT = Resolution(10, 12)
LIMB_OVERLAP = 0.04


@dataclass(frozen=True)
class Prop:
    start: Vec3
    end: Vec3
    start_radii: Radii
    end_radii: Radii
    roundness: float
    paint: str
    resolution: Resolution = PROP


ITEM_PALETTE: dict[str, Vec3] = {
    "gold": (0.85, 0.66, 0.24),
    "grip": (0.3, 0.18, 0.1),
    "orb": (0.35, 0.65, 0.95),
    "steel": (0.72, 0.75, 0.8),
    "steel_dark": (0.34, 0.36, 0.4),
    "string": (0.92, 0.9, 0.82),
    "wood": (0.55, 0.36, 0.2),
}


def _round(radius: float) -> Radii:
    return Radii(radius, radius)


def _limb(points: tuple[Vec3, ...], radii: tuple[float, ...]) -> tuple[Prop, ...]:
    props = []
    for a, b, ra, rb in zip(points, points[1:], radii, radii[1:]):
        reach = (Vector(b) - Vector(a)).normalized() * LIMB_OVERLAP
        props.append(Prop(tuple(Vector(a) - reach), tuple(Vector(b) + reach), _round(ra), _round(rb), 3.0, "wood"))
    return tuple(props)


BOW_LIMB = ((0.0, 0.0, 0.0), (0.0, 0.03, 0.3), (0.0, 0.1, 0.52), (0.0, 0.17, 0.66))
BOW_RADII = (0.024, 0.02, 0.016, 0.01)

ITEMS: dict[str, tuple[Prop, ...]] = {
    "sword": (
        Prop((0.0, 0.0, -0.07), (0.0, 0.0, 0.07), _round(0.017), _round(0.017), 6.0, "grip"),
        Prop((0.0, 0.0, -0.11), (0.0, 0.0, -0.055), _round(0.027), _round(0.027), 2.0, "gold"),
        Prop((0.0, -0.11, 0.08), (0.0, 0.11, 0.08), Radii(0.014, 0.02), Radii(0.014, 0.02), 3.0, "gold"),
        Prop((0.0, 0.0, 0.08), (0.0, 0.0, 0.84), Radii(0.009, 0.036), Radii(0.004, 0.014), 5.0, "steel"),
    ),
    "shield": (
        Prop((-0.07, 0.0, 0.0), (0.07, 0.0, 0.0), _round(0.016), _round(0.016), 6.0, "grip"),
        Prop((-0.07, 0.01, 0.0), (-0.07, -0.07, 0.0), _round(0.014), _round(0.014), 6.0, "grip"),
        Prop((0.07, 0.01, 0.0), (0.07, -0.07, 0.0), _round(0.014), _round(0.014), 6.0, "grip"),
        Prop((0.0, -0.06, 0.0), (0.0, -0.1, 0.0), _round(0.315), _round(0.315), 6.0, "steel_dark", Resolution(32, 6)),
        Prop((0.0, -0.055, 0.0), (0.0, -0.11, 0.0), _round(0.29), _round(0.29), 6.0, "wood", Resolution(32, 6)),
        Prop((0.0, -0.09, 0.0), (0.0, -0.15, 0.0), _round(0.075), _round(0.075), 2.0, "steel"),
    ),
    "staff": (
        Prop((0.0, 0.0, -0.72), (0.0, 0.0, 1.0), _round(0.02), _round(0.024), 12.0, "wood", HAFT),
        Prop((0.0, 0.0, 0.94), (0.0, 0.0, 1.05), _round(0.04), _round(0.034), 3.0, "gold"),
        Prop((0.0, 0.0, 1.02), (0.0, 0.0, 1.16), _round(0.065), _round(0.065), 2.0, "orb", Resolution(16, 10)),
    ),
    "bow": (
        *_limb(BOW_LIMB, BOW_RADII),
        *_limb(tuple((x, y, -z) for x, y, z in BOW_LIMB), BOW_RADII),
        Prop((0.0, 0.0, -0.08), (0.0, 0.0, 0.08), _round(0.027), _round(0.027), 6.0, "grip"),
        Prop((0.0, 0.17, -0.66), (0.0, 0.17, 0.66), _round(0.003), _round(0.003), 20.0, "string", Resolution(6, 12)),
    ),
    "lumberjack_axe": (
        Prop((0.0, 0.0, -0.36), (0.0, 0.0, 0.58), _round(0.02), _round(0.023), 12.0, "wood", HAFT),
        Prop((0.0, 0.06, 0.5), (0.0, -0.16, 0.48), Radii(0.02, 0.05), Radii(0.007, 0.095), 4.0, "steel"),
    ),
    "pickaxe": (
        Prop((0.0, 0.0, -0.26), (0.0, 0.0, 0.5), _round(0.018), _round(0.021), 12.0, "wood", HAFT),
        Prop((0.0, 0.0, 0.43), (0.0, 0.0, 0.52), _round(0.032), _round(0.03), 4.0, "steel_dark"),
        Prop((0.0, 0.0, 0.475), (0.0, -0.25, 0.41), Radii(0.022, 0.028), Radii(0.004, 0.006), 2.2, "steel"),
        Prop((0.0, 0.0, 0.475), (0.0, 0.25, 0.41), Radii(0.022, 0.028), Radii(0.004, 0.006), 2.2, "steel"),
    ),
}


def check_items(contract: Contract) -> None:
    if sorted(ITEMS) != sorted(contract.hand_items):
        raise ContractError(f"hand item props cover {sorted(ITEMS)}, the contract declares {sorted(contract.hand_items)}")
    for item, props in ITEMS.items():
        for prop in props:
            if prop.paint not in ITEM_PALETTE:
                raise ContractError(f"hand item {item!r} paints {prop.paint!r}, absent from the item palette")


def build_item(item: str) -> bpy.types.Object:
    materials: dict[str, bpy.types.Material] = {}
    verts: list[Vec3] = []
    faces: list[tuple[int, ...]] = []
    face_materials: list[str] = []
    for prop in ITEMS[item]:
        prop_verts, prop_faces = sweep(Vector(prop.start), Vector(prop.end), prop.start_radii, prop.end_radii,
                                       prop.roundness, prop.resolution, 1.0)
        base = len(verts)
        verts.extend(prop_verts)
        faces.extend(tuple(base + i for i in face) for face in prop_faces)
        face_materials.extend([material(f"item_{prop.paint}", ITEM_PALETTE[prop.paint], materials).name] * len(prop_faces))

    mesh = bpy.data.meshes.new(item)
    mesh.from_pydata(verts, [], faces)
    used = sorted(materials)
    for name in used:
        mesh.materials.append(materials[name])
    mesh.polygons.foreach_set("material_index", [used.index(name) for name in face_materials])
    mesh.polygons.foreach_set("use_smooth", [True] * len(faces))
    mesh.update()
    ob = bpy.data.objects.new(item, mesh)
    bpy.context.scene.collection.objects.link(ob)
    return ob
