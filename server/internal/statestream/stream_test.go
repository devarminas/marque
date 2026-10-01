package statestream

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

func ids(items []string) []string {
	var out []string
	for _, s := range items {
		head, _, _ := strings.Cut(s, " ")
		out = append(out, head)
	}
	return out
}

func TestInterestStopsAtCellBorders(t *testing.T) {
	cfg := DefaultConfig()
	cfg.CellSize, cfg.Radius = 32, 1
	l := newLink(t, cfg)
	wolves := func(px float64) Frame {
		return Frame{Entities: []Entity{
			player(me, px, 0.5),
			npc(1, 63.99, 0.5, 100),
			npc(2, 64, 0.5, 100),
			npc(3, -32, 0.5, 100),
			npc(4, -32.01, 0.5, 100),
			npc(5, 0.5, 63.99, 100),
			npc(6, 0.5, -32.01, 100),
			npc(7, 63.99, -32, 100),
			npc(8, 95.99, 0.5, 100),
		}}
	}
	f := wolves(0.5)
	f.Tick = 1
	got := ids(l.step(f, Focus{}, true))
	slices.Sort(got)
	want := []string{"entity{id:NpcId(1/0)", "entity{id:NpcId(3/0)", "entity{id:NpcId(5/0)", "entity{id:NpcId(7/0)", "entity{id:PlayerId(1/0)"}
	if !slices.Equal(got, want) {
		t.Fatalf("player in cell 0: got %v, want %v", got, want)
	}
	l.ack()

	f = wolves(32)
	f.Tick = 2
	items := l.step(f, Focus{}, true)
	entering := `entity{id:NpcId(8/0) transform:Transform{x:95.99 y:0 z:0.5} vitals:Vitals{hp:100 max_hp:100 mana:10 max_mana:10} gear:_ cast:CastBar{casting:_} look:Look{kind:"wolf"}}`
	if !slices.Contains(items, entering) {
		t.Fatalf("entering wolf 8 lacks a component: %v", items)
	}
	got = ids(items)
	slices.Sort(got)
	want = []string{"entity{id:NpcId(2/0)", "entity{id:NpcId(8/0)", "entity{id:PlayerId(1/0)", "gone{id:NpcId(3/0)}"}
	if !slices.Equal(got, want) {
		t.Fatalf("player moved into cell 1: got %v, want %v", got, want)
	}
	l.ack()

	for tick := uint32(3); tick <= 6; tick++ {
		f = wolves(32 + float64(tick))
		f.Tick = tick
		for _, s := range l.step(f, Focus{}, true) {
			for _, out := range []string{"NpcId(3/0)", "NpcId(4/0)", "NpcId(6/0)"} {
				if strings.Contains(s, out) {
					t.Fatalf("tick %d: %s is outside the interest set but sent %s", tick, out, s)
				}
			}
		}
		l.ack()
	}
}

func TestDeltasFollowTheAcknowledgedTick(t *testing.T) {
	l := newLink(t, DefaultConfig())
	frame := func(tick uint32, wolfX float64, wolfHp uint32) Frame {
		return Frame{Tick: tick, Entities: []Entity{player(me, 0, 0), npc(9, wolfX, 0, wolfHp)}}
	}
	steps := []struct {
		frame   Frame
		deliver bool
		ack     bool
		want    []string
	}{
		{frame(1, 5, 100), true, true, []string{
			`entity{id:PlayerId(1/0) transform:Transform{x:0 y:0 z:0} vitals:Vitals{hp:100 max_hp:100 mana:10 max_mana:10} gear:Gear{helmet:_ chest:_ trousers:_ feet:_ left_hand:_ right_hand:"sword"} cast:CastBar{casting:_} look:_}`,
			`entity{id:NpcId(9/0) transform:Transform{x:5 y:0 z:0} vitals:Vitals{hp:100 max_hp:100 mana:10 max_mana:10} gear:_ cast:CastBar{casting:_} look:Look{kind:"wolf"}}`,
		}},
		{frame(2, 6, 100), false, false, []string{
			`entity{id:NpcId(9/0) transform:Transform{x:6 y:0 z:0} vitals:_ gear:_ cast:_ look:_}`,
		}},
		{frame(3, 6, 90), true, true, []string{
			`entity{id:NpcId(9/0) transform:Transform{x:6 y:0 z:0} vitals:Vitals{hp:90 max_hp:100 mana:10 max_mana:10} gear:_ cast:_ look:_}`,
		}},
		{frame(4, 6, 90), true, false, nil},
		{frame(5, 7, 90), true, true, []string{
			`entity{id:NpcId(9/0) transform:Transform{x:7 y:0 z:0} vitals:_ gear:_ cast:_ look:_}`,
		}},
	}
	for _, s := range steps {
		got := l.step(s.frame, Focus{}, s.deliver)
		if !slices.Equal(got, s.want) {
			t.Fatalf("tick %d: got\n%s\nwant\n%s", s.frame.Tick, strings.Join(got, "\n"), strings.Join(s.want, "\n"))
		}
		if s.ack {
			if tick, acked := l.ack(); !acked || tick != s.frame.Tick {
				t.Fatalf("tick %d: ack returned %d, %v", s.frame.Tick, tick, acked)
			}
		}
	}
}

func TestFullStateAfter32UnacknowledgedPackets(t *testing.T) {
	l := newLink(t, DefaultConfig())
	frame := func(tick uint32) Frame {
		return Frame{Tick: tick, Entities: []Entity{player(me, 0, 0), npc(9, float64(tick), 0, 100)}}
	}
	l.step(frame(1), Focus{}, true)
	l.ack()
	var got []string
	for tick := uint32(2); tick <= 36; tick++ {
		got = append(got, fmt.Sprintf("%d:%s", tick, strings.Join(ids(l.step(frame(tick), Focus{}, tick == 36)), ",")))
	}
	l.ack()
	got = append(got, fmt.Sprintf("%d:%s", 37, strings.Join(l.step(frame(37), Focus{}, true), ",")))
	wolf := "entity{id:NpcId(9/0)"
	var want []string
	for tick := 2; tick <= 36; tick++ {
		if tick >= 34 {
			want = append(want, fmt.Sprintf("%d:entity{id:PlayerId(1/0),%s", tick, wolf))
		} else {
			want = append(want, fmt.Sprintf("%d:%s", tick, wolf))
		}
	}
	want = append(want, "37:entity{id:NpcId(9/0) transform:Transform{x:37 y:0 z:0} vitals:_ gear:_ cast:_ look:_}")
	if !slices.Equal(got, want) {
		t.Fatalf("got\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestFactsRepeatUntilAckedForAtMostEightTicks(t *testing.T) {
	l := newLink(t, DefaultConfig())
	wolf := wire.NpcId{Index: 9}
	farNode := wire.NodeId{Index: 4}
	frame := func(tick uint32, facts ...Fact) Frame {
		return Frame{Tick: tick, Facts: facts, Entities: []Entity{
			player(me, 0, 0),
			npc(9, 2, 0, 100),
			Node(farNode, transformAt(500, 500), look("ore")),
		}}
	}
	facts := func(tick uint32) []string {
		var out []string
		for _, s := range l.step(frame(tick), Focus{}, false) {
			if !strings.HasPrefix(s, "entity{") {
				out = append(out, s)
			}
		}
		return out
	}
	l.step(frame(1), Focus{}, true)
	l.ack()

	swing := must(wire.SwingFields{Tick: 2, Attacker: me, Target: wolf, Amount: 7}.Build())
	gather := must(wire.GatherStartFields{Tick: 2, Player: me, Node: farNode}.Build())
	l.step(frame(2, SwingFact(swing), GatherFact(gather)), Focus{}, false)
	var got []string
	for tick := uint32(3); tick <= 10; tick++ {
		got = append(got, fmt.Sprintf("%d:%s", tick, strings.Join(facts(tick), ",")))
	}
	want := []string{
		"3:swing{tick:2 attacker:PlayerId(1/0) target:NpcId(9/0) amount:7 crit:false miss:false}",
		"4:swing{tick:2 attacker:PlayerId(1/0) target:NpcId(9/0) amount:7 crit:false miss:false}",
		"5:swing{tick:2 attacker:PlayerId(1/0) target:NpcId(9/0) amount:7 crit:false miss:false}",
		"6:swing{tick:2 attacker:PlayerId(1/0) target:NpcId(9/0) amount:7 crit:false miss:false}",
		"7:swing{tick:2 attacker:PlayerId(1/0) target:NpcId(9/0) amount:7 crit:false miss:false}",
		"8:swing{tick:2 attacker:PlayerId(1/0) target:NpcId(9/0) amount:7 crit:false miss:false}",
		"9:swing{tick:2 attacker:PlayerId(1/0) target:NpcId(9/0) amount:7 crit:false miss:false}",
		"10:",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("unacked swing from tick 2 (gather names a node outside interest):\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	cast := must(wire.CastPhaseFields{Tick: 11, Caster: wolf, Ability: "howl", Step: wire.CastStepBegin}.Build())
	got = l.step(frame(11, CastFact(cast)), Focus{}, true)
	if want := []string{`cast_phase{tick:11 caster:NpcId(9/0) ability:"howl" step:begin target:_ amount:0}`}; !slices.Equal(got, want) {
		t.Fatalf("tick 11: got %v, want %v", got, want)
	}
	if tick, acked := l.ack(); !acked || tick != 11 {
		t.Fatalf("ack of tick 11 returned %d, %v", tick, acked)
	}
	if got := facts(12); got != nil {
		t.Fatalf("tick 12 repeats an acked fact: %v", got)
	}
}

func TestPendingFactDropsWhenANamedEntityLeavesInterest(t *testing.T) {
	l := newLink(t, DefaultConfig())
	wolf := wire.NpcId{Index: 9}
	frame := func(tick uint32, wolfX float64, facts ...Fact) Frame {
		return Frame{Tick: tick, Facts: facts, Entities: []Entity{player(me, 0, 0), npc(9, wolfX, 0, 100)}}
	}
	l.step(frame(1, 2), Focus{}, true)
	l.ack()

	swing := must(wire.SwingFields{Tick: 2, Attacker: me, Target: wolf, Amount: 7}.Build())
	got := []string{"2:" + strings.Join(l.step(frame(2, 2, SwingFact(swing)), Focus{}, false), ",")}
	for tick := uint32(3); tick <= 10; tick++ {
		got = append(got, fmt.Sprintf("%d:%s", tick, strings.Join(l.step(frame(tick, 500), Focus{}, false), ",")))
	}
	want := []string{
		"2:swing{tick:2 attacker:PlayerId(1/0) target:NpcId(9/0) amount:7 crit:false miss:false}",
		"3:gone{id:NpcId(9/0)}",
		"4:gone{id:NpcId(9/0)}",
		"5:gone{id:NpcId(9/0)}",
		"6:gone{id:NpcId(9/0)}",
		"7:gone{id:NpcId(9/0)}",
		"8:gone{id:NpcId(9/0)}",
		"9:gone{id:NpcId(9/0)}",
		"10:gone{id:NpcId(9/0)}",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("unacked swing naming a wolf that left interest at tick 3:\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestSkippedEntitiesGainPriorityUntilSent(t *testing.T) {
	l := newLink(t, DefaultConfig())
	mate := wire.PlayerId{Index: 2}
	target := wire.NpcId{Index: 150}
	frame := func(tick uint32) Frame {
		f := Frame{Tick: tick, Entities: []Entity{player(me, 0, 0), player(mate, 40+float64(tick)/10, 40)}}
		for i := uint32(1); i <= 150; i++ {
			f.Entities = append(f.Entities, npc(i, float64(i%30)+float64(tick)/10, float64(i/30), 100))
		}
		return f
	}
	focus := Focus{Target: codec.Some[wire.EntityId](target), Party: []wire.PlayerId{mate}}
	last := map[string]uint32{}
	gap := map[string]uint32{}
	perTick := map[int]int{}
	const ticks = 60
	for tick := uint32(1); tick <= ticks; tick++ {
		got := ids(l.step(frame(tick), focus, true))
		perTick[len(got)]++
		for _, id := range got {
			gap[id] = max(gap[id], tick-last[id])
			last[id] = tick
		}
		l.ack()
	}
	worst, worstID := uint32(0), ""
	for id, g := range gap {
		if !strings.Contains(id, "NpcId") {
			continue
		}
		g = max(g, ticks+1-last[id])
		if g > worst || g == worst && id < worstID {
			worst, worstID = g, id
		}
	}
	got := fmt.Sprintf("sent=%d target_gap=%d mate_gap=%d worst_gap=%d worst=%s per_tick=%v",
		len(gap), gap["entity{id:NpcId(150/0)"], gap["entity{id:PlayerId(2/0)"], worst, worstID, perTick)
	want := "sent=152 target_gap=2 mate_gap=3 worst_gap=7 worst=entity{id:NpcId(114/0) per_tick=map[24:1 25:3 26:1 30:1 35:1 48:2 49:51]"
	if got != want {
		t.Fatalf("crowd of 150 wolves over %d ticks:\ngot  %s\nwant %s", ticks, got, want)
	}
}

func TestPriorityOrdersByTargetPartyAndDistance(t *testing.T) {
	l := newLink(t, DefaultConfig())
	mate := wire.PlayerId{Index: 2}
	f := Frame{Tick: 1, Entities: []Entity{
		npc(1, 60, 0, 100),
		npc(2, 5, 0, 100),
		npc(3, 90, 0, 100),
		player(mate, 70, 0),
		player(me, 0, 0),
	}}
	focus := Focus{Target: codec.Some[wire.EntityId](wire.NpcId{Index: 3}), Party: []wire.PlayerId{mate}}
	got := ids(l.step(f, focus, true))
	want := []string{"entity{id:PlayerId(1/0)", "entity{id:NpcId(3/0)", "entity{id:PlayerId(2/0)", "entity{id:NpcId(2/0)", "entity{id:NpcId(1/0)"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestPackedCrowdPayloadFitsOneDatagram(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Budget = MaxBudget(0)
	l := newLink(t, cfg)
	long := codec.Some(strings.Repeat("é", 16))
	gear := must(wire.GearFields{Helmet: long, Chest: long, Trousers: long, Feet: long, LeftHand: long, RightHand: long}.Build())
	frame := func(tick uint32) Frame {
		f := Frame{Tick: tick}
		for i := uint32(0); i < 1000; i++ {
			id := wire.PlayerId{Index: 1<<31 + i, Gen: 1 << 31}
			if i == 0 {
				id = me
			}
			casting := must(wire.CastingFields{Ability: strings.Repeat("a", 32), Start: tick, Ticks: 65535}.Build())
			cast := must(wire.CastBarFields{Casting: codec.Some(casting)}.Build())
			v := must(wire.VitalsFields{Hp: 1<<31 + tick, MaxHp: 1<<32 - 1, Mana: tick, MaxMana: 1<<32 - 1}.Build())
			f.Entities = append(f.Entities, Player(id, transformAt(4000-float64(tick), -4000), v, gear, cast))
			if i > 0 && i%100 == 0 {
				phase := must(wire.CastPhaseFields{Tick: tick, Caster: id, Ability: strings.Repeat("b", 32), Step: wire.CastStepResolve, Target: codec.Some[wire.CombatantId](me), Amount: 1<<32 - 1}.Build())
				f.Facts = append(f.Facts, CastFact(phase))
			}
		}
		return f
	}
	var sizes []string
	for tick := uint32(1); tick <= 20; tick++ {
		l.now += tickMicros
		if err := l.w.Commit(frame(tick)); err != nil {
			t.Fatal(err)
		}
		u := l.c.Build(l.w, Focus{})
		fl, err := l.srv.Flush(l.now, u)
		if err != nil {
			t.Fatalf("tick %d: %v", tick, err)
		}
		l.c.Sent(fl)
		if len(fl.Datagrams) != 1 || fl.UnreliableSent != len(u.Items) {
			t.Fatalf("tick %d: %d items went out as %d of them in %d datagrams", tick, len(u.Items), fl.UnreliableSent, len(fl.Datagrams))
		}
		sizes = append(sizes, fmt.Sprintf("%d/%d", len(u.Items), len(fl.Datagrams[0])))
	}
	got := strings.Join(sizes, " ")
	want := "11/1132 15/1144 15/1136 15/1144 15/1144 15/1144 15/1136 15/1144 15/1144 15/1144 15/1144 15/1144 15/1144 15/1144 15/1136 15/1144 15/1144 15/1144 15/1144 15/1144"
	if got != want {
		t.Fatalf("items/datagram bytes per tick:\ngot  %s\nwant %s", got, want)
	}
}

func TestCommitRefusesFramesThatCannotBeSent(t *testing.T) {
	w := must(NewWorld(DefaultConfig()))
	if err := w.Commit(Frame{Tick: 5, Entities: []Entity{player(me, 0, 0)}}); err != nil {
		t.Fatal(err)
	}
	swing := must(wire.SwingFields{Tick: 6, Attacker: me, Target: wire.NpcId{Index: 1}}.Build())
	cases := []struct {
		name  string
		frame Frame
		want  string
	}{
		{"same tick", Frame{Tick: 5}, "statestream: frame tick 5 does not follow tick 5"},
		{"zero entity", Frame{Tick: 6, Entities: []Entity{{}}}, "statestream: entity with no id in frame 6"},
		{"twice", Frame{Tick: 6, Entities: []Entity{player(me, 0, 0), player(me, 1, 0)}}, "statestream: entity PlayerId(1/0) twice in frame 6"},
		{"zero fact", Frame{Tick: 6, Facts: []Fact{{}}}, "statestream: empty fact in frame 6"},
		{"stale fact", Frame{Tick: 7, Facts: []Fact{SwingFact(swing)}}, "statestream: fact swing{tick:6 attacker:PlayerId(1/0) target:NpcId(1/0) amount:0 crit:false miss:false} carries tick 6 in frame 7"},
		{"unbuilt fact", Frame{Tick: 6, Facts: []Fact{GatherFact(wire.GatherStart{})}}, "statestream: fact gather_start{tick:0 player:PlayerId(0/0) node:NodeId(0/0)} carries tick 0 in frame 6"},
	}
	for _, c := range cases {
		err := w.Commit(c.frame)
		if err == nil || err.Error() != c.want {
			t.Errorf("%s: got %v, want %q", c.name, err, c.want)
		}
	}
	if w.Tick() != 5 {
		t.Fatalf("refused frames moved the world to tick %d", w.Tick())
	}
}

func TestConfigBounds(t *testing.T) {
	cases := []struct {
		name string
		edit func(*Config)
		want string
	}{
		{"default", func(*Config) {}, ""},
		{"zero cell", func(c *Config) { c.CellSize = 0 }, "statestream: CellSize 0 is not a positive finite size"},
		{"negative radius", func(c *Config) { c.Radius = -1 }, "statestream: Radius -1 below 0"},
		{"budget over datagram", func(c *Config) { c.Budget = 1181 }, fmt.Sprintf("statestream: Budget 1181 outside %d to 1180", MinBudget())},
		{"budget under seal", func(c *Config) { c.Budget, c.SealOverhead = 1180, 24 }, fmt.Sprintf("statestream: Budget 1180 outside %d to 1156", MinBudget())},
		{"no base weight", func(c *Config) { c.Weights.Base = 0 }, "statestream: Weights {Base:0 Near:8 Target:16 Party:8} need Base at least 1 and no negative weight"},
	}
	for _, c := range cases {
		cfg := DefaultConfig()
		c.edit(&cfg)
		_, err := NewWorld(cfg)
		got := ""
		if err != nil {
			got = err.Error()
		}
		if got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestMinimumBudgetStillSendsRemovalsAndEntities(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Budget = MinBudget()
	l := newLink(t, cfg)
	frame := func(tick uint32, wolves uint32) Frame {
		f := Frame{Tick: tick, Entities: []Entity{player(me, 0, 0)}}
		for i := uint32(1); i <= wolves; i++ {
			f.Entities = append(f.Entities, npc(i, float64(i)+float64(tick)/10, 0, 100))
		}
		return f
	}
	var got []string
	for tick := uint32(1); tick <= 12; tick++ {
		wolves := uint32(60)
		if tick > 8 {
			wolves = 10
		}
		gone, entities := 0, 0
		for _, id := range ids(l.step(frame(tick, wolves), Focus{}, true)) {
			if strings.HasPrefix(id, "gone") {
				gone++
			} else {
				entities++
			}
		}
		got = append(got, fmt.Sprintf("%d:gone=%d entities=%d", tick, gone, entities))
		l.ack()
	}
	want := []string{
		"1:gone=0 entities=8", "2:gone=0 entities=9", "3:gone=0 entities=9", "4:gone=0 entities=11",
		"5:gone=0 entities=9", "6:gone=0 entities=11", "7:gone=0 entities=13", "8:gone=0 entities=13",
		"9:gone=13 entities=10", "10:gone=13 entities=10", "11:gone=13 entities=10", "12:gone=2 entities=10",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("budget %d:\ngot\n%s\nwant\n%s", cfg.Budget, strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}
