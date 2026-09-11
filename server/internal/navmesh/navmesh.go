package navmesh

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
)

const RelPath = "shared/maps/arena_ring_of_trials_nav.json"

const moveSearchIters = 24

type Vec3 struct {
	X, Y, Z float64
}

type Mesh struct {
	Vertices []Vec3
	Polys    [][3]int
}

type fileMesh struct {
	Vertices [][]float64 `json:"vertices"`
	Polygons [][]int     `json:"polygons"`
}

func LoadJSON(path string) (*Mesh, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("navmesh: read %s: %w", path, err)
	}
	var file fileMesh
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, fmt.Errorf("navmesh: parse %s: %w", path, err)
	}
	m := &Mesh{
		Vertices: make([]Vec3, len(file.Vertices)),
		Polys:    make([][3]int, 0, len(file.Polygons)),
	}
	for i, v := range file.Vertices {
		if len(v) != 3 {
			return nil, fmt.Errorf("navmesh: vertex %d has %d components, want 3", i, len(v))
		}
		m.Vertices[i] = Vec3{X: v[0], Y: v[1], Z: v[2]}
	}
	n := len(m.Vertices)
	for i, p := range file.Polygons {
		if len(p) != 3 {
			return nil, fmt.Errorf("navmesh: polygon %d has %d indices, want 3", i, len(p))
		}
		a, b, c := p[0], p[1], p[2]
		if a < 0 || b < 0 || c < 0 || a >= n || b >= n || c >= n {
			return nil, fmt.Errorf("navmesh: polygon %d out of range indices %v (n=%d)", i, p, n)
		}
		m.Polys = append(m.Polys, [3]int{a, b, c})
	}
	return m, nil
}

func (m *Mesh) ContainsXZ(x, z float64) bool {
	_, ok := m.HeightAt(x, z, 0)
	return ok
}

func (m *Mesh) HeightAt(x, z, nearY float64) (y float64, ok bool) {
	if m == nil {
		return 0, false
	}
	best := 0.0
	bestDist := math.Inf(1)
	found := false
	for _, p := range m.Polys {
		a := m.Vertices[p[0]]
		b := m.Vertices[p[1]]
		c := m.Vertices[p[2]]
		u, v, w, inside := barycentricXZ(x, z, a, b, c)
		if !inside {
			continue
		}
		hy := u*a.Y + v*b.Y + w*c.Y
		d := math.Abs(hy - nearY)
		if !found || d < bestDist {
			best = hy
			bestDist = d
			found = true
		}
	}
	return best, found
}

func (m *Mesh) Move(fromX, fromZ, toX, toZ float64) (x, z float64) {
	if m == nil {
		return toX, toZ
	}
	if !m.ContainsXZ(fromX, fromZ) {
		if m.ContainsXZ(toX, toZ) {
			return toX, toZ
		}
		return fromX, fromZ
	}
	dx := toX - fromX
	dz := toZ - fromZ
	dist := math.Hypot(dx, dz)
	if dist < 1e-12 {
		return fromX, fromZ
	}
	steps := int(dist * 8)
	if steps < moveSearchIters {
		steps = moveSearchIters
	}
	if steps > 512 {
		steps = 512
	}
	lastOn := 0.0
	for i := 1; i <= steps; i++ {
		t := float64(i) / float64(steps)
		mx := fromX + dx*t
		mz := fromZ + dz*t
		if m.ContainsXZ(mx, mz) {
			lastOn = t
			continue
		}
		lo, hi := lastOn, t
		for range moveSearchIters {
			mid := (lo + hi) * 0.5
			if m.ContainsXZ(fromX+dx*mid, fromZ+dz*mid) {
				lo = mid
			} else {
				hi = mid
			}
		}
		return fromX + dx*lo, fromZ + dz*lo
	}
	return toX, toZ
}

func barycentricXZ(px, pz float64, a, b, c Vec3) (u, v, w float64, ok bool) {
	v0x := b.X - a.X
	v0z := b.Z - a.Z
	v1x := c.X - a.X
	v1z := c.Z - a.Z
	v2x := px - a.X
	v2z := pz - a.Z
	den := v0x*v1z - v1x*v0z
	if math.Abs(den) < 1e-12 {
		return 0, 0, 0, false
	}
	v = (v2x*v1z - v1x*v2z) / den
	w = (v0x*v2z - v2x*v0z) / den
	u = 1 - v - w
	const eps = -1e-9
	if u < eps || v < eps || w < eps {
		return 0, 0, 0, false
	}
	return u, v, w, true
}
