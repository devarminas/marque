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

func TestNavSteerBlockedOffMesh(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	alice := pw.join()
	alice.pos = Point{X: 0, Z: 0}
	alice.y = pw.w.groundYAt(0, 0)

	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 0)
	for range 2000 {
		before := alice.pos
		pw.w.step()
		if alice.pos == before {
			break
		}
	}
	if _, ok := mesh.HeightAt(alice.pos.X, alice.pos.Z); !ok {
		t.Fatalf("steer left mesh at %v", alice.pos)
	}
	if math.Hypot(alice.pos.X, alice.pos.Z) > 90 {
		t.Fatalf("walked through wall to %v", alice.pos)
	}
}

func TestNavFloorHeightAtSpawn(t *testing.T) {
	pw := newProbeWorld(t)
	mesh := loadArenaNav(t)
	pw.w.SetNav(mesh)

	y, ok := mesh.HeightAt(0, 0)
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
