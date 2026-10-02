package statestream

import (
	"fmt"
	"maps"
	"math"
	"math/rand/v2"
	"slices"
	"testing"

	"github.com/devarminas/marque/server/internal/netsim"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

type rebuilt struct {
	transform codec.Opt[wire.Transform]
	vitals    codec.Opt[wire.Vitals]
	gear      codec.Opt[wire.Gear]
	cast      codec.Opt[wire.CastBar]
	look      codec.Opt[wire.Look]
}

func keep[T any](old, next codec.Opt[T]) codec.Opt[T] {
	if isSome(next) {
		return next
	}
	return old
}

type testClient struct {
	world  map[wire.EntityId]rebuilt
	facts  map[string]bool
	gones  int
	ticks  map[uint32]map[string]string
	errors []string
}

func (c *testClient) apply(stamp uint32, items [][]byte) {
	for _, it := range items {
		msg, err := wire.DecodeState(it)
		if err != nil {
			c.errors = append(c.errors, fmt.Sprintf("tick %d: %v", stamp, err))
			continue
		}
		switch m := msg.(type) {
		case wire.Entity:
			e := c.world[m.Id()]
			c.world[m.Id()] = rebuilt{
				transform: keep(e.transform, m.Transform()),
				vitals:    keep(e.vitals, m.Vitals()),
				gear:      keep(e.gear, m.Gear()),
				cast:      keep(e.cast, m.Cast()),
				look:      keep(e.look, m.Look()),
			}
		case wire.Gone:
			delete(c.world, m.Id())
			c.gones++
		default:
			c.facts[m.String()] = true
		}
	}
	snap := map[string]string{}
	for id, e := range c.world {
		m, err := wire.EntityFields{Id: id, Transform: e.transform, Vitals: e.vitals, Gear: e.gear, Cast: e.cast, Look: e.look}.Build()
		if err != nil {
			c.errors = append(c.errors, fmt.Sprintf("tick %d: rebuilt %v: %v", stamp, id, err))
			continue
		}
		snap[fmt.Sprint(id)] = m.String()
	}
	c.ticks[stamp] = snap
}

func serverView(w *World) map[string]string {
	out := map[string]string{}
	for id, r := range w.interest(me) {
		out[fmt.Sprint(id)] = must(r.entity.message(r.entity.components())).String()
	}
	return out
}

type scene struct {
	rng   *rand.Rand
	npcs  []Entity
	items map[uint32]Entity
	gens  map[uint32]uint32
}

func newScene(rng *rand.Rand) *scene {
	s := &scene{rng: rng, items: map[uint32]Entity{}, gens: map[uint32]uint32{}}
	for i := uint32(1); i <= 14; i++ {
		s.npcs = append(s.npcs, npc(i, rng.Float64()*400-200, rng.Float64()*400-200, 100))
	}
	return s
}

func (s *scene) frame(tick uint32) Frame {
	angle := float64(tick) * 2 * math.Pi / 200
	f := Frame{Tick: tick, Entities: []Entity{player(me, 120*math.Cos(angle), 120*math.Sin(angle))}}
	for i, e := range s.npcs {
		x := min(4000, max(-4000, e.transform.X()+s.rng.Float64()*4-2))
		z := min(4000, max(-4000, e.transform.Z()+s.rng.Float64()*4-2))
		v, _ := e.vitals.Get()
		hp := v.Hp()
		if s.rng.IntN(10) == 0 {
			hp = uint32(s.rng.IntN(101))
		}
		cast := idle()
		if (tick/7+uint32(i))%3 == 0 {
			casting := must(wire.CastingFields{Ability: "howl", Start: tick - tick%7, Ticks: 7}.Build())
			cast = must(wire.CastBarFields{Casting: codec.Some(casting)}.Build())
		}
		l, _ := e.look.Get()
		s.npcs[i] = Npc(e.id.(wire.NpcId), transformAt(x, z), vitals(hp), cast, l)
		if s.rng.IntN(12) == 0 {
			swing := must(wire.SwingFields{Tick: tick, Attacker: e.id.(wire.NpcId), Target: me, Amount: uint32(s.rng.IntN(20))}.Build())
			f.Facts = append(f.Facts, SwingFact(swing))
		}
	}
	f.Entities = append(f.Entities, s.npcs...)
	if tick%10 == 0 {
		slot := tick / 10 % 4
		if _, ok := s.items[slot]; ok {
			delete(s.items, slot)
			s.gens[slot]++
		} else {
			id := wire.ItemId{Index: slot, Gen: s.gens[slot]}
			s.items[slot] = Item(id, transformAt(s.rng.Float64()*300-150, s.rng.Float64()*300-150), look("ore"))
		}
	}
	for _, slot := range slices.Sorted(maps.Keys(s.items)) {
		f.Entities = append(f.Entities, s.items[slot])
	}
	return f
}

func TestClientRebuildsInterestSetThroughNetsim(t *testing.T) {
	for _, tc := range []struct {
		profile string
		want    string
	}{
		{"lossy_5pct", "applied=559 acked=531 compared=531 trimmed=0 gones=124 facts=130/130"},
		{"bad_wifi", "applied=451 acked=354 compared=354 trimmed=0 gones=275 facts=129/130"},
	} {
		t.Run(tc.profile, func(t *testing.T) {
			seed := netsim.SeedFromEnv(356)
			t.Logf("seed=%d profile=%s", seed, tc.profile)
			cfg := DefaultConfig()
			cfg.Budget = MaxBudget(0)
			w, c := must(NewWorld(cfg)), must(NewClient(cfg, me))
			tcfg := transport.DefaultConfig(wire.SchemaHash)
			srv := must(transport.NewEndpoint(transport.Server, tcfg, 0))
			cli := must(transport.NewEndpoint(transport.Client, tcfg, 0))
			sim := netsim.New(netsim.Profiles[tc.profile], seed)
			sc := newScene(rand.New(rand.NewPCG(seed, 356)))
			tester := &testClient{world: map[wire.EntityId]rebuilt{}, facts: map[string]bool{}, ticks: map[uint32]map[string]string{}}
			views := map[uint32]map[string]string{}
			emitted := map[string]bool{}
			var now uint64
			acked, compared, skipped := 0, 0, 0
			for tick := uint32(1); tick <= 600; tick++ {
				now += tickMicros
				for _, d := range sim.Poll(netsim.AToB, now) {
					r, err := cli.Receive(d.Packet, now)
					if err == nil && r.Unreliable.Items != nil {
						tester.apply(r.Unreliable.Stamp, r.Unreliable.Items)
					}
				}
				for _, d := range sim.Poll(netsim.BToA, now) {
					r, err := srv.Receive(d.Packet, now)
					if err != nil {
						continue
					}
					at, ok := c.Acked(r.PeerAck)
					if !ok {
						continue
					}
					acked++
					got, ok := tester.ticks[at]
					if !ok {
						t.Fatalf("seed %d: server saw tick %d acked but the client never applied it", seed, at)
					}
					if !maps.Equal(got, views[at]) {
						t.Fatalf("seed %d: tick %d rebuilt world differs from the server's interest set\nclient %v\nserver %v", seed, at, got, views[at])
					}
					compared++
				}
				f := sc.frame(tick)
				if err := w.Commit(f); err != nil {
					t.Fatalf("seed %d: %v", seed, err)
				}
				for _, fact := range f.Facts {
					if !slices.ContainsFunc(fact.names, func(id wire.EntityId) bool { return w.interest(me)[id] == nil }) {
						emitted[fact.msg.String()] = true
					}
				}
				views[tick] = serverView(w)
				u := c.Build(w, Focus{})
				fl := must(srv.Flush(now, u))
				if fl.UnreliableSent != len(u.Items) {
					skipped++
				}
				c.Sent(fl)
				for _, d := range fl.Datagrams {
					sim.Send(netsim.AToB, d, now)
				}
				in := must(must(wire.InputFields{Seq: tick}.Build()).Append(nil))
				for _, d := range must(cli.Flush(now, transport.Unreliable{Stamp: tick, Items: [][]byte{in}})).Datagrams {
					sim.Send(netsim.BToA, d, now)
				}
			}
			if len(tester.errors) > 0 {
				t.Fatalf("seed %d: client errors: %v", seed, tester.errors)
			}
			got := fmt.Sprintf("applied=%d acked=%d compared=%d trimmed=%d gones=%d facts=%d/%d",
				len(tester.ticks), acked, compared, skipped, tester.gones, len(tester.facts), len(emitted))
			if got != tc.want {
				t.Fatalf("seed %d:\ngot  %s\nwant %s", seed, got, tc.want)
			}
		})
	}
}
