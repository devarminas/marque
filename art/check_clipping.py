"""blender --background --factory-startup --python-exit-code 1 --python art/check_clipping.py"""

import json
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

from armor import LOOKS
from body import HUMAN_SHAPES, Joint
from contract import REPO, Contract, ContractError, load, res_to_path

TOLERANCE = 0.003
SEAM_PAD = 0.03
LIMIT = 0
WELD_DIGITS = 5
RAY_STEP = 1.0e-5
MAX_CROSSINGS = 64
RAYS = tuple(Vector(v).normalized() for v in ((0.31, 0.53, 0.79), (-0.67, 0.29, -0.41), (0.23, -0.83, 0.37)))
FRAMES = {"idle": tuple(range(0, 60, 5)), "walk": tuple(range(30)), "swing": tuple(range(13))}
ARM_TRUNK = frozenset(("torso", "head", "hips"))
LEG_TRUNK = frozenset(("torso", "head"))
LIMB_TRUNKS = {
    "upper_arms": ARM_TRUNK, "forearms": ARM_TRUNK, "hands": ARM_TRUNK,
    "thighs": LEG_TRUNK, "shins": LEG_TRUNK, "feet": LEG_TRUNK,
}
LIMB_ROOTS = ("upperarm_l", "upperarm_r", "thigh_l", "thigh_r")
METRICS = ("a", "b", "c")
BODY = "body"
SETS = REPO / "shared/sets.json"
JOINT_RADII = {shape.bone: shape.radius for shapes in HUMAN_SHAPES.values() for shape in shapes if isinstance(shape, Joint)}


@dataclass(frozen=True)
class Island:
    owner: str
    bone: str
    region: str
    vertices: np.ndarray
    triangles: np.ndarray

    @property
    def name(self) -> str:
        return f"{self.owner}/{self.bone}"


@dataclass
class Posed:
    island: Island
    points: np.ndarray
    low: np.ndarray
    high: np.ndarray
    bvh: BVHTree


@dataclass(frozen=True)
class Config:
    name: str
    worn: tuple[str, ...]


@dataclass
class Worst:
    count: int = 0
    depth: float = 0.0
    frame: int = -1
    pair: str = ""


def import_human(contract: Contract) -> tuple[bpy.types.Object, list[bpy.types.Object]]:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = contract.fps
    bpy.ops.import_scene.gltf(filepath=str(res_to_path(contract.variants[contract.clip_rig].glb)))
    rigs = [ob for ob in bpy.data.objects if ob.type == "ARMATURE"]
    if len(rigs) != 1:
        raise ContractError(f"expected one armature in the human glb, got {len(rigs)}")
    meshes = sorted((ob for ob in bpy.data.objects if ob.type == "MESH" and ob.find_armature() == rigs[0]),
                    key=lambda ob: ob.name)
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(res_to_path(contract.clips_glb)))
    for ob in [ob for ob in bpy.data.objects if ob not in before]:
        bpy.data.objects.remove(ob)
    return rigs[0], meshes


def islands(contract: Contract, ob: bpy.types.Object) -> list[Island]:
    bone_region = {bone: region for region, bones in contract.regions.items() for bone in bones}
    mesh = ob.data
    mesh.calc_loop_triangles()
    coords = np.empty(len(mesh.vertices) * 3)
    mesh.vertices.foreach_get("co", coords)
    _, weld = np.unique(np.round(coords.reshape(-1, 3), WELD_DIGITS), axis=0, return_inverse=True)
    weld = weld.ravel()
    triangles = np.empty(len(mesh.loop_triangles) * 3, dtype=np.int64)
    mesh.loop_triangles.foreach_get("vertices", triangles)
    triangles = triangles.reshape(-1, 3)

    parent = list(range(weld.max() + 1))

    def find(node: int) -> int:
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    for a, b, c in weld[triangles]:
        root = find(a)
        for other in (b, c):
            parent[find(other)] = root
    labels = np.array([find(node) for node in weld])
    groups = {group.index: group.name for group in ob.vertex_groups}
    owner = ob.name.removeprefix("region_") if ob.name.startswith("region_") else ob.name
    result = []
    for label in sorted(set(labels.tolist())):
        vertices = np.nonzero(labels == label)[0]
        bones = {groups[g.group] for index in vertices.tolist() for g in mesh.vertices[index].groups if g.weight > 0.0}
        if len(bones) != 1:
            raise ContractError(f"{ob.name} island at vertex {vertices[0]} is weighted to {sorted(bones)}, expected one bone")
        bone = bones.pop()
        mask = np.isin(triangles[:, 0], vertices)
        result.append(Island(BODY if ob.name.startswith("region_") else owner, bone, bone_region[bone], vertices,
                             triangles[mask]))
    return result


def pose(rig: bpy.types.Object, meshes: list[bpy.types.Object], parts: dict[str, list[Island]], clip: str, frame: int):
    rig.animation_data_create()
    action = bpy.data.actions[clip]
    rig.animation_data.action = action
    if action.slots:
        rig.animation_data.action_slot = action.slots[0]
    bpy.context.scene.frame_set(frame)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    posed = {}
    for ob in meshes:
        evaluated = ob.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        coords = np.empty(len(mesh.vertices) * 3)
        mesh.vertices.foreach_get("co", coords)
        evaluated.to_mesh_clear()
        matrix = np.array(ob.matrix_world)
        coords = coords.reshape(-1, 3) @ matrix[:3, :3].T + matrix[:3, 3]
        for index, island in enumerate(parts[ob.name]):
            points = coords[island.vertices]
            remap = {vertex: row for row, vertex in enumerate(island.vertices.tolist())}
            local = [[remap[v] for v in triangle] for triangle in island.triangles.tolist()]
            bvh = BVHTree.FromPolygons(points.tolist(), local, all_triangles=True)
            posed[(ob.name, index)] = Posed(island, points, points.min(axis=0), points.max(axis=0), bvh)
    heads = {bone.name: np.array(rig.matrix_world @ bone.head) for bone in rig.pose.bones}
    return posed, heads


def crossings(bvh: BVHTree, origin: Vector, ray: Vector) -> int:
    count = 0
    location = origin
    while True:
        hit = bvh.ray_cast(location, ray)[0]
        if hit is None:
            return count
        count += 1
        if count > MAX_CROSSINGS:
            raise RuntimeError(f"ray from {tuple(origin)} crossed more than {MAX_CROSSINGS} faces")
        location = hit + ray * RAY_STEP


def inside(into: Posed, point: Vector) -> bool:
    return sum(crossings(into.bvh, point, ray) % 2 for ray in RAYS) >= 2


def buried(points: np.ndarray, into: Posed) -> dict[int, float]:
    near = np.all((points > into.low - TOLERANCE) & (points < into.high + TOLERANCE), axis=1)
    found = {}
    for index in np.nonzero(near)[0].tolist():
        point = Vector(points[index])
        depth = into.bvh.find_nearest(point)[3]
        if depth is not None and depth > TOLERANCE and inside(into, point):
            found[index] = depth
    return found


def overlaps(a: Posed, b: Posed) -> bool:
    return bool(np.all(a.low <= b.high) and np.all(b.low <= a.high))


class Frame:
    def __init__(self, number: int, posed: dict, heads: dict[str, np.ndarray]):
        self.number = number
        self.posed = posed
        self.heads = heads
        self._cache: dict[tuple, dict[int, float]] = {}

    def clashes(self, first, second) -> list[tuple[tuple, tuple, int, float]]:
        result = []
        for src, dst in ((first, second), (second, first)):
            if (src, dst) not in self._cache:
                hit = overlaps(self.posed[src], self.posed[dst])
                self._cache[(src, dst)] = buried(self.posed[src].points, self.posed[dst]) if hit else {}
            result.extend((src, dst, index, depth) for index, depth in self._cache[(src, dst)].items())
        return result


def configs(contract: Contract) -> list[Config]:
    kits = json.loads(SETS.read_text(encoding="utf-8"))["sets"]
    return [
        Config("bare", ()),
        *(Config(kit["id"], tuple(sorted(kit["slots"].values()))) for kit in kits),
        *(Config(item, (item,)) for item in sorted(contract.pieces)),
    ]


def _coverers(contract: Contract, config: Config) -> dict[str, str]:
    coverer = {region: BODY for region in contract.regions}
    for item in config.worn:
        for region in contract.pieces[item].hides:
            coverer[region] = item
    return coverer


def seams(contract: Contract, config: Config, bones: tuple[str, ...] | None = None) -> dict[str, float]:
    coverer = _coverers(contract, config)
    bone_region = {bone: region for region, members in contract.regions.items() for bone in members}
    balls = {}
    for bone in contract.bones:
        if bone.parent not in bone_region or bone_region[bone.name] == bone_region[bone.parent]:
            continue
        sides = (coverer[bone_region[bone.name]], coverer[bone_region[bone.parent]])
        if bones is None and sides[0] == sides[1]:
            continue
        if bones is not None and bone.name not in bones:
            continue
        pad = max((LOOKS[item].pad for item in sides if item != BODY), default=0.0)
        balls[bone.name] = JOINT_RADII[bone.name] + pad + SEAM_PAD
    return balls


def exempt(point: np.ndarray, heads: dict[str, np.ndarray], balls: dict[str, float]) -> bool:
    return any(np.linalg.norm(point - heads[bone]) <= radius for bone, radius in balls.items())


def measure(contract: Contract, frame: Frame, config: Config) -> dict[str, Worst]:
    hidden = {region for item in config.worn for region in contract.pieces[item].hides}
    shown = [key for key, posed in frame.posed.items()
             if (posed.island.owner == BODY and posed.island.region not in hidden) or posed.island.owner in config.worn]
    joints = seams(contract, config)
    roots = seams(contract, config, LIMB_ROOTS)
    pairs: dict[str, list] = {metric: [] for metric in METRICS}
    for i, first in enumerate(shown):
        for second in shown[i + 1:]:
            a, b = frame.posed[first].island, frame.posed[second].island
            if a.owner != b.owner:
                pairs["a" if BODY in (a.owner, b.owner) else "b"].append((first, second, joints))
            if b.region in LIMB_TRUNKS.get(a.region, ()) or a.region in LIMB_TRUNKS.get(b.region, ()):
                pairs["c"].append((first, second, roots))
    result = {}
    for metric, metric_pairs in pairs.items():
        offenders: dict[tuple, tuple[float, str]] = {}
        for first, second, allowed in metric_pairs:
            for src, dst, index, depth in frame.clashes(first, second):
                if exempt(frame.posed[src].points[index], frame.heads, allowed):
                    continue
                if depth > offenders.get((src, index), (0.0, ""))[0]:
                    offenders[(src, index)] = (depth, f"{frame.posed[src].island.name} in {frame.posed[dst].island.name}")
        deepest = max(offenders.values(), default=(0.0, ""))
        result[metric] = Worst(len(offenders), deepest[0], frame.number, deepest[1])
    return result


def exposed(contract: Contract, frame: Frame) -> dict[str, int]:
    result = {}
    for item, piece in sorted(contract.pieces.items()):
        shells = [posed for posed in frame.posed.values() if posed.island.owner == item]
        count = 0
        for posed in frame.posed.values():
            if posed.island.owner != BODY or posed.island.region not in piece.hides:
                continue
            around = [shell for shell in shells if shell.island.bone == posed.island.bone]
            for row in posed.points:
                point = Vector(row)
                if not any(shell.bvh.find_nearest(point)[3] <= TOLERANCE or inside(shell, point) for shell in around):
                    count += 1
        result[item] = count
    return result


def main() -> None:
    contract = load()
    rig, meshes = import_human(contract)
    parts = {ob.name: islands(contract, ob) for ob in meshes}
    kits = configs(contract)
    worst: dict[tuple[str, str], dict[str, Worst]] = {}
    enclosure: dict[str, int] = {}
    for clip, frames in FRAMES.items():
        for number in frames:
            frame = Frame(number, *pose(rig, meshes, parts, clip, number))
            if not enclosure:
                enclosure = exposed(contract, frame)
            for config in kits:
                row = worst.setdefault((config.name, clip), {metric: Worst() for metric in METRICS})
                for metric, found in measure(contract, frame, config).items():
                    held = row[metric]
                    if found.count > held.count or (found.count == held.count and found.depth > held.depth):
                        row[metric] = found

    print(f"clipping: worst frame per kit and clip; vertices buried deeper than {TOLERANCE * 1000:.0f} mm,"
          f" seams and limb roots exempt within joint radius + piece pad + {SEAM_PAD * 100:.0f} cm")
    print(f"{'kit':<20}{'clip':<7}{'(a) body/piece':>18}{'(b) piece/piece':>18}{'(c) limb/trunk':>18}")
    failures = []
    for (name, clip), row in worst.items():
        cells = []
        for metric in METRICS:
            found = row[metric]
            if found.count > LIMIT:
                failures.append(f"  {name} {clip} ({metric}) f{found.frame}: {found.count} vertices, deepest"
                                f" {found.depth * 1000:.0f} mm, {found.pair}")
            cells.append(f"{found.count} {found.depth * 1000:.0f}mm f{found.frame}" if found.count else "0")
        print(f"{name:<20}{clip:<7}" + "".join(f"{cell:>18}" for cell in cells))
    print("enclosure: hidden body vertices outside a same-bone part of their piece, " +
          ", ".join(f"{item} {count}" for item, count in enclosure.items()))
    failures.extend(f"  {item} leaves {count} hidden body vertices outside its shell" for item, count in enclosure.items() if count)
    if failures:
        print("\n".join(failures))
        raise RuntimeError(f"{len(failures)} rows exceed the limit of {LIMIT}")
    print("clipping: every kit stays within the limit")


main()
