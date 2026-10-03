package eventstream

import (
	"errors"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"reflect"
	"strings"
	"testing"
)

func collection(t *testing.T, cfg Config) (*Sessions, Epoch, *transport.Sender) {
	t.Helper()
	ss, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err = ss.Create(7, 9, 88, game.PlayerHandle{Index: 1, Gen: 1}, 0); err != nil {
		t.Fatal(err)
	}
	plan, err := ss.Attach(7, 9, 0)
	if err != nil {
		t.Fatal(err)
	}
	sender, err := transport.NewSender(transport.Server, transport.DefaultConfig(wire.SchemaHash), transport.Plain{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	return ss, plan.Epoch, sender
}
func change(tick uint32, value game.OwnerValue) game.OwnerChange {
	return game.OwnerChange{Player: game.PlayerHandle{Index: 1, Gen: 1}, Tick: tick, Value: value}
}
func TestOfferedApplicationCommitControlsJournal(t *testing.T) {
	ss, epoch, sender := collection(t, DefaultConfig())
	if err := ss.Commit(7, Commit{Stream: 88, Epoch: epoch}); !errors.Is(err, ErrCommit) {
		t.Fatalf("unoffered zero commit %v", err)
	}
	if err := ss.AppendAt(1, []game.OwnerChange{change(1, game.AdminReplyValue{Text: "one"})}); err != nil {
		t.Fatal(err)
	}
	b, err := ss.CloseTick(7, epoch, 1, 3, sender)
	if err != nil {
		t.Fatal(err)
	}
	if b != (Boundary{Stream: 88, Epoch: 1, Tick: 1, EventEnd: 1, StateItems: 3}) {
		t.Fatalf("boundary %+v", b)
	}
	sender.Observe(transport.AckWindow{Latest: 0}, transport.NoAcks, 1)
	if got, err := ss.Journal(7); err != nil || len(got) != 1 {
		t.Fatalf("packet receipt removed journal %+v %v", got, err)
	}
	for _, c := range []Commit{{Stream: 89, Epoch: epoch, Tick: 1, EventEnd: 1}, {Stream: 88, Epoch: 2, Tick: 1, EventEnd: 1}, {Stream: 88, Epoch: epoch, Tick: 2, EventEnd: 1}, {Stream: 88, Epoch: epoch, Tick: 1, EventEnd: 2}, {Stream: 88, Epoch: epoch, Tick: 1, EventEnd: 0}} {
		if err := ss.Commit(7, c); err == nil {
			t.Fatalf("accepted forged commit %+v", c)
		}
	}
	c := Commit{Stream: 88, Epoch: epoch, Tick: 1, EventEnd: 1}
	if err := ss.Commit(7, c); err != nil {
		t.Fatal(err)
	}
	if err := ss.Commit(7, c); err != nil {
		t.Fatal(err)
	}
	if got, err := ss.Journal(7); err != nil || len(got) != 0 {
		t.Fatalf("commit journal %+v %v", got, err)
	}
	if err := ss.AppendAt(2, nil); err != nil {
		t.Fatal(err)
	}
	b, err = ss.CloseTick(7, epoch, 2, 0, sender)
	if err != nil {
		t.Fatal(err)
	}
	if b.Tick != 2 || b.EventEnd != 1 || b.StateItems != 0 {
		t.Fatalf("empty close %+v", b)
	}
	if _, err = ss.CloseTick(7, epoch, 2, 0, sender); err != nil {
		t.Fatal(err)
	}
	if _, err = ss.CloseTick(7, epoch, 2, 1, sender); !errors.Is(err, ErrTick) {
		t.Fatalf("changed duplicate close %v", err)
	}
}
func TestIntentSequenceAndResumeAccountEpoch(t *testing.T) {
	ss, epoch, _ := collection(t, DefaultConfig())
	canonical := []byte{1, 2, 3}
	yes, err := ss.AcceptIntent(7, epoch, 1, canonical)
	if err != nil || !yes {
		t.Fatalf("first %v %v", yes, err)
	}
	canonical[0] = 9
	if yes, err = ss.AcceptIntent(7, epoch, 1, []byte{1, 2, 3}); err != nil || yes {
		t.Fatalf("duplicate %v %v", yes, err)
	}
	if _, err = ss.AcceptIntent(7, epoch, 1, canonical); !errors.Is(err, ErrSequence) {
		t.Fatalf("changed duplicate %v", err)
	}
	if _, err = ss.AcceptIntent(7, epoch, 3, canonical); !errors.Is(err, ErrSequence) {
		t.Fatalf("gap %v", err)
	}
	if _, err = ss.Attach(7, 9, 1); !errors.Is(err, ErrConnected) {
		t.Fatalf("live duplicate %v", err)
	}
	if err = ss.Suspend(7, epoch, 1); err != nil {
		t.Fatal(err)
	}
	if _, err = ss.Attach(7, 10, 2); !errors.Is(err, ErrAccount) {
		t.Fatalf("account %v", err)
	}
	plan, err := ss.Attach(7, 9, 2)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Stream != 88 || plan.Epoch != 2 || plan.NextIntent != 2 || !plan.FullStateRequired {
		t.Fatalf("resume %+v", plan)
	}
	if _, err = ss.Resolve(7, epoch); !errors.Is(err, ErrEpoch) {
		t.Fatalf("stale epoch %v", err)
	}
	if err = ss.Suspend(7, plan.Epoch, 2); err != nil {
		t.Fatal(err)
	}
	if _, err = ss.Attach(7, 9, 1502); !errors.Is(err, ErrSession) {
		t.Fatalf("expired %v", err)
	}
	if got := ss.Expire(1502); !reflect.DeepEqual(got, []game.PlayerHandle{{Index: 1, Gen: 1}}) {
		t.Fatalf("expired owners %+v", got)
	}
	if err = ss.Create(7, 9, 88, game.PlayerHandle{Index: 2, Gen: 1}, 1502); !errors.Is(err, ErrSession) {
		t.Fatalf("reused stream %v", err)
	}
	if err = ss.Create(7, 9, 89, game.PlayerHandle{Index: 2, Gen: 1}, 1502); err != nil {
		t.Fatal(err)
	}
}
func TestAtomicTickValidationBudgetAndValueOwnership(t *testing.T) {
	ss, _, _ := collection(t, DefaultConfig())
	value := game.InventoryValue{Size: 28, Slots: []game.BagEntry{{Slot: 0, Kind: "logs"}}}
	changes := []game.OwnerChange{change(1, value)}
	if err := ss.AppendAt(1, changes); err != nil {
		t.Fatal(err)
	}
	if err := ss.AppendAt(1, changes); err != nil {
		t.Fatal(err)
	}
	value.Slots[0].Kind = "changed"
	journal, err := ss.Journal(7)
	if err != nil {
		t.Fatal(err)
	}
	if journal[0].Value.(game.InventoryValue).Slots[0].Kind != "logs" {
		t.Fatalf("aliased input %+v", journal)
	}
	journal[0].Value.(game.InventoryValue).Slots[0].Kind = "reader mutation"
	journal, err = ss.Journal(7)
	if err != nil {
		t.Fatal(err)
	}
	if journal[0].Value.(game.InventoryValue).Slots[0].Kind != "logs" {
		t.Fatalf("aliased output %+v", journal)
	}
	invalid := []game.OwnerChange{change(2, game.AdminReplyValue{Text: "valid"}), change(2, game.AdminReplyValue{Text: strings.Repeat("x", 8193)})}
	if err = ss.AppendAt(2, invalid); err == nil {
		t.Fatal("accepted oversized producer")
	}
	journal, err = ss.Journal(7)
	if err != nil || len(journal) != 1 || journal[0].Seq != 1 {
		t.Fatalf("partial invalid append %+v %v", journal, err)
	}
	cfg := DefaultConfig()
	cfg.JournalEvents = 1
	limited, _, _ := collection(t, cfg)
	if err = limited.AppendAt(1, []game.OwnerChange{change(1, game.AdminReplyValue{Text: "a"}), change(1, game.AdminReplyValue{Text: "b"})}); !errors.Is(err, ErrCapacity) {
		t.Fatalf("event cap %v", err)
	}
	if _, err = limited.Journal(7); !errors.Is(err, ErrSession) {
		t.Fatalf("overflow remains resumable %v", err)
	}
	cfg = DefaultConfig()
	cfg.JournalBytes = 1
	limited, _, _ = collection(t, cfg)
	if err = limited.AppendAt(1, []game.OwnerChange{change(1, game.AdminReplyValue{Text: "a"})}); !errors.Is(err, ErrCapacity) {
		t.Fatalf("byte cap %v", err)
	}
	cfg = DefaultConfig()
	cfg.OfferedTicks = 1
	limited, epoch, sender := collection(t, cfg)
	if err = limited.AppendAt(1, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = limited.CloseTick(7, epoch, 1, 0, sender); err != nil {
		t.Fatal(err)
	}
	if err = limited.AppendAt(2, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = limited.CloseTick(7, epoch, 2, 0, sender); !errors.Is(err, ErrCapacity) {
		t.Fatalf("offered cap %v", err)
	}
}

func TestSlowOwnerCannotLoseAnotherOwnersTick(t *testing.T) {
	cfg := DefaultConfig()
	cfg.JournalEvents = 1
	ss, epoch, _ := collection(t, cfg)
	second := game.PlayerHandle{Index: 2, Gen: 1}
	if err := ss.Create(8, 10, 89, second, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := ss.Attach(8, 10, 0); err != nil {
		t.Fatal(err)
	}
	if err := ss.AppendAt(1, []game.OwnerChange{change(1, game.AdminReplyValue{Text: "old"})}); err != nil {
		t.Fatal(err)
	}
	batch := []game.OwnerChange{change(2, game.AdminReplyValue{Text: "slow"}), {Player: second, Tick: 2, Value: game.AdminReplyValue{Text: "healthy"}}}
	err := ss.AppendAt(2, batch)
	var capacity *CapacityError
	if !errors.As(err, &capacity) || !reflect.DeepEqual(capacity.RetiredOwners, []game.PlayerHandle{{Index: 1, Gen: 1}}) {
		t.Fatalf("capacity result %+v %v", capacity, err)
	}
	healthy, err := ss.Journal(8)
	if err != nil || !reflect.DeepEqual(healthy, []Fact{{Seq: 1, Tick: 2, Value: game.AdminReplyValue{Text: "healthy"}}}) {
		t.Fatalf("healthy journal %+v %v", healthy, err)
	}
	if err = ss.AppendAt(2, batch); err != nil {
		t.Fatalf("same tick retry %v", err)
	}
	healthy, err = ss.Journal(8)
	if err != nil || len(healthy) != 1 {
		t.Fatalf("retry duplicated journal %+v %v", healthy, err)
	}
	if _, err = ss.AcceptIntent(8, epoch, 1, []byte(strings.Repeat("x", MaxCanonicalIntentBytes+1))); !errors.Is(err, ErrSequence) {
		t.Fatalf("oversized canonical command %v", err)
	}
}

func TestWireBoundaryPayloadSizes(t *testing.T) {
	ss, epoch, sender := collection(t, DefaultConfig())
	if err := ss.AppendAt(1, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := ss.CloseTick(7, epoch, 1, 0, sender); err != nil {
		t.Fatal(err)
	}
	close, e := built(wire.TickCloseFields{Stream: 88, Epoch: 1, Tick: 1, EventEnd: 0, StateItems: 0}.Build())
	if e != nil {
		t.Fatal(e)
	}
	resume, e := built(wire.ResumeBoundaryFields{Stream: 88, Epoch: 1, Tick: 1, EventEnd: 0, AppliedEvent: 0, NextIntent: 1}.Build())
	if e != nil {
		t.Fatal(e)
	}
	refusal, e := encode(88, 1, 1, game.RefusedValue{Origin: game.Origin{Source: game.OriginIntent, Seq: 1}, Reason: game.ReasonDead})
	if e != nil {
		t.Fatal(e)
	}
	if len(close) != 32 || len(resume) != 42 || len(refusal) != 28 {
		t.Fatalf("close=%d resume=%d refusal=%d", len(close), len(resume), len(refusal))
	}
	t.Logf("close=32 bytes, resume=42 bytes, refusal=28 bytes; 25Hz empty closes=800 payload bytes/s")
}

func TestCloseCertifiesTrimmedAndEmptyActualFlush(t *testing.T) {
	ss, epoch, _ := collection(t, DefaultConfig())
	cfg := transport.DefaultConfig(wire.SchemaHash)
	cfg.TickBudget = 1200
	sender, err := transport.NewSender(transport.Server, cfg, transport.Plain{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	receiver, err := transport.NewReceiver(transport.Client, cfg, transport.Plain{})
	if err != nil {
		t.Fatal(err)
	}
	hp, err := built(wire.HpFields{Id: wire.PlayerId{Index: 1, Gen: 1}, Hp: 42, MaxHp: 120}.Build())
	if err != nil {
		t.Fatal(err)
	}
	draft := make([][]byte, 100)
	for i := range draft {
		draft[i] = hp
	}
	if err = ss.AppendAt(1, nil); err != nil {
		t.Fatal(err)
	}
	flushed, err := sender.Flush(1, transport.Unreliable{Stamp: 1, Items: draft})
	if err != nil {
		t.Fatal(err)
	}
	if flushed.UnreliableSent != 97 {
		t.Fatalf("actual trimmed count %d want97", flushed.UnreliableSent)
	}
	count := 0
	for _, packet := range flushed.Datagrams {
		got, e := receiver.Receive(packet)
		if e != nil {
			t.Fatal(e)
		}
		count += len(got.Unreliable.Items)
	}
	if count != 97 {
		t.Fatalf("received actual slice count %d", count)
	}
	boundary, err := ss.CloseTick(7, epoch, 1, flushed.UnreliableSent, sender)
	if err != nil {
		t.Fatal(err)
	}
	if boundary.StateItems != 97 {
		t.Fatalf("close certified draft instead of actual %+v", boundary)
	}
	closed, err := sender.Flush(2, transport.Unreliable{})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, packet := range closed.Datagrams {
		got, e := receiver.Receive(packet)
		if e != nil {
			t.Fatal(e)
		}
		for _, data := range got.Reliable {
			message, e := wire.DecodeEvents(data)
			if e != nil {
				t.Fatal(e)
			}
			if close, ok := message.(wire.TickClose); ok {
				found = true
				if close.StateItems() != 97 || close.Tick() != 1 || close.EventEnd() != 0 {
					t.Fatalf("wire close %v", close)
				}
			}
		}
	}
	if !found {
		t.Fatal("actual count close not transported")
	}
	fresh, err := transport.NewSender(transport.Server, cfg, transport.Plain{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err = ss.AppendAt(2, []game.OwnerChange{change(2, game.AdminReplyValue{Text: strings.Repeat("x", 1130)})}); err != nil {
		t.Fatal(err)
	}
	if err = ss.QueueEvents(7, epoch, fresh); err != nil {
		t.Fatal(err)
	}
	flushed, err = fresh.Flush(1, transport.Unreliable{Stamp: 2, Items: draft})
	if err != nil {
		t.Fatal(err)
	}
	if flushed.UnreliableSent != 0 {
		t.Fatalf("reliable-first empty actual count %d", flushed.UnreliableSent)
	}
	boundary, err = ss.CloseTick(7, epoch, 2, flushed.UnreliableSent, fresh)
	if err != nil {
		t.Fatal(err)
	}
	if boundary.Tick != 2 || boundary.EventEnd != 1 || boundary.StateItems != 0 {
		t.Fatalf("empty actual close %+v", boundary)
	}
	emptyReceiver, err := transport.NewReceiver(transport.Client, cfg, transport.Plain{})
	if err != nil {
		t.Fatal(err)
	}
	for _, packet := range flushed.Datagrams {
		if _, err = emptyReceiver.Receive(packet); err != nil {
			t.Fatal(err)
		}
	}
	final, err := fresh.Flush(2, transport.Unreliable{})
	if err != nil {
		t.Fatal(err)
	}
	emptyFound := false
	for _, packet := range final.Datagrams {
		got, e := emptyReceiver.Receive(packet)
		if e != nil {
			t.Fatal(e)
		}
		for _, data := range got.Reliable {
			m, e := wire.DecodeEvents(data)
			if e != nil {
				t.Fatal(e)
			}
			if close, ok := m.(wire.TickClose); ok {
				emptyFound = true
				if close.Tick() != 2 || close.EventEnd() != 1 || close.StateItems() != 0 {
					t.Fatalf("transported empty close %v", close)
				}
			}
		}
	}
	if !emptyFound {
		t.Fatal("empty actual flush close was not transported")
	}

}

func TestEquipmentMetadataAndSkillsAreOwnedAcrossJournalReads(t *testing.T) {
	ss, _, _ := collection(t, DefaultConfig())
	equipment := game.EquipmentValue{Worn: []string{"helmet", "left hand", "chest", "right hand", "feet", "trousers"}, Slots: []game.WornEntry{{Slot: "helmet", Kind: "forester_cap"}}}
	skills := game.SkillsValue{Skills: []game.SkillEntry{{ID: "woodcutting", XP: 10, Level: 1}}}
	if err := ss.AppendAt(1, []game.OwnerChange{change(1, equipment), change(1, skills)}); err != nil {
		t.Fatal(err)
	}
	equipment.Worn[0] = "poison"
	equipment.Slots[0].Kind = "poison"
	skills.Skills[0].XP = 999
	values, err := ss.Journal(7)
	if err != nil {
		t.Fatal(err)
	}
	wantEquipment := game.EquipmentValue{Worn: []string{"helmet", "left hand", "chest", "right hand", "feet", "trousers"}, Slots: []game.WornEntry{{Slot: "helmet", Kind: "forester_cap"}}}
	wantSkills := game.SkillsValue{Skills: []game.SkillEntry{{ID: "woodcutting", XP: 10, Level: 1}}}
	if !reflect.DeepEqual(values[0].Value, wantEquipment) || !reflect.DeepEqual(values[1].Value, wantSkills) {
		t.Fatalf("producer aliased journal %+v", values)
	}
	values[0].Value.(game.EquipmentValue).Worn[0] = "reader poison"
	values[1].Value.(game.SkillsValue).Skills[0].XP = 999
	values, err = ss.Journal(7)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(values[0].Value, wantEquipment) || !reflect.DeepEqual(values[1].Value, wantSkills) {
		t.Fatalf("reader aliased journal %+v", values)
	}
}
