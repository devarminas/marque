package navmesh

import (
	"math"
	"path/filepath"
	"runtime"
	"testing"
)

func arenaJSON(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(RelPath))
}

func loadArena(t *testing.T) *Mesh {
	t.Helper()
	m, err := LoadJSON(arenaJSON(t))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Polys) == 0 || len(m.Vertices) == 0 {
		t.Fatal("arena nav JSON is empty")
	}
	return m
}

func TestLoadArenaJSON(t *testing.T) {
	_ = loadArena(t)
}

func TestHeightAtOrigin(t *testing.T) {
	m := loadArena(t)
	y, ok := m.HeightAt(0, 0)
	t.Logf("HeightAt(0,0) y=%v ok=%v", y, ok)
	if !ok {
		t.Fatal("expected (0,0) on arena mesh")
	}
	if math.IsNaN(y) || math.IsInf(y, 0) {
		t.Fatalf("bad height %v", y)
	}
}

func TestHeightAtFloorSample(t *testing.T) {
	m := loadArena(t)
	// Low vertex on the exported mesh; should be on a containing triangle.
	v := m.Vertices[0]
	y, ok := m.HeightAt(v.X, v.Z)
	if !ok {
		t.Fatalf("vertex 0 xz=(%v,%v) not on mesh", v.X, v.Z)
	}
	if math.Abs(y-v.Y) > 1e-3 {
		t.Fatalf("HeightAt=%v, vertex Y=%v", y, v.Y)
	}
}

func TestHeightAtOffMesh(t *testing.T) {
	m := loadArena(t)
	if _, ok := m.HeightAt(1000, 1000); ok {
		t.Fatal("far point should be off mesh")
	}
}

func TestMoveAllowsOnMesh(t *testing.T) {
	m := loadArena(t)
	x, z := m.Move(0, 0, 0.5, 0)
	if math.Abs(x-0.5) > 1e-9 || z != 0 {
		t.Fatalf("Move=%v,%v want 0.5,0", x, z)
	}
}

func TestMoveStopsAtBoundary(t *testing.T) {
	m := loadArena(t)
	fromX, fromZ := 0.0, 0.0
	if _, ok := m.HeightAt(fromX, fromZ); !ok {
		t.Fatal("from must be on mesh")
	}
	toX, toZ := 200.0, 0.0
	x, z := m.Move(fromX, fromZ, toX, toZ)
	if _, ok := m.HeightAt(x, z); !ok {
		t.Fatalf("result (%v,%v) off mesh", x, z)
	}
	if _, ok := m.HeightAt(toX, toZ); ok {
		t.Fatal("destination unexpectedly on mesh")
	}
	if math.Hypot(x-fromX, z-fromZ) < 1 {
		t.Fatalf("stuck at from: (%v,%v)", x, z)
	}
	if math.Hypot(x-toX, z-toZ) < 1 {
		t.Fatalf("reached far off-mesh to: (%v,%v)", x, z)
	}
}

func TestMoveOffMeshToOnMeshReaches(t *testing.T) {
	m := loadArena(t)
	x, z := m.Move(1000, 1000, 0, 0)
	if x != 0 || z != 0 {
		t.Fatalf("got (%v,%v), want on-mesh to", x, z)
	}
}

func TestMoveBothOffMeshStays(t *testing.T) {
	m := loadArena(t)
	x, z := m.Move(1000, 1000, 1100, 1100)
	if x != 1000 || z != 1000 {
		t.Fatalf("got (%v,%v), want from", x, z)
	}
}
