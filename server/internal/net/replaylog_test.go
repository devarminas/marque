package net_test

import (
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
)

const approachDest = 10.0

func TestJoinDuringApproachSendsNoPlayerPathReplay(t *testing.T) {
	h := newHarness(t, acornAt(approachDest, 0))

	alice := h.dial("alice")
	aw := alice.welcome()
	aliceID := aw.You

	alice.pickup(aw.Items[0].ID)
	pose := alice.awaitPlayerPose(aliceID)
	if pose.ID != aliceID {
		t.Fatalf("approach pose id=%d, want alice %d", pose.ID, aliceID)
	}
	if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 0 {
		t.Fatalf("player approach logged %d path_assigned, want 0: %+v", len(assigned), assigned)
	}

	time.Sleep(4 * game.TickDuration)

	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	bobPos := positionOf(t, bobWelcome, aliceID)
	if bobPos.X == 0 && bobPos.Z == 0 {
		t.Fatal("late joiner welcome still has alice at spawn; want mid-approach pose")
	}

	if replays := h.eventsNamed(game.EvPathReplayed); len(replays) != 0 {
		t.Fatalf("logged %d path_replayed for player approach, want 0: %+v", len(replays), replays)
	}
}

func TestJoinDuringTwoApproachesSendsNoPlayerPathReplay(t *testing.T) {
	h := newHarness(t, acornAt(approachDest, 0), acornAt(0, approachDest))

	alice := h.dial("alice")
	aw := alice.welcome()
	bob := h.dial("bob")
	bw := bob.welcome()
	alice.spawn()

	alice.pickup(aw.Items[0].ID)
	bob.pickup(bw.Items[1].ID)
	_ = alice.awaitPlayerPose(aw.You)
	_ = bob.awaitPlayerPose(bw.You)

	carol := h.dial("carol")
	carolWelcome := carol.welcome()
	if positionOf(t, carolWelcome, aw.You).X == 0 && positionOf(t, carolWelcome, aw.You).Z == 0 {
		t.Fatal("carol welcome left alice at spawn during approach")
	}
	if positionOf(t, carolWelcome, bw.You).X == 0 && positionOf(t, carolWelcome, bw.You).Z == 0 {
		t.Fatal("carol welcome left bob at spawn during approach")
	}

	if replays := h.eventsNamed(game.EvPathReplayed); len(replays) != 0 {
		t.Fatalf("logged %d path_replayed, want 0: %+v", len(replays), replays)
	}
	if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 0 {
		t.Fatalf("logged %d player path_assigned, want 0: %+v", len(assigned), assigned)
	}
}

func TestHaltedPlayerLogsNoReplay(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	halt := haltMidSteer(t, alice)
	bob.drain()

	carol := h.dial("carol")
	carolWelcome := carol.welcome()
	if carolWelcome.Tick <= halt.Tick {
		t.Fatalf("carol joined at tick %d, not after the halt at %d; the test proved nothing",
			carolWelcome.Tick, halt.Tick)
	}

	carol.expectSilence()

	if replays := h.eventsNamed(game.EvPathReplayed); len(replays) != 0 {
		t.Fatalf("logged %d %s events for a join with nobody mid-walk, want none: %+v",
			len(replays), game.EvPathReplayed, replays)
	}
}
