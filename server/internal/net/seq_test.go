package net_test

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestADuplicateDropSpawnsOneItem(t *testing.T) {
	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	seeded := alice.welcome().Items[0].ID

	alice.pickup(seeded)
	held := alice.awaitInventory()
	if len(held.Slots) != 1 {
		t.Fatalf("alice holds %+v before the drop, want one acorn", held.Slots)
	}
	alice.drain()

	retried := fmt.Sprintf(`{"drop":{"slot":%d,"seq":5}}`, held.Slots[0].Slot)
	alice.sendRaw(retried)
	alice.sendRaw(retried)

	var spawns, inventories int
	for _, f := range alice.collect(silenceWindow) {
		switch {
		case f.ItemSpawn != nil:
			spawns++
		case f.Inventory != nil:
			inventories++
		case f.Error != nil:
			t.Fatalf("the retried drop was answered with %s; a duplicate is answered with nothing at all, "+
				"because an error naming it would be an ack wearing a different hat", f.raw)
		default:
			t.Fatalf("a %s frame arrived after the retried drop: %s", f.kind(), f.raw)
		}
	}
	if spawns != 1 {
		t.Fatalf("the retried drop put %d acorns on the ground, want 1", spawns)
	}
	if inventories != 1 {
		t.Fatalf("the retried drop restated alice's inventory %d times, want 1", inventories)
	}

	duplicates := h.awaitEvents(game.EvIntentDuplicate, 1)
	if len(duplicates) != 1 {
		t.Fatalf("%d %s events, want exactly 1", len(duplicates), game.EvIntentDuplicate)
	}
	if got := duplicates[0]["re"]; got != mnet.MsgDrop {
		t.Errorf("%s names %v, want %q", game.EvIntentDuplicate, got, mnet.MsgDrop)
	}
	if got := duplicates[0]["seq"]; got != float64(5) {
		t.Errorf("%s names seq %v, want 5", game.EvIntentDuplicate, got)
	}
	if got := duplicates[0]["last_seq"]; got != float64(5) {
		t.Errorf("%s names last_seq %v, want 5: the first drop is what consumed it", game.EvIntentDuplicate, got)
	}

	dropped := h.eventsNamed(game.EvDrop)
	if len(dropped) != 1 {
		t.Fatalf("%d %s events, want exactly 1", len(dropped), game.EvDrop)
	}
	if got := dropped[0]["seq"]; got != float64(5) {
		t.Errorf("%s names seq %v, want 5: a reader of the log tells a first application from a retry "+
			"by this field alone", game.EvDrop, got)
	}
}

func TestAResumedPlayerRemembersItsSequenceNumber(t *testing.T) {
	h := newHarness(t, acornAt(underfoot, 0))

	alice := h.dial("alice")
	first := alice.welcome()
	if first.LastSeq != 0 {
		t.Fatalf("a fresh join was welcomed with last_seq %d, want 0", first.LastSeq)
	}
	seeded := first.Items[0].ID

	taking := fmt.Sprintf(`{"pickup":{"item":%d,"seq":1}}`, seeded)
	alice.sendRaw(taking)
	if held := alice.awaitInventory(); len(held.Slots) != 1 || held.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("alice holds %+v before the socket dies, want one acorn", held.Slots)
	}

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	time.Sleep(waitInsideTheGrace)

	resumed := h.dialResume("alice-again", first.Session)
	step := readJoinStep(resumed)
	if step.welcome.LastSeq != 1 {
		t.Fatalf("the resumed welcome says last_seq %d, want 1; there are no acks, so this field is the only "+
			"thing that tells a reconnecting client where its numbering stands", step.welcome.LastSeq)
	}
	if len(step.inventory.Slots) != 1 || step.inventory.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("the resumed inventory holds %+v, want the one acorn alice took", step.inventory.Slots)
	}

	resumed.sendRaw(taking)
	h.awaitEvents(game.EvIntentDuplicate, 1)

	resumed.expectSilence()
	if taken := h.eventsNamed(game.EvPickup); len(taken) != 1 {
		t.Fatalf("%d %s events across the resume, want exactly 1: the retry must not reach the world",
			len(taken), game.EvPickup)
	}
}

func TestALowerSequenceNumberIsDroppedAndAGapIsAccepted(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.sendRaw(`{"move":{"dx":1,"dz":0,"seq":3}}`)
	first := alice.awaitPose()
	if first.X <= 0 {
		t.Fatalf("first pose x=%v, want progress along +x", first.X)
	}

	alice.sendRaw(`{"move":{"dx":-1,"dz":0,"seq":2}}`)
	h.awaitEvents(game.EvIntentDuplicate, 1)
	moved := h.eventsNamed(game.EvMove)
	if len(moved) != 1 {
		t.Fatalf("%d %s events after a seq below the mark, want 1", len(moved), game.EvMove)
	}

	alice.sendRaw(`{"move":{"dx":0,"dz":1,"seq":10}}`)
	second := alice.awaitPose()
	if second.Tick <= first.Tick {
		t.Fatalf("pose after gap tick %d, want after %d", second.Tick, first.Tick)
	}
	if len(h.eventsNamed(game.EvMove)) != 2 {
		t.Fatalf("%d %s events after the gap, want 2", len(h.eventsNamed(game.EvMove)), game.EvMove)
	}
}

func TestAnUnsequencedIntentAfterASequencedOneIsApplied(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()

	alice.sendRaw(`{"move":{"dx":1,"dz":0,"seq":10}}`)
	alice.awaitPose()

	alice.walkTo(2, 2)
	if math.Hypot(alice.x-2, alice.z-2) > tickStep*1.5 {
		t.Fatalf("unsequenced walk ended at (%v,%v), want near [2 2]", alice.x, alice.z)
	}

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	time.Sleep(waitInsideTheGrace)

	step := readJoinStep(h.dialResume("alice-again", first.Session))
	if step.welcome.LastSeq != 10 {
		t.Fatalf("the resumed welcome says last_seq %d, want 10; an unsequenced frame is applied without "+
			"touching the mark, and a client that read 0 here would renumber from scratch",
			step.welcome.LastSeq)
	}
}

func TestAMalformedSequenceNumberIsRefusedAndTheConnectionSurvives(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	frames := []string{
		`{"move":{"dx":1,"dz":1,"seq":0}}`,
		`{"move":{"dx":1,"dz":1,"seq":-1}}`,
		`{"move":{"dx":1,"dz":1,"seq":1.5}}`,
		`{"move":{"dx":1,"dz":1,"seq":"7"}}`,
	}
	for _, frame := range frames {
		alice.sendRaw(frame)
		if refusal := alice.awaitError(); refusal.Re != mnet.MsgMove {
			t.Fatalf("%s: the error is attributed to %q, want %q", frame, refusal.Re, mnet.MsgMove)
		}
	}

	alice.walkTo(4, 6)
	if math.Hypot(alice.x-4, alice.z-6) > tickStep*1.5 {
		t.Fatalf("after four bad sequence numbers ended at (%v,%v), want near [4 6]", alice.x, alice.z)
	}

	rejected := h.awaitEvents(game.EvMoveRejected, len(frames))
	if len(rejected) != len(frames) {
		t.Fatalf("%d %s events, want %d", len(rejected), game.EvMoveRejected, len(frames))
	}
	for i, ev := range rejected {
		if got := ev["reason"]; got != string(mnet.ReasonMalformedJSON) {
			t.Errorf("%s was rejected with reason %v, want %q", frames[i], got, mnet.ReasonMalformedJSON)
		}
	}
}

func TestARefusedIntentStillConsumesItsSequenceNumber(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()

	alice.sendRaw(`{"move_to":{"x":999,"z":0,"seq":8}}`)
	if refusal := alice.awaitError(); refusal.Re != mnet.MsgMoveTo {
		t.Fatalf("the error is attributed to %q, want %q", refusal.Re, mnet.MsgMoveTo)
	}
	rejected := h.awaitEvents(game.EvMoveToRejected, 1)
	if got := rejected[0]["reason"]; got != string(mnet.ReasonIllegalSample) {
		t.Fatalf("move_to was rejected with reason %v, want %q", got, mnet.ReasonIllegalSample)
	}

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	time.Sleep(waitInsideTheGrace)

	step := readJoinStep(h.dialResume("alice-again", first.Session))
	if step.welcome.LastSeq != 8 {
		t.Fatalf("the resumed welcome says last_seq %d, want 8; the intent was received and decided, and "+
			"its retry would be refused for the same reason", step.welcome.LastSeq)
	}
}
