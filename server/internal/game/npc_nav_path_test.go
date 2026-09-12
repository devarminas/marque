package game

import (
	"math"
	"testing"

	"github.com/devarminas/marque/server/internal/navmesh"
)

func TestNPCPathStaysOnMeshAcrossHole(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	imp := &npc{
		id:   9001,
		kind: KindImp,
		hp:   ImpMaxHP,
		home: Point{X: -22, Z: 5},
		pos:  Point{X: -22, Z: 5},
	}
	pw.w.npcs[imp.id] = imp
	pw.w.npcOrder = append(pw.w.npcOrder, imp.id)

	dest := Point{X: -21, Z: 6}
	mid := Point{X: (imp.pos.X + dest.X) / 2, Z: (imp.pos.Z + dest.Z) / 2}
	if mesh.ContainsXZ(mid.X, mid.Z) {
		t.Fatal("straight mid must be off mesh")
	}

	pw.w.assignNPCPath(imp, dest)
	if len(imp.remaining) == 0 {
		t.Fatal("expected path remaining after assign")
	}
	points := append([]Point{imp.pos}, imp.remaining...)
	assertGamePathOnMesh(t, mesh, points)
	assertGameNoHoleTunnel(t, points, imp.pos, dest, mid)
}

func TestImpChaseDoesNotTunnelHole(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	alice := pw.join()
	imp := &npc{
		id:     9002,
		kind:   KindImp,
		hp:     ImpMaxHP,
		home:   Point{X: -22, Z: 5},
		pos:    Point{X: -22, Z: 5},
		phase:  phaseCombat,
		target: alice.id,
	}
	pw.w.npcs[imp.id] = imp
	pw.w.npcOrder = append(pw.w.npcOrder, imp.id)

	alice.pos = Point{X: -20.5, Z: 6.5}
	alice.y = 8.4
	holeFrom := Point{X: -22, Z: 5}
	holeTo := Point{X: -21, Z: 6}
	holeMid := Point{X: (holeFrom.X + holeTo.X) / 2, Z: (holeFrom.Z + holeTo.Z) / 2}
	if mesh.ContainsXZ(holeMid.X, holeMid.Z) {
		t.Fatal("hole mid must be off mesh")
	}
	if !mesh.ContainsXZ(imp.pos.X, imp.pos.Z) || !mesh.ContainsXZ(alice.pos.X, alice.pos.Z) {
		t.Fatal("chase endpoints must be on mesh")
	}
	if distanceBetween(imp.pos, alice.pos) <= AttackRange {
		t.Fatal("player must sit beyond melee so chase assigns a path")
	}

	navPath, _ := mesh.FindPath(imp.pos.X, imp.pos.Z, alice.pos.X, alice.pos.Z)
	navReach := len(navPath) > 0 && math.Hypot(navPath[len(navPath)-1].X-alice.pos.X, navPath[len(navPath)-1].Z-alice.pos.Z) <= 1e-3

	var recorded []Point
	for range 300 {
		recorded = append(recorded, imp.pos)
		recorded = append(recorded, imp.remaining...)
		if !mesh.ContainsXZ(imp.pos.X, imp.pos.Z) {
			t.Fatalf("imp left mesh at %v", imp.pos)
		}
		if math.Hypot(imp.pos.X-holeMid.X, imp.pos.Z-holeMid.Z) < 1e-3 {
			t.Fatalf("imp occupied hole mid %v", imp.pos)
		}
		pw.w.step()
	}

	for _, ev := range pw.events(EvPathAssigned) {
		raw, _ := ev["points"].([]any)
		for _, item := range raw {
			arr, _ := item.([]any)
			if len(arr) < 2 {
				continue
			}
			x, _ := arr[0].(float64)
			z, _ := arr[1].(float64)
			recorded = append(recorded, Point{X: x, Z: z})
		}
	}

	assertGamePathOnMesh(t, mesh, recorded)
	for i := 0; i+1 < len(recorded); i++ {
		if tunnelsHoleChord(recorded[i], recorded[i+1], holeFrom, holeTo, holeMid) {
			t.Fatalf("recorded segment tunneled hole %v→%v", recorded[i], recorded[i+1])
		}
	}
	if !navReach && distanceBetween(imp.pos, alice.pos) <= 1e-3 {
		t.Fatalf("imp ended at player %v though FindPath cannot reach", imp.pos)
	}
}

func TestImpCannotReachThroughOffMeshGap(t *testing.T) {
	pw := newClassProbe(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	alice := pw.joinWithClass("knight")
	imp := &npc{
		id:     9003,
		kind:   KindImp,
		hp:     ImpMaxHP,
		home:   Point{X: 6, Z: 6},
		pos:    Point{X: 6, Z: 6},
		phase:  phaseCombat,
		target: alice.id,
	}
	pw.w.npcs[imp.id] = imp
	pw.w.npcOrder = append(pw.w.npcOrder, imp.id)

	alice.pos = Point{X: 7, Z: 7}
	alice.y = ArenaFloorY
	if mesh.ContainsXZ(alice.pos.X, alice.pos.Z) {
		t.Fatal("player must sit in off-mesh hole")
	}
	if !mesh.ContainsXZ(imp.pos.X, imp.pos.Z) {
		t.Fatal("imp must start on mesh")
	}

	for range 200 {
		pw.w.step()
		if !mesh.ContainsXZ(imp.pos.X, imp.pos.Z) {
			t.Fatalf("imp left mesh at %v", imp.pos)
		}
		if imp.pos == alice.pos {
			t.Fatalf("imp occupied off-mesh player cell %v", imp.pos)
		}
	}
	if math.Hypot(imp.pos.X-alice.pos.X, imp.pos.Z-alice.pos.Z) < 0.05 {
		t.Fatalf("imp overlapped player through gap at %v", imp.pos)
	}
}

func TestNilNavStillStraightLine(t *testing.T) {
	pw := newProbeWorld(t)
	if pw.w.nav != nil {
		t.Fatal("probe world should start without nav")
	}
	imp := &npc{id: 1, pos: Point{X: 0, Z: 0}}
	points, assign := pw.w.npcDestinationPath(imp, Point{X: 3, Z: 0})
	if !assign || len(points) != 2 {
		t.Fatalf("points=%v assign=%v", points, assign)
	}
	if points[0] != (Point{X: 0, Z: 0}) || points[1] != (Point{X: 3, Z: 0}) {
		t.Fatalf("want straight (0,0)→(3,0), got %v", points)
	}
}

func assertGamePathOnMesh(t *testing.T, mesh *navmesh.Mesh, points []Point) {
	t.Helper()
	for i, p := range points {
		if !mesh.ContainsXZ(p.X, p.Z) {
			t.Fatalf("path[%d]=%v off mesh", i, p)
		}
	}
	for i := 0; i+1 < len(points); i++ {
		a, b := points[i], points[i+1]
		midOn := mesh.ContainsXZ((a.X+b.X)/2, (a.Z+b.Z)/2)
		mx, mz := mesh.Move(a.X, a.Z, b.X, b.Z)
		if !midOn && math.Hypot(mx-b.X, mz-b.Z) > 1e-3 {
			t.Fatalf("segment %d leaves mesh at (%v,%v) short of %v", i, mx, mz, b)
		}
	}
}

func assertGameNoHoleTunnel(t *testing.T, points []Point, from, to, mid Point) {
	t.Helper()
	for i := 0; i+1 < len(points); i++ {
		if tunnelsHoleChord(points[i], points[i+1], from, to, mid) {
			t.Fatalf("tunneled hole mid via segment %d", i)
		}
	}
}

func tunnelsHoleChord(a, b, from, to, mid Point) bool {
	segMid := Point{X: (a.X + b.X) / 2, Z: (a.Z + b.Z) / 2}
	return math.Abs(segMid.X-mid.X) < 1e-3 && math.Abs(segMid.Z-mid.Z) < 1e-3 &&
		math.Abs(a.X-from.X) < 1e-3 && math.Abs(a.Z-from.Z) < 1e-3 &&
		math.Abs(b.X-to.X) < 1e-3 && math.Abs(b.Z-to.Z) < 1e-3
}
