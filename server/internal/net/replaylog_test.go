package net_test

import (
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const approachDest = 10.0

func TestJoinReplayLogsTheReAnchoredPath(t *testing.T) {
	h := newHarness(t, acornAt(approachDest, 0))

	alice := h.dial("alice")
	aw := alice.welcome()
	aliceID := aw.You

	alice.pickup(aw.Items[0].ID)
	assigned := h.awaitEvents(game.EvPathAssigned, 1)[0]
	alice.path()

	time.Sleep(4 * game.TickDuration)

	bob := h.dial("bob")
	bobWelcome := bob.welcomeFrame()
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

	if got := logNumber(t, replay, "t"); got != float64(bobWelcome.Tick) {
		t.Errorf("%s logged at tick %v, want the tick bob was welcomed at (%d)",
			game.EvPathReplayed, got, bobWelcome.Tick)
	}

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
	if last := replayPoints[len(replayPoints)-1]; last != mnet.Pt(approachDest, 0) {
		t.Errorf("%s ends at %v, want alice's original destination [%v 0]",
			game.EvPathReplayed, last, approachDest)
	}
}

func TestJoinReplayLogsOncePerWalker(t *testing.T) {
	h := newHarness(t, acornAt(approachDest, 0), acornAt(0, approachDest))

	alice := h.dial("alice")
	aw := alice.welcome()
	aliceID := aw.You
	bob := h.dial("bob")
	bw := bob.welcome()
	bobID := bw.You
	alice.spawn()

	alice.pickup(aw.Items[0].ID)
	bob.pickup(bw.Items[1].ID)
	h.awaitEvents(game.EvPathAssigned, 2)
	_ = alice.path()
	_ = bob.path()

	carol := h.dial("carol")
	carolWelcome := carol.welcomeFrame()

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
