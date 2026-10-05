import pathlib
import subprocess

client = pathlib.Path(__file__).resolve().parents[1] / "client"
base = ["godot", "--headless", "--path", str(client)]
positive = subprocess.run(base + ["--script", "res://tests/core_property_inventory.gd"], capture_output=True, text=True, timeout=20)
if positive.returncode:
    raise SystemExit(positive.stdout + positive.stderr)
properties = [line.split()[1:] for line in positive.stdout.splitlines() if line.startswith("ARM360_PROPERTY ")]
properties += [[name, prop] for name in ["MarquePlayerHandle", "MarqueNpcHandle", "MarqueItemHandle", "MarqueNodeHandle"] for prop in ["valid", "kind", "index", "generation"]]
if len(properties) < 100:
    raise SystemExit("extension property inventory is incomplete")
for name, prop in properties:
    run = subprocess.run(base + ["--script", "res://tests/core_property_probe.gd", "--quit-after", "2", "--", name, prop], capture_output=True, text=True, timeout=10)
    output = run.stdout + run.stderr
    if run.returncode or f"ARM360_EXTENSION_PROPERTY_LOADED {name}.{prop}" not in output or "because it is read-only" not in output or "ARM360_PROPERTY_ASSIGNMENT_UNEXPECTEDLY_SUCCEEDED" in output:
        raise SystemExit(f"read-only control failed for {name}.{prop}\n{output}")
print(f"ARM360_READ_ONLY_PROPERTIES_PASS {len(properties)} isolated assignment runs")
