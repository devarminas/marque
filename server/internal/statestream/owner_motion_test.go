package statestream

import (
	"errors"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"testing"
)

func TestOwnerMotionEveryTickUsesScheduledBudget(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Budget = MinBudget()
	id := wire.PlayerId{Index: 1, Gen: 1}
	world := must(NewWorld(cfg))
	client := must(NewClient(cfg, id))
	server := must(transport.NewEndpoint(transport.Server, transport.DefaultConfig(wire.SchemaHash), transport.Plain{}, transport.Plain{}, 0))
	peer := must(transport.NewEndpoint(transport.Client, transport.DefaultConfig(wire.SchemaHash), transport.Plain{}, transport.Plain{}, 0))
	for tick := uint32(1); tick <= 4; tick++ {
		entities := []Entity{player(id, 0, 0)}
		for n := uint32(2); n < 80; n++ {
			entities = append(entities, npc(n, 1, 1, 100))
		}
		if e := world.Commit(Frame{Tick: tick, Entities: entities}); e != nil {
			t.Fatal(e)
		}
		m := must((wire.OwnerMotionFields{Stream: 88, Epoch: 1, Player: id, Tick: tick, InputSeq: tick - 1, Grounded: true, Mode: wire.MotionModeFree, MapId: "fixture", MapRevision: 1, HalfExtent: 128, TickIntervalUs: 40000}).Build())
		scheduled, e := client.BuildOwner(world, Focus{}, m)
		if e != nil {
			t.Fatal(e)
		}
		if len(scheduled.Items) == 0 {
			t.Fatal("missing idle owner baseline")
		}
		first := must(wire.DecodeState(scheduled.Items[0]))
		if first != m {
			t.Fatalf("owner baseline is not first priority at tick%d %v", tick, first)
		}
		used := sectionHeader
		for _, data := range scheduled.Items {
			used += itemCost(len(data))
		}
		if used > cfg.Budget {
			t.Fatalf("owner baseline excluded from budget %d limit%d", used, cfg.Budget)
		}
		flushed := must(server.Flush(uint64(tick)*tickMicros, scheduled))
		client.Sent(flushed)
		if flushed.UnreliableSent != len(scheduled.Items) {
			t.Fatal("scheduled slice was unexpectedly trimmed")
		}
		var received wire.OwnerMotion
		for _, d := range flushed.Datagrams {
			got := must(peer.Receive(d, uint64(tick)*tickMicros))
			received = must(wire.DecodeState(got.Unreliable.Items[0])).(wire.OwnerMotion)
		}
		if received.Tick() != tick || received.InputSeq() != tick-1 {
			t.Fatalf("baseline skipped idle producing tick %v", received)
		}
		input := must(must((wire.InputFields{Seq: tick}).Build()).Append(nil))
		ack := must(peer.Flush(uint64(tick)*tickMicros, transport.Unreliable{Stamp: tick, Items: [][]byte{input}}))
		for _, d := range ack.Datagrams {
			got := must(server.Receive(d, uint64(tick)*tickMicros))
			client.Acked(got.PeerAck)
		}
	}
	bad := must((wire.OwnerMotionFields{Player: id, Tick: 3, Mode: wire.MotionModeFree, MapId: "fixture", MapRevision: 1, HalfExtent: 128, TickIntervalUs: 40000}).Build())
	if _, e := client.BuildOwner(world, Focus{}, bad); !errors.Is(e, ErrOwnerMotion) {
		t.Fatalf("wrong producing tick %v", e)
	}
	fields := wire.OwnerMotionFields{Player: wire.PlayerId{Index: 1, Gen: 2}, Tick: 4, Mode: wire.MotionModeFree, MapId: "fixture", MapRevision: 1, HalfExtent: 128, TickIntervalUs: 40000}
	if _, e := client.BuildOwner(world, Focus{}, must(fields.Build())); !errors.Is(e, ErrOwnerMotion) {
		t.Fatalf("wrong owner generation %v", e)
	}
}
