package statestream

import (
	"bytes"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

func decodedEntity(t *testing.T, items [][]byte) wire.Entity {
	t.Helper()
	if len(items) != 1 {
		t.Fatalf("one Entity required, got %d", len(items))
	}
	value, err := wire.DecodeState(items[0])
	if err != nil {
		t.Fatal(err)
	}
	entity, ok := value.(wire.Entity)
	if !ok {
		t.Fatalf("Entity required, got %T", value)
	}
	return entity
}

func completeOperations(t *testing.T, value wire.Entity) {
	t.Helper()
	if !isSome(value.Transform()) || !isSome(value.Vitals()) || !isSome(value.Gear()) || !isSome(value.Cast()) || !isSome(value.Look()) {
		t.Fatalf("incomplete operation coverage %s", value)
	}
}

func populatedEntity() Entity {
	value := player(me, 0, 0)
	value.look = codec.Some(look("human"))
	value.cast = codec.Some(must(wire.CastBarFields{Casting: codec.Some(must(wire.CastingFields{Ability: "fireball", Start: 1, Ticks: 38}.Build()))}.Build()))
	return value
}

func TestOuterRemovalsSurviveLossAndAckOnlyCarriedOperation(t *testing.T) {
	for _, component := range []component{compVitals, compGear, compCast, compLook} {
		t.Run([]string{"transform", "vitals", "gear", "cast", "look"}[component], func(t *testing.T) {
			l := newLink(t, DefaultConfig())
			value := populatedEntity()
			first := l.step(Frame{Tick: 1, Entities: []Entity{value}}, Focus{}, true)
			if len(first) != 1 {
				t.Fatal(first)
			}
			l.ack()
			switch component {
			case compVitals:
				value.vitals = codec.Opt[wire.Vitals]{}
			case compGear:
				value.gear = codec.Opt[wire.Gear]{}
			case compCast:
				value.cast = codec.Opt[wire.CastBar]{}
			case compLook:
				value.look = codec.Opt[wire.Look]{}
			}
			lost := l.step(Frame{Tick: 2, Entities: []Entity{value}}, Focus{}, false)
			retry := l.step(Frame{Tick: 3, Entities: []Entity{value}}, Focus{}, true)
			if len(lost) != 1 || len(retry) != 1 || lost[0] != retry[0] {
				t.Fatalf("lost clear must retry exactly, lost %v retry %v", lost, retry)
			}
			message := decodedEntity(t, [][]byte{must(must(value.message(1 << component)).Append(nil))})
			switch component {
			case compVitals:
				v, ok := message.Vitals().Get()
				if !ok || isSome(v.Value()) {
					t.Fatal(message)
				}
			case compGear:
				v, ok := message.Gear().Get()
				if !ok || isSome(v.Value()) {
					t.Fatal(message)
				}
			case compCast:
				v, ok := message.Cast().Get()
				if !ok || isSome(v.Value()) {
					t.Fatal(message)
				}
			case compLook:
				v, ok := message.Look().Get()
				if !ok || isSome(v.Value()) {
					t.Fatal(message)
				}
			}
			if message.String() != retry[0] {
				t.Fatalf("actual delivered clear differs %s %v", message, retry)
			}
			if tick, ok := l.ack(); !ok || tick != 3 {
				t.Fatalf("actual ACK %d %v", tick, ok)
			}
			for c := range numComponents {
				want := uint32(1)
				if c == component {
					want = 3
				}
				if l.c.views[me].acked[c] != want {
					t.Fatalf("component%d baseline%d want%d", c, l.c.views[me].acked[c], want)
				}
			}
			if got := l.step(Frame{Tick: 4, Entities: []Entity{value}}, Focus{}, true); len(got) != 0 {
				t.Fatalf("acknowledged unchanged clear repeats %v", got)
			}
		})
	}
}

func TestLostInitialAndFullAfterCarryAbsentOperations(t *testing.T) {
	l := newLink(t, DefaultConfig())
	value := Entity{id: me, transform: transformAt(0, 0)}
	lost := l.step(Frame{Tick: 1, Entities: []Entity{value}}, Focus{}, false)
	actual := l.step(Frame{Tick: 2, Entities: []Entity{value}}, Focus{}, true)
	if len(lost) != 1 || len(actual) != 1 || lost[0] != actual[0] {
		t.Fatalf("initial loss %v retry %v", lost, actual)
	}
	if actual[0] != must(value.message(allComponents)).String() {
		t.Fatalf("actual retry lacks full absent operations %v", actual)
	}
	completeOperations(t, decodedEntity(t, [][]byte{l.w.records[me].encode(allComponents)}))
	l.ack()
	for tick := uint32(3); tick <= 35; tick++ {
		value.transform = transformAt(float64(tick), 0)
		got := l.step(Frame{Tick: tick, Entities: []Entity{value}}, Focus{}, false)
		if tick == 35 {
			completeOperations(t, decodedEntity(t, [][]byte{must(must(value.message(allComponents)).Append(nil))}))
			if len(got) != 1 || got[0] != must(value.message(allComponents)).String() {
				t.Fatalf("FullAfter omits absent clear %v", got)
			}
		}
	}
}

func TestActualTrimmedFlushCannotAcknowledgeBuiltOperations(t *testing.T) {
	l := newLink(t, DefaultConfig())
	value := populatedEntity()
	l.step(Frame{Tick: 1, Entities: []Entity{value}}, Focus{}, true)
	l.ack()
	value.cast = codec.Opt[wire.CastBar]{}
	long := codec.Some(strings.Repeat("x", 32))
	value.gear = codec.Some(must(wire.GearFields{Helmet: long, Chest: long, Trousers: long, Feet: long, LeftHand: long, RightHand: long}.Build()))
	if err := l.w.Commit(Frame{Tick: 2, Entities: []Entity{value}}); err != nil {
		t.Fatal(err)
	}
	u := l.c.Build(l.w, Focus{})
	if len(u.Items) != 1 {
		t.Fatal("clear not built")
	}
	cfg := transport.DefaultConfig(wire.SchemaHash)
	cfg.TickBudget = transport.MaxDatagram
	l.srv = must(transport.NewEndpoint(transport.Server, cfg, transport.Plain{}, transport.Plain{}, l.now))
	l.cli = must(transport.NewEndpoint(transport.Client, cfg, transport.Plain{}, transport.Plain{}, l.now))
	if err := l.srv.Send(bytes.Repeat([]byte{7}, 3000)); err != nil {
		t.Fatal(err)
	}
	l.now += tickMicros
	fl := must(l.srv.Flush(l.now, u))
	l.c.Sent(fl)
	if fl.UnreliableSent != 0 || len(fl.Datagrams) != 1 {
		t.Fatalf("real backlog must trim clear, got%d/%d", fl.UnreliableSent, len(fl.Datagrams))
	}
	for _, d := range fl.Datagrams {
		must(l.cli.Receive(d, l.now))
	}
	if _, ok := l.ack(); ok {
		t.Fatal("ACK for reliable-only flush advanced draft clear")
	}
	if l.c.views[me].acked[compCast] != 1 {
		t.Fatal("unflushed clear acknowledged")
	}
	if err := l.w.Commit(Frame{Tick: 3, Entities: []Entity{value}}); err != nil {
		t.Fatal(err)
	}
	retry := l.c.Build(l.w, Focus{})
	if len(retry.Items) != 1 || !bytes.Equal(retry.Items[0], u.Items[0]) {
		t.Fatal("trimmed clear not due with original bytes")
	}
}

func TestGeneratedEntityMaxIncludesAllUpdateBytes(t *testing.T) {
	if maxEntityCost != 328 || MinBudget() != 402 {
		t.Fatalf("actual generated maxima entity%d minimum%d", maxEntityCost, MinBudget())
	}
}

func TestDelayedActualAckCannotSuppressReenteredClearOperations(t *testing.T) {
	l := newLink(t, DefaultConfig())
	id := wire.NpcId{Index: 9, Gen: 1}
	old := Npc(id, transformAt(1, 0), vitals(100), idle(), look("wolf"))
	if err := l.w.Commit(Frame{Tick: 1, Entities: []Entity{player(me, 0, 0), old}}); err != nil {
		t.Fatal(err)
	}
	l.now = tickMicros
	first := must(l.srv.Flush(l.now, l.c.Build(l.w, Focus{})))
	l.c.Sent(first)
	for _, d := range first.Datagrams {
		must(l.cli.Receive(d, l.now))
	}
	input := must(must(wire.InputFields{Seq: 1}.Build()).Append(nil))
	delayed := must(l.cli.Flush(l.now, transport.Unreliable{Stamp: 1, Items: [][]byte{input}}))
	old.transform = transformAt(500, 0)
	if err := l.w.Commit(Frame{Tick: 2, Entities: []Entity{player(me, 0, 0), old}}); err != nil {
		t.Fatal(err)
	}
	l.c.Build(l.w, Focus{})
	clear := Entity{id: id, transform: transformAt(1, 0)}
	if err := l.w.Commit(Frame{Tick: 3, Entities: []Entity{player(me, 0, 0), clear}}); err != nil {
		t.Fatal(err)
	}
	l.c.Build(l.w, Focus{})
	if l.c.views[id].since != 3 {
		t.Fatal("reentry identity not established")
	}
	for _, d := range delayed.Datagrams {
		received := must(l.srv.Receive(d, 3*tickMicros))
		tick, ok := l.c.Acked(received.PeerAck)
		if !ok || tick != 1 {
			t.Fatalf("actual delayed ack %d %v", tick, ok)
		}
	}
	for component := range numComponents {
		if l.c.views[id].acked[component] != 0 {
			t.Fatal("pre-reentry actual ACK suppressed clear")
		}
	}
	pending := l.c.Build(l.w, Focus{})
	message := decodedEntity(t, pending.Items)
	completeOperations(t, message)
	if message.Id() != id {
		t.Fatal(message)
	}
	if v, _ := message.Vitals().Get(); isSome(v.Value()) {
		t.Fatal(message)
	}
	if g, _ := message.Gear().Get(); isSome(g.Value()) {
		t.Fatal(message)
	}
	if c, _ := message.Cast().Get(); isSome(c.Value()) {
		t.Fatal(message)
	}
	if look, _ := message.Look().Get(); isSome(look.Value()) {
		t.Fatal(message)
	}
}

func TestMaximumCompleteRowAndResetPartGeneratedSizes(t *testing.T) {
	long := codec.Some(strings.Repeat("x", 32))
	gear := must(wire.GearFields{Helmet: long, Chest: long, Trousers: long, Feet: long, LeftHand: long, RightHand: long}.Build())
	casting := must(wire.CastingFields{Ability: strings.Repeat("x", 32), Start: ^uint32(0), Ticks: ^uint16(0)}.Build())
	value := Entity{id: wire.PlayerId{Index: ^uint32(0), Gen: ^uint32(0)}, transform: transformAt(4096, -4096),
		vitals: codec.Some(must(wire.VitalsFields{Hp: ^uint32(0), MaxHp: ^uint32(0), Mana: ^uint32(0), MaxMana: ^uint32(0)}.Build())),
		gear:   codec.Some(gear), cast: codec.Some(must(wire.CastBarFields{Casting: codec.Some(casting)}.Build())), look: codec.Some(look(strings.Repeat("x", 32)))}
	snapshot := must(wire.EntitySnapshotFields{Id: value.id, Transform: value.transform, Vitals: value.vitals, Gear: value.gear, Cast: value.cast, Look: value.look}.Build())
	ordinary := must(must(value.message(allComponents)).Append(nil))
	rows := make([]wire.EntitySnapshot, 64)
	for i := range rows {
		rows[i] = must(wire.EntitySnapshotFields{Id: wire.PlayerId{Index: ^uint32(0) - uint32(i), Gen: ^uint32(0)}, Transform: value.transform, Vitals: snapshot.Vitals(), Gear: snapshot.Gear(), Cast: snapshot.Cast(), Look: snapshot.Look()}.Build())
	}
	certificate := must(wire.ResetCertificateFields{Stream: 88, Epoch: 2, Lease: 42, Baseline: 7, Tick: 10, NextIntent: 1, Parts: 1, Entities: 64}.Build())
	part := must(wire.ResetPartFields{Certificate: certificate, Index: 0, Entities: rows}.Build())
	encoded := must(part.Append(nil))
	if len(ordinary) != 326 || len(encoded) != 20543 || len(encoded) > transport.MaxMessage {
		t.Fatalf("actual generated sizes Entity%d ResetPart%d MaxMessage%d", len(ordinary), len(encoded), transport.MaxMessage)
	}
	decoded, err := wire.DecodeEvents(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if got := decoded.(wire.ResetPart); got.Entities().Len() != 64 || got.Entities().At(0) != rows[0] || got.Entities().At(63) != rows[63] {
		t.Fatal("maximal exact snapshot values did not roundtrip")
	}
}
