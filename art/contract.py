from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CLIENT = REPO / "client"
CONTRACT_PATH = CLIENT / "assets/proto/art_contract.json"
JSON_WIDTH = 130

Vec3 = tuple[float, float, float]


class ContractError(Exception):
    pass


@dataclass(frozen=True)
class Bone:
    name: str
    parent: str | None
    head: Vec3
    tail: Vec3
    roll: float


@dataclass(frozen=True)
class Variant:
    name: str
    scale: float
    glb: str


@dataclass(frozen=True)
class Clip:
    name: str
    frames: int
    loop: bool


@dataclass(frozen=True)
class Piece:
    item: str
    slot: str
    hides: tuple[str, ...]


@dataclass(frozen=True)
class Contract:
    fps: int
    armature: str
    clips_glb: str
    clip_rig: str
    bones: tuple[Bone, ...]
    variants: dict[str, Variant]
    regions: dict[str, tuple[str, ...]]
    slot_regions: dict[str, tuple[str, ...]]
    pieces: dict[str, Piece]
    hand_items: dict[str, str]
    clips: dict[str, Clip]

    def bone(self, name: str) -> Bone:
        for bone in self.bones:
            if bone.name == name:
                return bone
        raise ContractError(f"no contract bone named {name!r}")


def res_to_path(res: str, root: Path = CLIENT) -> Path:
    if not res.startswith("res://"):
        raise ContractError(f"expected a res:// path, got {res!r}")
    return root / res.removeprefix("res://")


def read_raw(path: Path = CONTRACT_PATH) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_raw(raw: dict, path: Path = CONTRACT_PATH) -> None:
    path.write_text(_format(raw, 0) + "\n", encoding="utf-8", newline="\n")


def _format(value: object, depth: int) -> str:
    inline = json.dumps(value, separators=(", ", ": "))
    if not isinstance(value, (dict, list)) or len(inline) + 2 * depth <= JSON_WIDTH:
        return inline
    pad = "  " * (depth + 1)
    if isinstance(value, dict):
        rows = [f"{pad}{json.dumps(key)}: {_format(item, depth + 1)}" for key, item in value.items()]
        return "{\n" + ",\n".join(rows) + "\n" + "  " * depth + "}"
    rows = [pad + _format(item, depth + 1) for item in value]
    return "[\n" + ",\n".join(rows) + "\n" + "  " * depth + "]"


def load(path: Path = CONTRACT_PATH) -> Contract:
    raw = read_raw(path)
    bones = tuple(_bone(row) for row in _field(raw, "bones", list))
    names = [bone.name for bone in bones]
    for index, bone in enumerate(bones):
        if names.count(bone.name) != 1:
            raise ContractError(f"bone {bone.name!r} is declared {names.count(bone.name)} times")
        if (bone.parent is None) != (index == 0):
            raise ContractError(f"only the first bone is parentless, got {bone.name!r} parent {bone.parent!r}")
        if bone.parent is not None and bone.parent not in names[:index]:
            raise ContractError(f"bone {bone.name!r} names parent {bone.parent!r} before it is declared")
    regions = {
        region: tuple(_typed(bone, str, f"regions.{region}") for bone in _typed(members, list, f"regions.{region}"))
        for region, members in _field(raw, "regions", dict).items()
    }
    for region, members in regions.items():
        for bone in members:
            if bone not in names:
                raise ContractError(f"region {region!r} names unknown bone {bone!r}")
    slot_regions = {
        slot: tuple(_typed(region, str, f"slot_regions.{slot}") for region in _typed(members, list, f"slot_regions.{slot}"))
        for slot, members in _field(raw, "slot_regions", dict).items()
    }
    for slot, members in slot_regions.items():
        for region in members:
            if region not in regions:
                raise ContractError(f"slot {slot!r} owns unknown region {region!r}")
    pieces = {item: _piece(item, row, slot_regions) for item, row in _field(raw, "pieces", dict).items()}
    hand_items = {item: _res(path, f"hand_items.{item}") for item, path in _field(raw, "hand_items", dict).items()}
    variants = {
        name: Variant(
            name,
            _positive(_field(row, "scale", (int, float)), f"variants.{name}.scale"),
            _field(row, "glb", str),
        )
        for name, row in _field(raw, "variants", dict).items()
    }
    clip_rig = _field(raw, "clip_rig", str)
    if clip_rig not in variants:
        raise ContractError(f"clip_rig {clip_rig!r} is not a declared variant {sorted(variants)}")
    clips = {
        name: Clip(
            name,
            int(_positive(_field(row, "frames", int), f"clips.{name}.frames")),
            _field(row, "loop", bool),
        )
        for name, row in _field(raw, "clips", dict).items()
    }
    return Contract(
        fps=int(_positive(_field(raw, "fps", int), "fps")),
        armature=_field(raw, "armature", str),
        clips_glb=_field(raw, "clips_glb", str),
        clip_rig=clip_rig,
        bones=bones,
        variants=variants,
        regions=regions,
        slot_regions=slot_regions,
        pieces=pieces,
        hand_items=hand_items,
        clips=clips,
    )


def _piece(item: str, row: object, slot_regions: dict[str, tuple[str, ...]]) -> Piece:
    row = _typed(row, dict, f"pieces.{item}")
    slot = _field(row, "slot", str)
    if slot not in slot_regions:
        raise ContractError(f"piece {item!r} names unknown slot {slot!r}")
    hides = tuple(_typed(region, str, f"pieces.{item}.hides") for region in _field(row, "hides", list))
    for region in hides:
        if region not in slot_regions[slot]:
            raise ContractError(f"piece {item!r} hides region {region!r} outside slot {slot!r}")
    return Piece(item, slot, hides)


def _bone(row: object) -> Bone:
    row = _typed(row, dict, "bones[]")
    name = _field(row, "name", str)
    parent = row.get("parent")
    if parent is not None and not isinstance(parent, str):
        raise ContractError(f"bone {name!r} parent must be a string or null, got {parent!r}")
    if "head" not in row or "tail" not in row or "roll" not in row:
        raise ContractError(f"bone {name!r} has no rest; run art/extract_rest.py")
    return Bone(name, parent, _vec3(row["head"], f"{name}.head"), _vec3(row["tail"], f"{name}.tail"),
                float(_field(row, "roll", (int, float))))


def _vec3(value: object, where: str) -> Vec3:
    items = _typed(value, list, where)
    if len(items) != 3 or not all(isinstance(item, (int, float)) and not isinstance(item, bool) for item in items):
        raise ContractError(f"{where} must be three numbers, got {value!r}")
    return (float(items[0]), float(items[1]), float(items[2]))


def _field(row: dict, key: str, kind: type | tuple[type, ...]) -> object:
    if key not in row:
        raise ContractError(f"missing field {key!r} in {sorted(row)}")
    return _typed(row[key], kind, key)


def _typed(value: object, kind: type | tuple[type, ...], where: str) -> object:
    kinds = kind if isinstance(kind, tuple) else (kind,)
    if isinstance(value, bool) and bool not in kinds:
        raise ContractError(f"{where} must be {kind}, got {value!r}")
    if not isinstance(value, kind):
        raise ContractError(f"{where} must be {kind}, got {value!r}")
    return value


def _positive(value: float, where: str) -> float:
    if value <= 0:
        raise ContractError(f"{where} must be positive, got {value!r}")
    return value


def _res(value: object, where: str) -> str:
    path = _typed(value, str, where)
    if not path.startswith("res://"):
        raise ContractError(f"{where} must be a res:// path, got {path!r}")
    return path
