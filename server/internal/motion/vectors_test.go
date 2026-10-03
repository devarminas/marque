package motion

import (
	"bufio"
	"fmt"
	"github.com/devarminas/marque/server/internal/navmesh"
	"math"
	"os"
	"strings"
	"testing"
)

func fixtures(t *testing.T) map[string]*navmesh.Mesh {
	t.Helper()
	f, e := os.Open("../../../shared/motion/meshes.txt")
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	meshes := map[string]*navmesh.Mesh{}
	var m *navmesh.Mesh
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		line := scan.Text()
		var tag, name string
		fmt.Sscan(line, &tag)
		switch tag {
		case "mesh":
			fmt.Sscan(line, &tag, &name)
			m = &navmesh.Mesh{}
			meshes[name] = m
		case "v":
			var v navmesh.Vec3
			if _, e := fmt.Sscan(line, &tag, &v.X, &v.Y, &v.Z); e != nil {
				t.Fatal(e)
			}
			m.Vertices = append(m.Vertices, v)
		case "t":
			var tri [3]int
			if _, e := fmt.Sscan(line, &tag, &tri[0], &tri[1], &tri[2]); e != nil {
				t.Fatal(e)
			}
			m.Polys = append(m.Polys, tri)
		}
	}
	if e := scan.Err(); e != nil {
		t.Fatal(e)
	}
	return meshes
}
func TestSharedMotionVectors(t *testing.T) {
	meshes := fixtures(t)
	f, e := os.Open("../../../shared/motion/vectors.txt")
	if e != nil {
		t.Fatal(e)
	}
	defer f.Close()
	scan := bufio.NewScanner(f)
	count := 0
	for scan.Scan() {
		var name, mapName string
		var n, mode, repeat int
		var end uint32
		var s, want State
		var input Input
		_, e := fmt.Fscan(strings.NewReader(scan.Text()), &name, &mapName, &n, &s.X, &s.Y, &s.Z, &s.VY, &s.DX, &s.DZ, &input.DX, &input.DZ, &input.Jump, &mode, &end, &repeat, &want.X, &want.Y, &want.Z, &want.VY, &want.DX, &want.DZ)
		if e != nil {
			t.Fatal(e)
		}
		t.Run(name, func(t *testing.T) {
			m := Map{HalfExtent: 128}
			if mapName != "flat" {
				m.Mesh = meshes[mapName]
			}
			policy := Policy{Mode: Mode(mode), EndTick: end}
			for i := 0; i < n; i++ {
				if i == 0 || repeat != 0 {
					s, policy, _ = Apply(s, m, policy, input, uint32(i))
					input.Jump = false
				}
				s = Step(s, m, 0.04)
			}
			got := []float64{s.X, s.Y, s.Z, s.VY, s.DX, s.DZ}
			expected := []float64{want.X, want.Y, want.Z, want.VY, want.DX, want.DZ}
			tolerance := 1e-9
			if n > 100 { tolerance = 1e-7 }
			for i, v := range got {
				if math.Abs(v-expected[i]) > tolerance {
					t.Fatalf("field%d got%.15g want%.15g", i, v, expected[i])
				}
			}
		})
		count++
	}
	if e := scan.Err(); e != nil {
		t.Fatal(e)
	}
	if count != 20 {
		t.Fatalf("vectors%d want20", count)
	}
}

func TestMeshHoleAndHeightTie(t *testing.T) {
	meshes := fixtures(t)
	x, z := meshes["hole"].Move(0.5, 0.5, 2.5, 0.5)
	if math.Abs(x-1) > 1e-9 || z != 0.5 {
		t.Fatalf("hole %.15g %.15g", x, z)
	}
	y, ok := meshes["stack"].HeightAt(0, 0, 1)
	if !ok || y != 0 {
		t.Fatalf("height tie %v %v", y, ok)
	}
}
