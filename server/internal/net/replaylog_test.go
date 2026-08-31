package net_test

// The event log's side of the join replay.
//
// PROTOCOL.md's "welcome" section says a joining client is sent one re-anchored
// path per player mid-walk. These tests assert the log records that, with the
// values the joiner was actually sent rather than the values of the assignment
// the walk started from. Without them the log cannot reconstruct what a
// newcomer was told: the numbers are re-derivable by re-simulating the walk,
// but nothing would mark that re-simulation as necessary.
//
// They live beside the frame-level tests in hub_test.go, driven by the same
// real server and real clients, because a replay only exists as a consequence
// of a real join.

import (
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// walkDest is far enough away that a walker is still walking for the whole of
// any test here. At WalkSpeed it is several seconds of travel.
const walkDest = 30.0

// TestJoinReplayLogsTheReAnchoredPath is the assertion the unit exists for: the
// logged replay carries the joiner's numbers, not the original walk's.
//
// Asserting only that some event appeared would pass against a log that echoed
// the original path_assigned, which is exactly the reconstruction that would be
// wrong. So both re-anchored fields are compared against the frame the joiner
// received and against the assignment they differ from.
func TestJoinReplayLogsTheReAnchoredPath(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceID := alice.welcome().You

	alice.moveTo(walkDest, 0)
	assigned := h.awaitEvents(game.EvPathAssigned, 1)[0]
	alice.path()

	// Ticks have to pass, or "re-anchored" and "verbatim" would agree and the
	// test would prove nothing.
	time.Sleep(4 * game.TickDuration)

	bob := h.dial("bob")
	bobWelcome := bob.welcome()
	inFlight := bob.path()

	replays := h.awaitEvents(game.EvPathReplayed, 1)
	if len(replays) != 1 {
		t.Fatalf("logged %d %s events for one joiner and one walker, want 1: %+v",
			len(replays), game.EvPathReplayed, replays)
	}
	replay := replays[0]

	if got := logNumber(t, replay, "player"); got != float64(aliceID) {
		t.Errorf("%s names player %v, want the walker alice (%d)", game.EvPathReplayed, got, aliceID)
	}
	if got := logNumber(t, replay, "to"); got != float64(bobWelcome.You) {
		t.Errorf("%s was sent to %v, want the joiner bob (%d)", game.EvPathReplayed, got, bobWelcome.You)
	}
	if got := logNumber(t, replay, "speed"); got != game.WalkSpeed {
		t.Errorf("%s logs speed %v, want %v", game.EvPathReplayed, got, game.WalkSpeed)
	}

	// The tick the replay was logged at is the join tick, so a reader can line
	// the event up with the welcome that preceded it.
	if got := logNumber(t, replay, "t"); got != float64(bobWelcome.Tick) {
		t.Errorf("%s logged at tick %v, want the tick bob was welcomed at (%d)",
			game.EvPathReplayed, got, bobWelcome.Tick)
	}

	// start_tick: the joiner's, which is later than the assignment's.
	assignedStart := logNumber(t, assigned, "start_tick")
	replayStart := logNumber(t, replay, "start_tick")
	if replayStart != float64(inFlight.StartTick) {
		t.Errorf("%s logs start_tick %v, want the %d bob was sent",
			game.EvPathReplayed, replayStart, inFlight.StartTick)
	}
	if replayStart <= assignedStart {
		t.Errorf("%s logs start_tick %v, not after the assignment's %v; that is a verbatim resend, not a re-anchor",
			game.EvPathReplayed, replayStart, assignedStart)
	}

	// points[0]: where alice is now, which is not where the walk began.
	assignedPoints := logPoints(t, assigned, "points")
	replayPoints := logPoints(t, replay, "points")
	if len(replayPoints) == 0 {
		t.Fatalf("%s logs an empty polyline", game.EvPathReplayed)
	}
	if replayPoints[0] != inFlight.Points[0] {
		t.Errorf("%s logs points[0] = %v, want the %v bob was sent",
			game.EvPathReplayed, replayPoints[0], inFlight.Points[0])
	}
	if replayPoints[0] == assignedPoints[0] {
		t.Errorf("%s logs points[0] = %v, the origin of the original walk; want alice's position at the join",
			game.EvPathReplayed, replayPoints[0])
	}
	if last := replayPoints[len(replayPoints)-1]; last != mnet.Pt(walkDest, 0) {
		t.Errorf("%s ends at %v, want alice's original destination [%v 0]",
			game.EvPathReplayed, last, walkDest)
	}
}

// TestJoinReplayLogsOncePerWalker covers the loop rather than one pass through
// it. Two players mid-walk when a third joins means two replayed frames, so the
// log must carry two events and not one summary of the burst.
func TestJoinReplayLogsOncePerWalker(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceID := alice.welcome().You
	bob := h.dial("bob")
	bobID := bob.welcome().You

	// Both walks are assigned after both joins, so the only replays in this
	// log are carol's.
	alice.moveTo(walkDest, 0)
	bob.moveTo(0, walkDest)
	h.awaitEvents(game.EvPathAssigned, 2)
	alice.drain()
	bob.drain()

	carol := h.dial("carol")
	carolWelcome := carol.welcome()

	replays := h.awaitEvents(game.EvPathReplayed, 2)
	if len(replays) != 2 {
		t.Fatalf("logged %d %s events for two walkers, want 2: %+v",
			len(replays), game.EvPathReplayed, replays)
	}

	walkers := make(map[float64]bool, 2)
	for i, replay := range replays {
		if got := logNumber(t, replay, "to"); got != float64(carolWelcome.You) {
			t.Errorf("%s[%d] was sent to %v, want the joiner carol (%d)",
				game.EvPathReplayed, i, got, carolWelcome.You)
		}
		if got := logNumber(t, replay, "t"); got != float64(carolWelcome.Tick) {
			t.Errorf("%s[%d] logged at tick %v, want carol's join tick %d; the replays are one atomic step",
				game.EvPathReplayed, i, got, carolWelcome.Tick)
		}
		walkers[logNumber(t, replay, "player")] = true
	}

	if !walkers[float64(aliceID)] || !walkers[float64(bobID)] {
		t.Fatalf("%s events name players %v, want one each for alice (%d) and bob (%d)",
			game.EvPathReplayed, walkers, aliceID, bobID)
	}
}

// TestHaltedPlayerLogsNoReplay is the negative case PROTOCOL.md spells out: a
// halted player is not mid-walk, so a joiner is sent no path for them and the
// log must not claim otherwise.
//
// The check is safe to make the moment carol's welcome has arrived. Welcome and
// its replays are composed in one step on the world goroutine, so a replay that
// was going to be logged was logged before that welcome was enqueued.
func TestHaltedPlayerLogsNoReplay(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn() // bob joining

	// Nobody joins between the walk and the halt, so a replay logged in this
	// test can only have come from carol.
	halt := haltMidWalk(t, alice)
	bob.drain()

	carol := h.dial("carol")
	carolWelcome := carol.welcome()
	if carolWelcome.Tick <= halt.StartTick {
		t.Fatalf("carol joined at tick %d, not after the halt at %d; the test proved nothing",
			carolWelcome.Tick, halt.StartTick)
	}

	carol.expectSilence()

	if replays := h.eventsNamed(game.EvPathReplayed); len(replays) != 0 {
		t.Fatalf("logged %d %s events for a join with nobody mid-walk, want none: %+v",
			len(replays), game.EvPathReplayed, replays)
	}
}

// logPoints reads a polyline out of a parsed log line. Points are logged the
// way they go on the wire, as [x, z] pairs, so each element decodes into a
// two-element []any of float64.
func logPoints(t *testing.T, obj map[string]any, key string) []mnet.Point {
	t.Helper()

	v, ok := obj[key]
	if !ok {
		t.Fatalf("log line has no %q field: %+v", key, obj)
	}
	raw, ok := v.([]any)
	if !ok {
		t.Fatalf("log field %q is %T (%v), want an array of points", key, v, v)
	}

	points := make([]mnet.Point, len(raw))
	for i, element := range raw {
		pair, ok := element.([]any)
		if !ok || len(pair) != 2 {
			t.Fatalf("log field %q[%d] is %v, want a two-element [x, z]", key, i, element)
		}
		x, xok := pair[0].(float64)
		z, zok := pair[1].(float64)
		if !xok || !zok {
			t.Fatalf("log field %q[%d] is %v, want two numbers", key, i, element)
		}
		points[i] = mnet.Pt(x, z)
	}
	return points
}
