package game

import (
	"math"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/devarminas/marque/server/internal/navmesh"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func loadArenaNav(t *testing.T) *navmesh.Mesh {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	m, err := navmesh.LoadJSON(filepath.Join(root, filepath.FromSlash(navmesh.RelPath)))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestNavSteerOpenShortWalk(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	alice := pw.join()
	alice.pos = Point{X: 0, Z: 0}
	alice.y = pw.w.groundYAt(0, 0, 0)

	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 0)
	pw.w.step()
	if alice.pos.X <= 0 {
		t.Fatalf("open walk did not advance: %v", alice.pos)
	}
	if !mesh.ContainsXZ(alice.pos.X, alice.pos.Z) {
		t.Fatalf("open walk left mesh at %v", alice.pos)
	}
}

func TestNavSteerBlockedOffMesh(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	alice := pw.join()
	alice.pos = Point{X: 0, Z: 0}
	alice.y = pw.w.groundYAt(0, 0, 0)

	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 0)
	for range 2000 {
		before := alice.pos
		pw.w.step()
		if alice.pos == before {
			break
		}
	}
	if !mesh.ContainsXZ(alice.pos.X, alice.pos.Z) {
		t.Fatalf("steer left mesh at %v", alice.pos)
	}
	if math.Hypot(alice.pos.X, alice.pos.Z) > 90 {
		t.Fatalf("walked through wall to %v", alice.pos)
	}
}

func TestNavSteerBlockedIntoHole(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	alice := pw.join()
	alice.pos = Point{X: 6, Z: 6}
	alice.y = pw.w.groundYAt(6, 6, 0)
	if !mesh.ContainsXZ(6, 6) {
		t.Fatal("(6,6) must be on mesh")
	}
	if mesh.ContainsXZ(7, 7) {
		t.Fatal("(7,7) must be off mesh (solid hole)")
	}

	pw.w.move(alice, mnet.Move{DX: 1, DZ: 1}, 0)
	for range 100 {
		before := alice.pos
		pw.w.step()
		if alice.pos == before {
			break
		}
	}
	if !mesh.ContainsXZ(alice.pos.X, alice.pos.Z) {
		t.Fatalf("steer left mesh at %v", alice.pos)
	}
	if alice.pos.X >= 7-1e-3 && alice.pos.Z >= 7-1e-3 {
		t.Fatalf("tunneled into/through hole to %v", alice.pos)
	}
	if math.Hypot(alice.pos.X-6, alice.pos.Z-6) > 2 {
		t.Fatalf("slid too far past hole edge: %v", alice.pos)
	}
}

func TestNavFloorHeightAtSpawn(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	y, ok := mesh.HeightAt(0, 0, 0)
	if !ok {
		t.Fatal("(0,0) off mesh")
	}

	alice := pw.join()
	alice.pos = Point{X: 0, Z: 0}
	alice.y = 0
	pw.w.stepVertical(alice, 0)
	if math.Abs(alice.y-y) > GroundEpsilon {
		t.Fatalf("grounded snap y=%v, want HeightAt %v", alice.y, y)
	}
}

func TestNavRampWalkChangesY(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	startY, ok := mesh.HeightAt(-4, 14, 0)
	if !ok {
		t.Fatal("ramp foot (-4,14) off mesh")
	}
	alice := pw.join()
	alice.pos = Point{X: -4, Z: 14}
	alice.y = startY

	pw.w.move(alice, mnet.Move{DX: 0, DZ: 1}, 0)
	lastY := alice.y
	rose := false
	for range 40 {
		pw.w.step()
		if !mesh.ContainsXZ(alice.pos.X, alice.pos.Z) {
			t.Fatalf("ramp walk left mesh at %v y=%v", alice.pos, alice.y)
		}
		wantY := pw.w.groundYAt(alice.pos.X, alice.pos.Z, alice.y)
		if math.Abs(alice.y-wantY) > GroundEpsilon {
			t.Fatalf("y=%v float/sink vs HeightAt %v at %v", alice.y, wantY, alice.pos)
		}
		if alice.y > lastY+1e-4 {
			rose = true
		}
		lastY = alice.y
	}
	if !rose {
		t.Fatalf("ramp walk never raised Y (end y=%v at %v)", alice.y, alice.pos)
	}
}

func TestNavStackedFloorKeepsLowDeck(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	alice := pw.join()
	alice.pos = Point{X: -6.5, Z: -8.5}
	low, ok := mesh.HeightAt(-6.5, -8.5, 0.4)
	if !ok || low > 1 {
		t.Fatalf("expected low floor start, got ok=%v y=%v", ok, low)
	}
	alice.y = low

	pw.w.move(alice, mnet.Move{DX: -1, DZ: 0}, 0)
	for range 40 {
		pw.w.step()
	}
	if alice.y > 2 {
		t.Fatalf("floor walk snapped toward upper deck y=%v at %v", alice.y, alice.pos)
	}
	if !mesh.ContainsXZ(alice.pos.X, alice.pos.Z) {
		t.Fatalf("left mesh at %v", alice.pos)
	}
}

func TestNavJumpLandsAtLocalGround(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	gx, gz := -20.0, -50.0
	gy, ok := mesh.HeightAt(gx, gz, 5.8)
	if !ok {
		t.Fatal("elevated sample off mesh")
	}
	if gy < 1 {
		t.Fatalf("expected elevated ground, got y=%v", gy)
	}

	alice := pw.join()
	alice.pos = Point{X: gx, Z: gz}
	alice.y = gy
	pw.w.move(alice, mnet.Move{Jump: true}, 0)
	if alice.vy != JumpSpeed {
		t.Fatalf("vy=%v, want JumpSpeed", alice.vy)
	}

	landed := false
	for range 200 {
		pw.w.step()
		if pw.w.grounded(alice) {
			landed = true
			break
		}
	}
	if !landed {
		t.Fatalf("never landed: y=%v vy=%v", alice.y, alice.vy)
	}
	if math.Abs(alice.y-gy) > GroundEpsilon || alice.vy != 0 {
		t.Fatalf("land y=%v vy=%v, want local ground %v", alice.y, alice.vy, gy)
	}
	if math.Abs(alice.y) < 1 {
		t.Fatalf("landed near y=0 (%v), want elevated local ground", alice.y)
	}
}
