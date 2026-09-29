# gdext-core prototype

Throwaway prototype: a plain C++ core loaded into Godot 4.7 through GDExtension.

Build:

```bash
git clone --depth 1 https://github.com/godotengine/godot-cpp.git
mkdir -p api && (cd api && godot --headless --dump-extension-api)
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DGODOTCPP_TARGET=template_debug
cmake --build build -j
```

Test:

```bash
./build/marque_core_tests
godot --headless --path project --import || godot --headless --path project --import
godot --headless --path project --script res://test_world_client.gd
```

The first import of a fresh project aborts; the second succeeds. Root cause unknown.
