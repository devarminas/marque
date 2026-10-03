package intents_test

import (
	"github.com/devarminas/marque/server/internal/eventstream"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/gamelog"
	"github.com/devarminas/marque/server/internal/intents"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/netsim"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"io"
	"reflect"
	"testing"
)

type idleTransport struct{}

func (idleTransport) Events() <-chan mnet.Event { return nil }
func must[T any](t *testing.T, v T, err error) T {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	return v
}
func build[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

type pair struct {
	cs, ss *transport.Sender
	cr, sr *transport.Receiver
	sim    *netsim.Simulator
	now    uint64
}

func newPair(t *testing.T, profile netsim.Profile, seed uint64) *pair {
	cfg := transport.DefaultConfig(wire.SchemaHash)
	cs, e := transport.NewSender(transport.Client, cfg, transport.Plain{}, 0)
	cs = must(t, cs, e)
	ss, e := transport.NewSender(transport.Server, cfg, transport.Plain{}, 0)
	ss = must(t, ss, e)
	cr, e := transport.NewReceiver(transport.Client, cfg, transport.Plain{})
	cr = must(t, cr, e)
	sr, e := transport.NewReceiver(transport.Server, cfg, transport.Plain{})
	sr = must(t, sr, e)
	return &pair{cs: cs, ss: ss, cr: cr, sr: sr, sim: netsim.New(profile, seed)}
}
func (p *pair) turn(t *testing.T, onIntent func([]byte), onEvent func([]byte)) {
	t.Helper()
	p.now += 40000
	for _, x := range []struct {
		s   *transport.Sender
		dir netsim.Direction
	}{{p.cs, netsim.AToB}, {p.ss, netsim.BToA}} {
		f, e := x.s.Flush(p.now, transport.Unreliable{})
		if e != nil {
			t.Fatal(e)
		}
		if f.State != transport.Open {
			t.Fatalf("sender closed at %d", p.now)
		}
		for _, d := range f.Datagrams {
			p.sim.Send(x.dir, d, p.now)
		}
	}
	for _, x := range []struct {
		r   *transport.Receiver
		s   *transport.Sender
		dir netsim.Direction
		fn  func([]byte)
	}{{p.sr, p.ss, netsim.AToB, onIntent}, {p.cr, p.cs, netsim.BToA, onEvent}} {
		for _, d := range p.sim.Poll(x.dir, p.now) {
			got, e := x.r.Receive(d.Packet)
			if e == transport.ErrDuplicate || e == transport.ErrTooOld {
				continue
			}
			if e != nil {
				t.Fatal(e)
			}
			x.s.Observe(got.PeerAck, got.OwnAck, p.now)
			for _, msg := range got.Reliable {
				x.fn(msg)
			}
		}
	}
}
func fixture(t *testing.T) (*game.World, *eventstream.Sessions, eventstream.ResumePlan) {
	w := game.NewWorld(idleTransport{}, gamelog.New(io.Discard, false), game.NewMemoryStore(game.NoWearables), 1500, nil)
	owner, e := w.CreateOwner()
	owner = must(t, owner, e)
	w.TakeOwnerChanges()
	w.AdvanceTick()
	sessions, e := eventstream.New(eventstream.DefaultConfig())
	sessions = must(t, sessions, e)
	if e := sessions.Create(7, 9, 88, owner, 1); e != nil {
		t.Fatal(e)
	}
	plan, e := sessions.Attach(7, 9, 1)
	plan = must(t, plan, e)
	return w, sessions, plan
}
func TestAllActionFamiliesThroughTransportAndGame(t *testing.T) {
	cases := []struct {
		name   string
		msg    wire.IntentsMsg
		reason wire.RefuseReason
		events int
	}{
		{"pickup", build(wire.PickupFields{Seq: 1, Item: wire.ItemId{Index: 99, Gen: 1}}.Build()), wire.RefuseReasonUnknownItem, 1},
		{"drop", build(wire.DropFields{Seq: 1, Slot: 0}.Build()), wire.RefuseReasonEmptySlot, 1},
		{"equip", build(wire.EquipFields{Seq: 1, Slot: 0}.Build()), wire.RefuseReasonEmptySlot, 1},
		{"unequip", build(wire.UnequipFields{Seq: 1, Worn: "helmet"}.Build()), wire.RefuseReasonEmptyWornSlot, 1},
		{"gather", build(wire.GatherFields{Seq: 1, Node: wire.NodeId{Index: 99, Gen: 1}}.Build()), wire.RefuseReasonUnknownNode, 1},
		{"use_self", build(wire.UseSelfFields{Seq: 1, Slot: 0}.Build()), wire.RefuseReasonEmptySlot, 1},
		{"use_station", build(wire.UseStationFields{Seq: 1, Slot: 0, Node: wire.NodeId{Index: 99, Gen: 1}}.Build()), wire.RefuseReasonNoRecipe, 1},
		{"attack_player", build(wire.AttackPlayerFields{Seq: 1, Target: wire.PlayerId{Index: 1, Gen: 1}}.Build()), wire.RefuseReasonSelf, 1},
		{"attack_npc", build(wire.AttackNpcFields{Seq: 1, Target: wire.NpcId{Index: 1000001, Gen: 1}}.Build()), wire.RefuseReasonNeedsClass, 1},
		{"respawn", build(wire.RespawnFields{Seq: 1}.Build()), wire.RefuseReasonNotDead, 1},
		{"cast_self", build(wire.CastSelfFields{Seq: 1, Ability: "missing"}.Build()), wire.RefuseReasonUnknownAbility, 1},
		{"cast_player", build(wire.CastPlayerFields{Seq: 1, Ability: "missing", Target: wire.PlayerId{Index: 2, Gen: 1}}.Build()), wire.RefuseReasonUnknownAbility, 1},
		{"cast_npc", build(wire.CastNpcFields{Seq: 1, Ability: "missing", Target: wire.NpcId{Index: 1000001, Gen: 1}}.Build()), wire.RefuseReasonUnknownAbility, 1},
		{"talk", build(wire.TalkFields{Seq: 1, Npc: wire.NpcId{Index: 1000001, Gen: 1}}.Build()), wire.RefuseReasonUnknownPlayer, 1},
		{"dialog_option", build(wire.DialogOptionFields{Seq: 1, Npc: wire.NpcId{Index: 1000001, Gen: 1}, Option: "stop_talking"}.Build()), wire.RefuseReasonNoDialog, 1},
		{"give", build(wire.GiveFields{Seq: 1, Npc: wire.NpcId{Index: 1000001, Gen: 1}, Slot: 0}.Build()), wire.RefuseReasonUnknownPlayer, 1},
		{"party_invite", build(wire.PartyInviteFields{Seq: 1, Player: wire.PlayerId{Index: 1, Gen: 1}}.Build()), wire.RefuseReasonSelf, 1},
		{"party_accept", build(wire.PartyAcceptFields{Seq: 1}.Build()), wire.RefuseReasonNoInvite, 1},
		{"party_decline", build(wire.PartyDeclineFields{Seq: 1}.Build()), wire.RefuseReasonNoInvite, 1},
		{"party_leave", build(wire.PartyLeaveFields{Seq: 1}.Build()), wire.RefuseReasonNotInParty, 1},
		{"party_kick", build(wire.PartyKickFields{Seq: 1, Player: wire.PlayerId{Index: 2, Gen: 1}}.Build()), wire.RefuseReasonNotInParty, 1},
		{"admin", build(wire.AdminFields{Seq: 1, Line: "/help"}.Build()), wire.RefuseReasonUnauthorized, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w, sessions, plan := fixture(t)
			p := newPair(t, netsim.Clean, 357)
			data, e := tc.msg.Append(nil)
			if e != nil {
				t.Fatal(e)
			}
			if e = p.cs.Send(data); e != nil {
				t.Fatal(e)
			}
			var got []wire.EventsMsg
			handled := false
			for i := 0; i < 20; i++ {
				p.turn(t, func(data []byte) {
					m, e := wire.DecodeIntents(data)
					if e != nil {
						t.Fatal(e)
					}
					if e = intents.Apply(w, sessions, 7, plan.Epoch, m); e != nil {
						t.Fatal(e)
					}
					handled = true
					if e = sessions.AppendAt(1, w.TakeOwnerChanges()); e != nil {
						t.Fatal(e)
					}
					if _, e = sessions.CloseTick(7, plan.Epoch, 1, 0, p.ss); e != nil {
						t.Fatal(e)
					}
				}, func(data []byte) {
					m, e := wire.DecodeEvents(data)
					if e != nil {
						t.Fatal(e)
					}
					got = append(got, m)
				})
			}
			if !handled || len(got) != tc.events+1 {
				t.Fatalf("handled=%v events=%v", handled, got)
			}
			refusal, ok := got[0].(wire.Refused)
			if !ok {
				t.Fatalf("first event %T", got[0])
			}
			if refusal.Stream() != 88 || refusal.EventSeq() != 1 || refusal.Tick() != 1 || refusal.Source() != wire.OriginSourceIntent || refusal.Seq() != 1 || refusal.Reason() != tc.reason {
				t.Fatalf("refusal %v", refusal)
			}
			close, ok := got[len(got)-1].(wire.TickClose)
			if !ok || close.EventEnd() != uint64(tc.events) || close.StateItems() != 0 {
				t.Fatalf("close %v", got[len(got)-1])
			}
		})
	}
}
func TestInputOriginThroughTransportAndGame(t *testing.T) {
	w, sessions, plan := fixture(t)
	p := newPair(t, netsim.Clean, 357)
	input := build(wire.InputFields{Seq: 17, Dx: 0, Dz: 0, Jump: true}.Build())
	data, e := input.Append(nil)
	if e != nil {
		t.Fatal(e)
	}
	f, e := p.cs.Flush(1, transport.Unreliable{Stamp: 1, Items: [][]byte{data}})
	if e != nil {
		t.Fatal(e)
	}
	for _, d := range f.Datagrams {
		p.sim.Send(netsim.AToB, d, 1)
	}
	for _, d := range p.sim.Poll(netsim.AToB, 1) {
		got, e := p.sr.Receive(d.Packet)
		if e != nil {
			t.Fatal(e)
		}
		for _, b := range got.Unreliable.Items {
			m, e := wire.DecodeInput(b)
			if e != nil {
				t.Fatal(e)
			}
			if e = intents.ApplyInput(w, sessions, 7, plan.Epoch, m.(wire.Input)); e != nil {
				t.Fatal(e)
			}
		}
	}
	w.AdvanceTick()
	if e = intents.ApplyInput(w, sessions, 7, plan.Epoch, build(wire.InputFields{Seq: 18, Jump: true}.Build())); e != nil {
		t.Fatal(e)
	}
	if e = intents.ApplyInput(w, sessions, 7, plan.Epoch, build(wire.InputFields{Seq: 18, Jump: true}.Build())); e != nil {
		t.Fatal(e)
	}
	if e = intents.ApplyInput(w, sessions, 7, plan.Epoch, build(wire.InputFields{Seq: 17, Jump: true}.Build())); e != nil {
		t.Fatal(e)
	}
	changes := w.TakeOwnerChanges()
	if len(changes) != 1 {
		t.Fatalf("changes %v", changes)
	}
	if got := changes[0]; got.Tick != 2 || got.Value != (game.RefusedValue{Origin: game.Origin{Source: game.OriginInput, Seq: 18}, Reason: game.ReasonIllegalSample}) {
		t.Fatalf("input refusal %+v", got)
	}
}

func TestLossySessionResumeRetainsApplicationCursor(t *testing.T) {
	const seed uint64 = 35720261002
	t.Logf("seed=%d", seed)
	w, sessions, plan := fixture(t)
	p := newPair(t, netsim.Lossy5Pct, seed)
	var cursor uint64
	var applied []uint64
	handled := 0
	committed := false
	receive := func(data []byte) {
		m, e := wire.DecodeEvents(data)
		if e != nil {
			t.Fatal(e)
		}
		var seq uint64
		var tick uint32
		switch v := m.(type) {
		case wire.Refused:
			seq = v.EventSeq()
			tick = v.Tick()
			if v.Stream() != 88 || v.Source() != wire.OriginSourceIntent || v.Reason() != wire.RefuseReasonUnauthorized || uint64(v.Seq()) != (seq+1)/2 {
				t.Fatalf("seed=%d bad refusal %v", seed, v)
			}
		case wire.AdminReply:
			seq = v.EventSeq()
			tick = v.Tick()
			if v.Stream() != 88 || v.Text() != "deny: unauthorized" {
				t.Fatalf("seed=%d reply %v", seed, v)
			}
		default:
			return
		}
		expectedTick := uint32(1)
		if seq > 10 {
			expectedTick = 2
		}
		if tick != expectedTick {
			t.Fatalf("seed=%d sequence %d tick %d", seed, seq, tick)
		}
		if seq <= cursor {
			return
		}
		if seq != cursor+1 {
			t.Fatalf("seed=%d gap after %d got %d", seed, cursor, seq)
		}
		cursor = seq
		applied = append(applied, seq)
	}
	queue := func(first, last uint32) {
		for seq := first; seq <= last; seq++ {
			m := build(wire.AdminFields{Seq: seq, Line: "/help"}.Build())
			data, e := m.Append(nil)
			if e != nil {
				t.Fatal(e)
			}
			if e = p.cs.Send(data); e != nil {
				t.Fatal(e)
			}
		}
	}
	onIntent := func(data []byte) {
		m, e := wire.DecodeIntents(data)
		if e != nil {
			t.Fatal(e)
		}
		if e = intents.Apply(w, sessions, 7, plan.Epoch, m); e != nil {
			t.Fatal(e)
		}
		handled++
		if handled == 5 || handled == 10 {
			tick := uint32(1)
			if handled == 10 {
				tick = 2
			}
			if e = sessions.AppendAt(tick, w.TakeOwnerChanges()); e != nil {
				t.Fatal(e)
			}
			if _, e = sessions.CloseTick(7, plan.Epoch, tick, 0, p.ss); e != nil {
				t.Fatal(e)
			}
		}
	}
	queue(1, 5)
	for i := 0; i < 60; i++ {
		p.turn(t, onIntent, receive)
	}
	if handled != 5 || cursor != 10 {
		t.Fatalf("seed=%d first handled=%d cursor=%d", seed, handled, cursor)
	}
	journal, e := sessions.Journal(7)
	if e != nil || len(journal) != 10 {
		t.Fatalf("seed=%d receipt trimmed %+v %v", seed, journal, e)
	}
	w.AdvanceTick()
	queue(6, 10)
	for i := 0; i < 100 && handled < 10; i++ {
		p.turn(t, onIntent, receive)
	}
	if handled != 10 {
		t.Fatalf("seed=%d second handled=%d", seed, handled)
	}
	p.turn(t, onIntent, receive)
	if e = sessions.Suspend(7, plan.Epoch, 2); e != nil {
		t.Fatal(e)
	}
	plan, e = sessions.Attach(7, 9, 3)
	if e != nil {
		t.Fatal(e)
	}
	if plan.Stream != 88 || plan.Epoch != 2 || plan.NextIntent != 11 || plan.AppliedEvent != 0 || plan.EventEnd != 20 {
		t.Fatalf("seed=%d resume %+v", seed, plan)
	}
	p = newPair(t, netsim.Lossy5Pct, seed+1)
	if e = sessions.QueueResume(7, plan.Epoch, p.ss); e != nil {
		t.Fatal(e)
	}
	if _, e = sessions.CloseTick(7, plan.Epoch, 2, 0, p.ss); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 150; i++ {
		p.turn(t, func(data []byte) {
			m, e := wire.DecodeIntents(data)
			if e != nil {
				t.Fatal(e)
			}
			if e = intents.Apply(w, sessions, 7, plan.Epoch, m); e != nil {
				t.Fatal(e)
			}
			committed = true
		}, func(data []byte) {
			receive(data)
			m, e := wire.DecodeEvents(data)
			if e != nil {
				t.Fatal(e)
			}
			if close, ok := m.(wire.TickClose); ok {
				if cursor != 20 || close.Stream() != 88 || close.Epoch() != 2 || close.EventEnd() != 20 {
					t.Fatalf("seed=%d premature close %v cursor=%d", seed, close, cursor)
				}
				commit := build(wire.ApplicationCommitFields{Stream: 88, Epoch: 2, Tick: 2, EventEnd: 20}.Build())
				b, e := commit.Append(nil)
				if e != nil {
					t.Fatal(e)
				}
				if e = p.cs.Send(b); e != nil {
					t.Fatal(e)
				}
			}
		})
	}
	want := []uint64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	if !reflect.DeepEqual(applied, want) || !committed {
		t.Fatalf("seed=%d applications=%v committed=%v", seed, applied, committed)
	}
	journal, e = sessions.Journal(7)
	if e != nil || len(journal) != 0 {
		t.Fatalf("seed=%d committed journal %+v %v", seed, journal, e)
	}
}

func TestSuspendedPendingPickupProducesRetainedOwnerFact(t *testing.T) {
	w, sessions, plan := fixture(t)
	if err := w.SeedGroundItem("logs", game.VillageMap.SpawnX, game.VillageMap.SpawnZ); err != nil {
		t.Fatal(err)
	}
	p := newPair(t, netsim.Clean, 357)
	pickup := build(wire.PickupFields{Seq: 1, Item: wire.ItemId{Index: 1, Gen: 1}}.Build())
	data, err := pickup.Append(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = p.cs.Send(data); err != nil {
		t.Fatal(err)
	}
	handled := false
	p.turn(t, func(b []byte) {
		m, e := wire.DecodeIntents(b)
		if e != nil {
			t.Fatal(e)
		}
		if e = intents.Apply(w, sessions, 7, plan.Epoch, m); e != nil {
			t.Fatal(e)
		}
		handled = true
	}, func([]byte) { t.Fatal("unexpected event before pickup resolves") })
	if !handled {
		t.Fatal("pickup did not cross transport")
	}
	if err = sessions.AppendAt(1, w.TakeOwnerChanges()); err != nil {
		t.Fatal(err)
	}
	if err = sessions.Suspend(7, plan.Epoch, 1); err != nil {
		t.Fatal(err)
	}
	w.AdvanceTick()
	if err = sessions.AppendAt(2, w.TakeOwnerChanges()); err != nil {
		t.Fatal(err)
	}
	journal, err := sessions.Journal(7)
	if err != nil {
		t.Fatal(err)
	}
	want := []eventstream.Fact{{Seq: 1, Tick: 2, Value: game.InventoryValue{Size: 28, Slots: []game.BagEntry{{Slot: 0, Kind: "logs"}}}}}
	if !reflect.DeepEqual(journal, want) {
		t.Fatalf("suspended producer %+v want %+v", journal, want)
	}
	plan, err = sessions.Attach(7, 9, 3)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Epoch != 2 || plan.EventEnd != 1 || plan.NextIntent != 2 {
		t.Fatalf("resume %+v", plan)
	}
	if err = sessions.Suspend(7, plan.Epoch, 3); err != nil {
		t.Fatal(err)
	}
	owners := sessions.Expire(1503)
	if len(owners) != 1 {
		t.Fatalf("expired handles %+v", owners)
	}
	if err = w.ReleaseOwner(owners[0]); err != nil {
		t.Fatal(err)
	}
	if err = w.ApplyAction(owners[0], game.Origin{Source: game.OriginIntent, Seq: 2}, game.DropAction{}); err != game.ErrOwner {
		t.Fatalf("retired owner action %v", err)
	}
}

func TestCommitCannotBypassInboundEpochBinding(t *testing.T) {
	w, sessions, plan := fixture(t)
	if err := sessions.AppendAt(1, nil); err != nil {
		t.Fatal(err)
	}
	if err := sessions.Suspend(7, plan.Epoch, 1); err != nil {
		t.Fatal(err)
	}
	plan, err := sessions.Attach(7, 9, 2)
	if err != nil {
		t.Fatal(err)
	}
	p := newPair(t, netsim.Clean, 357)
	if _, err = sessions.CloseTick(7, plan.Epoch, 1, 0, p.ss); err != nil {
		t.Fatal(err)
	}
	commit := build(wire.ApplicationCommitFields{Stream: 88, Epoch: 2, Tick: 1, EventEnd: 0}.Build())
	if err = intents.Apply(w, sessions, 7, 1, commit); err != eventstream.ErrEpoch {
		t.Fatalf("stale inbound envelope committed %v", err)
	}
	if err = intents.Apply(w, sessions, 7, 2, commit); err != nil {
		t.Fatal(err)
	}
}
