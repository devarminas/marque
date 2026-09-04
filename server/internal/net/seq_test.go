package net_test

// Sequence numbers and the dedupe they buy, driven through real WebSocket
// clients against a real server. PROTOCOL.md, "Sequence numbers", is the
// contract.
//
// The unit exists so that a client which retries an intent it is unsure landed
// does not pay for the retry twice, and the tests are written from that side:
// what a duplicate must not spawn, must not answer, and must not log.

import (
	"fmt"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// TestADuplicateDropSpawnsOneItem is the unit's reason to exist. A drop is the
// one intent whose retry is unambiguously destructive: applied twice it takes a
// second slot and puts a second body in the world, and no restatement the
// client receives afterwards would say which of the two it asked for.
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

	// Counted as a whole set rather than one frame at a time: every claim here
	// is about what did not arrive, and no positive assertion can show that.
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

// TestAResumedPlayerRemembersItsSequenceNumber is what makes last_seq a
// property of the player rather than of the socket. A mark that reset on
// reconnect would dedupe nothing across the one failure retries exist for.
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

	// The item is long gone from the ground, so a re-applied pickup would be
	// refused as unknown_item and the refusal would arrive here. Silence is
	// what says the frame never reached the world's pickup at all.
	resumed.expectSilence()
	if taken := h.eventsNamed(game.EvPickup); len(taken) != 1 {
		t.Fatalf("%d %s events across the resume, want exactly 1: the retry must not reach the world",
			len(taken), game.EvPickup)
	}
}

// TestALowerSequenceNumberIsDroppedAndAGapIsAccepted pins the mark as a
// high-water mark rather than a set of what has been seen. A gap is accepted
// because nothing here can express "4 through 9 are still coming", and nothing
// needs it to: the client is the only thing that knows what it skipped.
func TestALowerSequenceNumberIsDroppedAndAGapIsAccepted(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.sendRaw(`{"move_to":{"x":5,"z":5,"seq":3}}`)
	if got := alice.path(); got.Points[len(got.Points)-1] != mnet.Pt(5, 5) {
		t.Fatalf("the first path ends at %v, want [5 5]", got.Points[len(got.Points)-1])
	}

	alice.sendRaw(`{"move_to":{"x":-5,"z":-5,"seq":2}}`)
	h.awaitEvents(game.EvIntentDuplicate, 1)
	if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 1 {
		t.Fatalf("%d %s events after a seq below the mark, want 1: an arrival the server has already "+
			"passed is not a new intent", len(assigned), game.EvPathAssigned)
	}

	alice.sendRaw(`{"move_to":{"x":7,"z":7,"seq":10}}`)
	if got := alice.path(); got.Points[len(got.Points)-1] != mnet.Pt(7, 7) {
		t.Fatalf("the path after the gap ends at %v, want [7 7]", got.Points[len(got.Points)-1])
	}
	if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 2 {
		t.Fatalf("%d %s events after the gap, want 2", len(assigned), game.EvPathAssigned)
	}
}

// TestAnUnsequencedIntentAfterASequencedOneIsApplied is the compatibility
// claim, and it is the one that decides whether this unit can ship before the
// client sends any numbers at all. Absent is unsequenced, never a seq of zero,
// and it neither advances the mark nor is measured against it.
func TestAnUnsequencedIntentAfterASequencedOneIsApplied(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()

	alice.sendRaw(`{"move_to":{"x":100,"z":0,"seq":10}}`)
	alice.path()

	alice.moveTo(2, 2)
	if got := alice.path(); got.Points[len(got.Points)-1] != mnet.Pt(2, 2) {
		t.Fatalf("the unsequenced click produced a path to %v, want [2 2]", got.Points[len(got.Points)-1])
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

// TestAMalformedSequenceNumberIsRefusedAndTheConnectionSurvives covers the four
// shapes a client can get wrong. Zero is the one worth staging deliberately: it
// is refused rather than read as absent, because a client that computed a
// sequence number and got zero has a bug the server should name.
func TestAMalformedSequenceNumberIsRefusedAndTheConnectionSurvives(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	frames := []string{
		`{"move_to":{"x":1,"z":1,"seq":0}}`,
		`{"move_to":{"x":1,"z":1,"seq":-1}}`,
		`{"move_to":{"x":1,"z":1,"seq":1.5}}`,
		`{"move_to":{"x":1,"z":1,"seq":"7"}}`,
	}
	for _, frame := range frames {
		alice.sendRaw(frame)
		if refusal := alice.awaitError(); refusal.Re != mnet.MsgMoveTo {
			t.Fatalf("%s: the error is attributed to %q, want %q", frame, refusal.Re, mnet.MsgMoveTo)
		}
	}

	alice.moveTo(4, 6)
	if got := alice.path(); got.Points[len(got.Points)-1] != mnet.Pt(4, 6) {
		t.Fatalf("after four bad sequence numbers the path ends at %v, want [4 6]: a broken frame is a "+
			"broken frame, not a broken client", got.Points[len(got.Points)-1])
	}

	rejected := h.awaitEvents(game.EvMoveToRejected, len(frames))
	if len(rejected) != len(frames) {
		t.Fatalf("%d %s events, want %d", len(rejected), game.EvMoveToRejected, len(frames))
	}
	for i, ev := range rejected {
		if got := ev["reason"]; got != string(mnet.ReasonMalformedJSON) {
			t.Errorf("%s was rejected with reason %v, want %q", frames[i], got, mnet.ReasonMalformedJSON)
		}
	}
}

// TestARefusedIntentStillConsumesItsSequenceNumber is the case the protocol
// argues at length and the one a reader is most likely to get backwards. The
// alternative makes last_seq depend on whether the server liked the body, and a
// number the client cannot predict from what it sent restates nothing.
func TestARefusedIntentStillConsumesItsSequenceNumber(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()

	alice.sendRaw(`{"move_to":{"x":999,"z":0,"seq":8}}`)
	if refusal := alice.awaitError(); refusal.Re != mnet.MsgMoveTo {
		t.Fatalf("the error is attributed to %q, want %q", refusal.Re, mnet.MsgMoveTo)
	}
	rejected := h.awaitEvents(game.EvMoveToRejected, 1)
	if got := rejected[0]["reason"]; got != string(mnet.ReasonOutOfBounds) {
		t.Fatalf("x=999 was rejected with reason %v, want %q", got, mnet.ReasonOutOfBounds)
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
