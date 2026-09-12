package navmesh

import (
	"math"
	"testing"
)

func TestFindPathOpenFloorIsTwoPoints(t *testing.T) {
	m := loadArena(t)
	path, ok := m.FindPath(0, 0, 0.5, 0)
	if !ok {
		t.Fatal("open floor path must be usable")
	}
	if len(path) != 2 {
		t.Fatalf("path=%v, want 2 points", path)
	}
	if math.Abs(path[0].X) > 1e-9 || math.Abs(path[0].Z) > 1e-9 {
		t.Fatalf("start=%v, want (0,0)", path[0])
	}
	if math.Abs(path[1].X-0.5) > 1e-9 || path[1].Z != 0 {
		t.Fatalf("end=%v, want (0.5,0)", path[1])
	}
}

func TestFindPathDoesNotTunnelAcrossHole(t *testing.T) {
	m := loadArena(t)
	fromX, fromZ := -22.0, 5.0
	toX, toZ := -21.0, 6.0
	if !m.ContainsXZ(fromX, fromZ) || !m.ContainsXZ(toX, toZ) {
		t.Fatal("hole endpoints must be on mesh")
	}
	midX, midZ := (fromX+toX)/2, (fromZ+toZ)/2
	if m.ContainsXZ(midX, midZ) {
		t.Fatal("midpoint must be off mesh")
	}

	path, ok := m.FindPath(fromX, fromZ, toX, toZ)
	if !ok || len(path) == 0 {
		t.Fatalf("FindPath=%v ok=%v", path, ok)
	}
	assertPathOnMesh(t, m, path)
	assertNoHoleTunnel(t, path, fromX, fromZ, toX, toZ, midX, midZ)

	last := path[len(path)-1]
	if math.Hypot(last.X-toX, last.Z-toZ) > 1e-3 {
		t.Fatalf("connected hole endpoints did not route around; ended at %v want (%v,%v)", last, toX, toZ)
	}
}

func TestFindPathBlockedIntoSolidHole(t *testing.T) {
	m := loadArena(t)
	fromX, fromZ := 6.0, 6.0
	toX, toZ := 7.0, 7.0
	if !m.ContainsXZ(fromX, fromZ) {
		t.Fatal("(6,6) must be on mesh")
	}
	if m.ContainsXZ(toX, toZ) {
		t.Fatal("(7,7) must be off mesh")
	}
	path, ok := m.FindPath(fromX, fromZ, toX, toZ)
	if !ok || len(path) < 1 {
		t.Fatalf("FindPath=%v ok=%v", path, ok)
	}
	end := path[len(path)-1]
	if !m.ContainsXZ(end.X, end.Z) {
		t.Fatalf("end off mesh %v", end)
	}
	if hypot2(end.X-toX, end.Z-toZ) < 1e-3 {
		t.Fatalf("reached off-mesh destination %v", end)
	}
	if hypot2(end.X-fromX, end.Z-fromZ) > 2 {
		t.Fatalf("slid too far past hole edge: %v", end)
	}
}

func assertPathOnMesh(t *testing.T, m *Mesh, path []PathPoint) {
	t.Helper()
	for i, p := range path {
		if !m.ContainsXZ(p.X, p.Z) {
			t.Fatalf("path[%d]=%v off mesh", i, p)
		}
	}
	for i := 0; i+1 < len(path); i++ {
		a, b := path[i], path[i+1]
		segMidX := (a.X + b.X) / 2
		segMidZ := (a.Z + b.Z) / 2
		onMid := m.ContainsXZ(segMidX, segMidZ)
		mx, mz := m.Move(a.X, a.Z, b.X, b.Z)
		moveReaches := hypot2(mx-b.X, mz-b.Z) <= 1e-3
		if !onMid && !moveReaches {
			t.Fatalf("segment %d→%d leaves mesh: mid off and Move stopped at (%v,%v) short of %v", i, i+1, mx, mz, b)
		}
	}
}

func assertNoHoleTunnel(t *testing.T, path []PathPoint, fromX, fromZ, toX, toZ, midX, midZ float64) {
	t.Helper()
	for i := 0; i+1 < len(path); i++ {
		a, b := path[i], path[i+1]
		segMidX := (a.X + b.X) / 2
		segMidZ := (a.Z + b.Z) / 2
		if math.Abs(segMidX-midX) < 1e-3 && math.Abs(segMidZ-midZ) < 1e-3 &&
			math.Abs(a.X-fromX) < 1e-3 && math.Abs(a.Z-fromZ) < 1e-3 &&
			math.Abs(b.X-toX) < 1e-3 && math.Abs(b.Z-toZ) < 1e-3 {
			t.Fatalf("tunneled hole chord %v→%v", a, b)
		}
	}
}
