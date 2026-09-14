"""blender --background --factory-startup --python-exit-code 1 --python art/check_determinism.py"""

import hashlib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy

from contract import REPO, load, res_to_path

BUILD = Path(__file__).resolve().parent / "build.py"


def build_and_hash(outputs: list[Path]) -> dict[Path, str]:
    command = [bpy.app.binary_path, "--background", "--factory-startup", "--python-exit-code", "1", "--python", str(BUILD)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"build.py exited {result.returncode}:\n{result.stdout[-4000:]}\n{result.stderr[-4000:]}")
    return {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in outputs}


def main() -> None:
    contract = load()
    outputs = sorted({res_to_path(variant.glb) for variant in contract.variants.values()}
                     | {res_to_path(contract.clips_glb)}
                     | {res_to_path(path) for path in contract.hand_items.values()})
    first = build_and_hash(outputs)
    second = build_and_hash(outputs)
    for path in outputs:
        verdict = "identical" if first[path] == second[path] else f"differs from {first[path]}"
        print(f"determinism: {second[path]} {path.relative_to(REPO).as_posix()} {verdict}")
    if first != second:
        raise RuntimeError("generator output is not deterministic")
    print(f"determinism: {len(outputs)} glbs identical across two runs")


main()
