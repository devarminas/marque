package navmesh

import (
	"container/heap"
	"math"
)

const (
	pathReachEps = 1e-6
	pathSnapEps  = 1e-3
)

type PathPoint struct {
	X float64
	Z float64
}

type portal struct {
	left  PathPoint
	right PathPoint
}

type adjEdge struct {
	poly   int
	portal portal
}

type pathGraph struct {
	adj      [][]adjEdge
	centroid []PathPoint
}

func (m *Mesh) ensurePathGraph() *pathGraph {
	if m == nil {
		return nil
	}
	m.graphOnce.Do(func() {
		m.pathGraph = buildPathGraph(m)
	})
	return m.pathGraph
}

func buildPathGraph(m *Mesh) *pathGraph {
	n := len(m.Polys)
	g := &pathGraph{
		adj:      make([][]adjEdge, n),
		centroid: make([]PathPoint, n),
	}
	type edgeKey struct{ a, b int }
	type edgeHit struct {
		poly int
		a, b int
	}
	seen := make(map[edgeKey]edgeHit, n*2)
	for i, p := range m.Polys {
		va, vb, vc := m.Vertices[p[0]], m.Vertices[p[1]], m.Vertices[p[2]]
		g.centroid[i] = PathPoint{
			X: (va.X + vb.X + vc.X) / 3,
			Z: (va.Z + vb.Z + vc.Z) / 3,
		}
		edges := [3][2]int{{p[0], p[1]}, {p[1], p[2]}, {p[2], p[0]}}
		for _, e := range edges {
			a, b := e[0], e[1]
			if a > b {
				a, b = b, a
			}
			key := edgeKey{a, b}
			if prev, ok := seen[key]; ok {
				g.adj[i] = append(g.adj[i], adjEdge{
					poly:   prev.poly,
					portal: portalFromCenter(m.Vertices[e[0]], m.Vertices[e[1]], g.centroid[i]),
				})
				g.adj[prev.poly] = append(g.adj[prev.poly], adjEdge{
					poly:   i,
					portal: portalFromCenter(m.Vertices[prev.a], m.Vertices[prev.b], g.centroid[prev.poly]),
				})
				delete(seen, key)
			} else {
				seen[key] = edgeHit{poly: i, a: e[0], b: e[1]}
			}
		}
	}
	return g
}

func portalFromCenter(va, vb Vec3, center PathPoint) portal {
	a := PathPoint{X: va.X, Z: va.Z}
	b := PathPoint{X: vb.X, Z: vb.Z}
	mid := PathPoint{X: (a.X + b.X) / 2, Z: (a.Z + b.Z) / 2}
	dir := PathPoint{X: mid.X - center.X, Z: mid.Z - center.Z}
	// Visual left of travel from the triangle center through the shared edge.
	if cross2(dir, PathPoint{X: a.X - center.X, Z: a.Z - center.Z}) > 0 {
		return portal{left: a, right: b}
	}
	return portal{left: b, right: a}
}

func (m *Mesh) FindPath(fromX, fromZ, toX, toZ float64) (path []PathPoint, ok bool) {
	if m == nil {
		return nil, false
	}
	from := PathPoint{X: fromX, Z: fromZ}
	to := PathPoint{X: toX, Z: toZ}

	startX, startZ, startPolys, startOn := m.locate(fromX, fromZ)
	endX, endZ, endPolys, endOn := m.locate(toX, toZ)
	mx, mz := m.Move(fromX, fromZ, toX, toZ)

	if startOn && hypot2(mx-toX, mz-toZ) < pathReachEps {
		return []PathPoint{from, to}, true
	}
	if !startOn && endOn && len(startPolys) == 0 {
		return []PathPoint{from, to}, true
	}

	if len(startPolys) > 0 && len(endPolys) > 0 {
		g := m.ensurePathGraph()
		if corridor, found := g.aStar(startPolys, endPolys); found {
			portals := make([]portal, 0, len(corridor))
			for i := 0; i+1 < len(corridor); i++ {
				portals = append(portals, portalBetween(g, corridor[i], corridor[i+1]))
			}
			start := PathPoint{X: startX, Z: startZ}
			end := PathPoint{X: endX, Z: endZ}
			portals = append(portals, portal{left: end, right: end})
			pulled := stringPull(start, portals)
			if startOn {
				pulled = prependPoint(from, pulled)
			} else {
				pulled = prependPoint(from, prependPoint(start, pulled))
			}
			if endOn {
				pulled = appendPoint(pulled, to)
			}
			pulled = compactPath(pulled)
			if len(pulled) < 2 {
				pulled = []PathPoint{from, to}
			}
			return pulled, pathUsable(pulled, to)
		}
	}

	clamped := clampPath(from, mx, mz)
	return clamped, pathUsable(clamped, to)
}

func clampPath(from PathPoint, mx, mz float64) []PathPoint {
	stop := PathPoint{X: mx, Z: mz}
	if hypot2(stop.X-from.X, stop.Z-from.Z) < pathReachEps {
		return []PathPoint{from}
	}
	return []PathPoint{from, stop}
}

func pathUsable(path []PathPoint, to PathPoint) bool {
	if len(path) == 0 {
		return false
	}
	last := path[len(path)-1]
	if hypot2(last.X-to.X, last.Z-to.Z) < pathReachEps {
		return true
	}
	return pathLength(path) > 0
}

func pathLength(path []PathPoint) float64 {
	var total float64
	for i := 1; i < len(path); i++ {
		total += hypot2(path[i].X-path[i-1].X, path[i].Z-path[i-1].Z)
	}
	return total
}

func compactPath(path []PathPoint) []PathPoint {
	if len(path) == 0 {
		return path
	}
	out := path[:1]
	for _, p := range path[1:] {
		prev := out[len(out)-1]
		if hypot2(p.X-prev.X, p.Z-prev.Z) > pathReachEps {
			out = append(out, p)
		}
	}
	return out
}

func prependPoint(p PathPoint, path []PathPoint) []PathPoint {
	if len(path) == 0 {
		return []PathPoint{p}
	}
	if hypot2(path[0].X-p.X, path[0].Z-p.Z) < pathReachEps {
		path[0] = p
		return path
	}
	return append([]PathPoint{p}, path...)
}

func appendPoint(path []PathPoint, p PathPoint) []PathPoint {
	if len(path) == 0 {
		return []PathPoint{p}
	}
	last := path[len(path)-1]
	if hypot2(last.X-p.X, last.Z-p.Z) < pathReachEps {
		path[len(path)-1] = p
		return path
	}
	return append(path, p)
}

func (m *Mesh) locate(x, z float64) (sx, sz float64, polys []int, on bool) {
	for i, p := range m.Polys {
		a := m.Vertices[p[0]]
		b := m.Vertices[p[1]]
		c := m.Vertices[p[2]]
		if _, _, _, inside := barycentricXZ(x, z, a, b, c); inside {
			polys = append(polys, i)
		}
	}
	if len(polys) > 0 {
		return x, z, polys, true
	}
	best := math.Inf(1)
	bestPoly := -1
	var bx, bz float64
	for i, p := range m.Polys {
		a := m.Vertices[p[0]]
		b := m.Vertices[p[1]]
		c := m.Vertices[p[2]]
		px, pz, d2 := closestOnTriangleXZ(x, z, a, b, c)
		if d2 < best {
			best = d2
			bestPoly = i
			bx, bz = px, pz
		}
	}
	if bestPoly < 0 || best > pathSnapEps*pathSnapEps {
		return x, z, nil, false
	}
	return bx, bz, []int{bestPoly}, false
}

func closestOnTriangleXZ(px, pz float64, a, b, c Vec3) (x, z, d2 float64) {
	if _, _, _, ok := barycentricXZ(px, pz, a, b, c); ok {
		return px, pz, 0
	}
	x1, z1, d1 := closestOnSegment(px, pz, a.X, a.Z, b.X, b.Z)
	x2, z2, d2s := closestOnSegment(px, pz, b.X, b.Z, c.X, c.Z)
	x3, z3, d3 := closestOnSegment(px, pz, c.X, c.Z, a.X, a.Z)
	x, z, d2 = x1, z1, d1
	if d2s < d2 {
		x, z, d2 = x2, z2, d2s
	}
	if d3 < d2 {
		x, z, d2 = x3, z3, d3
	}
	return
}

func closestOnSegment(px, pz, ax, az, bx, bz float64) (x, z, d2 float64) {
	dx, dz := bx-ax, bz-az
	len2 := dx*dx + dz*dz
	if len2 < 1e-24 {
		x, z = ax, az
		d2 = (px-ax)*(px-ax) + (pz-az)*(pz-az)
		return
	}
	t := ((px-ax)*dx + (pz-az)*dz) / len2
	if t < 0 {
		t = 0
	} else if t > 1 {
		t = 1
	}
	x = ax + t*dx
	z = az + t*dz
	d2 = (px-x)*(px-x) + (pz-z)*(pz-z)
	return
}

func portalBetween(g *pathGraph, a, b int) portal {
	for _, e := range g.adj[a] {
		if e.poly == b {
			return e.portal
		}
	}
	ca, cb := g.centroid[a], g.centroid[b]
	mid := PathPoint{X: (ca.X + cb.X) / 2, Z: (ca.Z + cb.Z) / 2}
	return portal{left: mid, right: mid}
}

type astarNode struct {
	poly int
	g, f float64
	idx  int
}

type astarHeap []*astarNode

func (h astarHeap) Len() int           { return len(h) }
func (h astarHeap) Less(i, j int) bool { return h[i].f < h[j].f }
func (h astarHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].idx = i
	h[j].idx = j
}
func (h *astarHeap) Push(x any) {
	n := x.(*astarNode)
	n.idx = len(*h)
	*h = append(*h, n)
}
func (h *astarHeap) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	old[n-1] = nil
	item.idx = -1
	*h = old[:n-1]
	return item
}

func (g *pathGraph) aStar(starts, goals []int) ([]int, bool) {
	n := len(g.centroid)
	if len(starts) == 0 || len(goals) == 0 || n == 0 {
		return nil, false
	}
	isGoal := make([]bool, n)
	for _, goal := range goals {
		if goal >= 0 && goal < n {
			isGoal[goal] = true
		}
	}
	came := make([]int, n)
	gScore := make([]float64, n)
	closed := make([]bool, n)
	for i := range came {
		came[i] = -1
		gScore[i] = math.Inf(1)
	}
	open := &astarHeap{}
	heap.Init(open)
	inOpen := make([]*astarNode, n)
	goalHint := g.centroid[goals[0]]
	for _, start := range starts {
		if start < 0 || start >= n {
			continue
		}
		gScore[start] = 0
		node := &astarNode{
			poly: start,
			g:    0,
			f:    hypot2(g.centroid[start].X-goalHint.X, g.centroid[start].Z-goalHint.Z),
		}
		heap.Push(open, node)
		inOpen[start] = node
	}
	if open.Len() == 0 {
		return nil, false
	}

	for open.Len() > 0 {
		cur := heap.Pop(open).(*astarNode)
		inOpen[cur.poly] = nil
		if isGoal[cur.poly] {
			return reconstruct(came, cur.poly), true
		}
		if closed[cur.poly] {
			continue
		}
		closed[cur.poly] = true
		for _, e := range g.adj[cur.poly] {
			if closed[e.poly] {
				continue
			}
			step := hypot2(g.centroid[cur.poly].X-g.centroid[e.poly].X, g.centroid[cur.poly].Z-g.centroid[e.poly].Z)
			tentative := gScore[cur.poly] + step
			if tentative >= gScore[e.poly] {
				continue
			}
			came[e.poly] = cur.poly
			gScore[e.poly] = tentative
			f := tentative + hypot2(g.centroid[e.poly].X-goalHint.X, g.centroid[e.poly].Z-goalHint.Z)
			if node := inOpen[e.poly]; node != nil {
				node.g = tentative
				node.f = f
				heap.Fix(open, node.idx)
			} else {
				node := &astarNode{poly: e.poly, g: tentative, f: f}
				heap.Push(open, node)
				inOpen[e.poly] = node
			}
		}
	}
	return nil, false
}

func reconstruct(came []int, goal int) []int {
	out := []int{goal}
	for cur := goal; came[cur] >= 0; cur = came[cur] {
		out = append(out, came[cur])
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

func stringPull(start PathPoint, portals []portal) []PathPoint {
	if len(portals) == 0 {
		return []PathPoint{start}
	}
	all := make([]portal, 0, len(portals)+1)
	all = append(all, portal{left: start, right: start})
	all = append(all, portals...)

	path := []PathPoint{start}
	apex := all[0].left
	left, right := all[0].left, all[0].right
	apexIdx, leftIdx, rightIdx := 0, 0, 0

	for i := 1; i < len(all); i++ {
		pLeft, pRight := all[i].left, all[i].right
		if triArea2(apex, right, pRight) <= 0 {
			if pointsEqual(apex, right) || triArea2(apex, left, pRight) > 0 {
				right = pRight
				rightIdx = i
			} else {
				path = append(path, left)
				apex = left
				apexIdx = leftIdx
				left, right = apex, apex
				leftIdx, rightIdx = apexIdx, apexIdx
				i = apexIdx
				continue
			}
		}
		if triArea2(apex, left, pLeft) >= 0 {
			if pointsEqual(apex, left) || triArea2(apex, right, pLeft) < 0 {
				left = pLeft
				leftIdx = i
			} else {
				path = append(path, right)
				apex = right
				apexIdx = rightIdx
				left, right = apex, apex
				leftIdx, rightIdx = apexIdx, apexIdx
				i = apexIdx
				continue
			}
		}
	}
	end := all[len(all)-1].left
	if !pointsEqual(path[len(path)-1], end) {
		path = append(path, end)
	}
	return path
}

func pointsEqual(a, b PathPoint) bool {
	return hypot2(a.X-b.X, a.Z-b.Z) < pathReachEps
}

func hypot2(dx, dz float64) float64 {
	return math.Hypot(dx, dz)
}

func cross2(a, b PathPoint) float64 {
	return a.X*b.Z - a.Z*b.X
}

func triArea2(a, b, c PathPoint) float64 {
	// Recast/Detour XZ sign so the published funnel inequalities stay valid.
	return (c.X-a.X)*(b.Z-a.Z) - (b.X-a.X)*(c.Z-a.Z)
}
