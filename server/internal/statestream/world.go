package statestream

import (
	"cmp"
	"fmt"
	"math"

	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

type component uint8

const (
	compTransform component = iota
	compVitals
	compGear
	compCast
	compLook
	numComponents
)

type mask uint8

func (m mask) has(c component) bool { return m&(1<<c) != 0 }

func maskOf(set [numComponents]bool) mask {
	var m mask
	for c, on := range set {
		if on {
			m |= 1 << c
		}
	}
	return m
}

type Entity struct {
	id        wire.EntityId
	transform wire.Transform
	vitals    codec.Opt[wire.Vitals]
	gear      codec.Opt[wire.Gear]
	cast      codec.Opt[wire.CastBar]
	look      codec.Opt[wire.Look]
}

func Player(id wire.PlayerId, t wire.Transform, v wire.Vitals, g wire.Gear, c wire.CastBar) Entity {
	return Entity{id: id, transform: t, vitals: codec.Some(v), gear: codec.Some(g), cast: codec.Some(c)}
}

func Npc(id wire.NpcId, t wire.Transform, v wire.Vitals, c wire.CastBar, l wire.Look) Entity {
	return Entity{id: id, transform: t, vitals: codec.Some(v), cast: codec.Some(c), look: codec.Some(l)}
}

func Item(id wire.ItemId, t wire.Transform, l wire.Look) Entity {
	return Entity{id: id, transform: t, look: codec.Some(l)}
}

func Node(id wire.NodeId, t wire.Transform, l wire.Look) Entity {
	return Entity{id: id, transform: t, look: codec.Some(l)}
}

func isSome[T any](o codec.Opt[T]) bool {
	_, ok := o.Get()
	return ok
}

const allComponents mask = (1 << numComponents) - 1

func (e Entity) differs(o Entity) mask {
	return maskOf([numComponents]bool{
		compTransform: e.transform != o.transform,
		compVitals:    e.vitals != o.vitals,
		compGear:      e.gear != o.gear,
		compCast:      e.cast != o.cast,
		compLook:      e.look != o.look,
	})
}

func (e Entity) message(m mask) (wire.Entity, error) {
	f := wire.EntityFields{Id: e.id}
	if m.has(compTransform) {
		f.Transform = codec.Some(e.transform)
	}
	if m.has(compVitals) {
		f.Vitals = codec.Some(must(wire.VitalsUpdateFields{Value: e.vitals}.Build()))
	}
	if m.has(compGear) {
		f.Gear = codec.Some(must(wire.GearUpdateFields{Value: e.gear}.Build()))
	}
	if m.has(compCast) {
		f.Cast = codec.Some(must(wire.CastUpdateFields{Value: e.cast}.Build()))
	}
	if m.has(compLook) {
		f.Look = codec.Some(must(wire.LookUpdateFields{Value: e.look}.Build()))
	}
	return f.Build()
}

type Fact struct {
	names []wire.EntityId
	tick  uint32
	msg   wire.StateMsg
}

func SwingFact(m wire.Swing) Fact {
	return Fact{names: []wire.EntityId{entityOf(m.Attacker()), entityOf(m.Target())}, tick: m.Tick(), msg: m}
}

func CastFact(m wire.CastPhase) Fact {
	names := []wire.EntityId{entityOf(m.Caster())}
	if t, ok := m.Target().Get(); ok {
		names = append(names, entityOf(t))
	}
	return Fact{names: names, tick: m.Tick(), msg: m}
}

func GatherFact(m wire.GatherStart) Fact {
	return Fact{names: []wire.EntityId{m.Player(), m.Node()}, tick: m.Tick(), msg: m}
}

func entityOf(c wire.CombatantId) wire.EntityId {
	switch v := c.(type) {
	case wire.PlayerId:
		return v
	case wire.NpcId:
		return v
	}
	return nil
}

func kindOf(id wire.EntityId) int {
	switch id.(type) {
	case wire.PlayerId:
		return 1
	case wire.NpcId:
		return 2
	case wire.ItemId:
		return 3
	case wire.NodeId:
		return 4
	}
	return 0
}

func handleOf(id wire.EntityId) (index, gen uint32) {
	switch v := id.(type) {
	case wire.PlayerId:
		return v.Index, v.Gen
	case wire.NpcId:
		return v.Index, v.Gen
	case wire.ItemId:
		return v.Index, v.Gen
	case wire.NodeId:
		return v.Index, v.Gen
	}
	return 0, 0
}

func compareIds(a, b wire.EntityId) int {
	ai, ag := handleOf(a)
	bi, bg := handleOf(b)
	return cmp.Or(cmp.Compare(kindOf(a), kindOf(b)), cmp.Compare(ai, bi), cmp.Compare(ag, bg))
}

type Frame struct {
	Tick     uint32
	Entities []Entity
	Facts    []Fact
}

type cell struct{ x, z int64 }

type record struct {
	entity  Entity
	changed [numComponents]uint32
	cell    cell
	cache   map[mask][]byte
}

type sharedFact struct {
	names []wire.EntityId
	tick  uint32
	bytes []byte
}

type World struct {
	cfg     Config
	tick    uint32
	records map[wire.EntityId]*record
	grid    map[cell][]wire.EntityId
	facts   []*sharedFact
}

func NewWorld(cfg Config) (*World, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &World{cfg: cfg, records: map[wire.EntityId]*record{}, grid: map[cell][]wire.EntityId{}}, nil
}

func (w *World) Tick() uint32 { return w.tick }

func (w *World) Commit(f Frame) error {
	if f.Tick <= w.tick {
		return fmt.Errorf("statestream: frame tick %d does not follow tick %d", f.Tick, w.tick)
	}
	next := make(map[wire.EntityId]*record, len(f.Entities))
	for _, e := range f.Entities {
		if kindOf(e.id) == 0 {
			return fmt.Errorf("statestream: entity with no id in frame %d", f.Tick)
		}
		if next[e.id] != nil {
			return fmt.Errorf("statestream: entity %v twice in frame %d", e.id, f.Tick)
		}
		r := &record{entity: e, cell: w.cellOf(e.transform)}
		touched := allComponents
		if old := w.records[e.id]; old != nil {
			r.changed, touched = old.changed, e.differs(old.entity)
			if touched == 0 {
				r.cache = old.cache
			}
		}
		if touched != 0 {
			full := allComponents
			m, err := e.message(full)
			var b []byte
			if err == nil {
				b, err = m.Append(nil)
			}
			if err != nil {
				return fmt.Errorf("statestream: entity %v in frame %d: %w", e.id, f.Tick, err)
			}
			r.cache = map[mask][]byte{full: b}
		}
		for c := range numComponents {
			if touched.has(c) {
				r.changed[c] = f.Tick
			}
		}
		next[e.id] = r
	}
	facts := make([]*sharedFact, 0, len(f.Facts))
	for _, fact := range f.Facts {
		if fact.msg == nil {
			return fmt.Errorf("statestream: empty fact in frame %d", f.Tick)
		}
		if fact.tick != f.Tick {
			return fmt.Errorf("statestream: fact %v carries tick %d in frame %d", fact.msg, fact.tick, f.Tick)
		}
		b, err := fact.msg.Append(nil)
		if err != nil {
			return fmt.Errorf("statestream: fact %v: %w", fact.msg, err)
		}
		facts = append(facts, &sharedFact{names: fact.names, tick: fact.tick, bytes: b})
	}
	w.tick, w.records, w.facts = f.Tick, next, facts
	w.grid = make(map[cell][]wire.EntityId, len(w.grid))
	for id, r := range next {
		w.grid[r.cell] = append(w.grid[r.cell], id)
	}
	return nil
}

func (w *World) cellOf(t wire.Transform) cell {
	return cell{int64(math.Floor(t.X() / w.cfg.CellSize)), int64(math.Floor(t.Z() / w.cfg.CellSize))}
}

func (w *World) interest(self wire.PlayerId) map[wire.EntityId]*record {
	out := map[wire.EntityId]*record{}
	me := w.records[self]
	if me == nil {
		return out
	}
	r := int64(w.cfg.Radius)
	for dx := -r; dx <= r; dx++ {
		for dz := -r; dz <= r; dz++ {
			for _, id := range w.grid[cell{me.cell.x + dx, me.cell.z + dz}] {
				out[id] = w.records[id]
			}
		}
	}
	return out
}

func (r *record) encode(m mask) []byte {
	if b, ok := r.cache[m]; ok {
		return b
	}
	b := must(must(r.entity.message(m)).Append(nil))
	if r.cache == nil {
		r.cache = map[mask][]byte{}
	}
	r.cache[m] = b
	return b
}
