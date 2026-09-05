package net_test

import (
	"math"
	"sync"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// tickStep is how far a walker moves in one tick. Derived from the two
// constants, never restated as a number, so a change to either shows up here as
// a changed expectation rather than a failing test with a stale literal.
var tickStep = game.WalkSpeed * game.TickDuration.Seconds()

// TestOneClientsMoveReachesTheOther is the M0a assertion: two real clients on
// one real server, and what A does is what B sees.
func TestOneClientsMoveReachesTheOther(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	bob := h.dial("bob")
	bobWelcome := bob.welcome()

	if aliceWelcome.You == bobWelcome.You {
		t.Fatalf("both clients were given id %d; ids are per-connection", aliceWelcome.You)
	}
	if bobWelcome.TickMS != int(game.TickDuration.Milliseconds()) {
		t.Fatalf("welcome says tick_ms=%d, want %d", bobWelcome.TickMS, game.TickDuration.Milliseconds())
	}
	if len(bobWelcome.Players) != 2 {
		t.Fatalf("bob's welcome lists %d players, want alice and bob: %+v", len(bobWelcome.Players), bobWelcome.Players)
	}

	// Alice hears that Bob joined. Bob does not hear about himself; he learned
	// his own existence from welcome.
	if spawned := alice.spawn(); spawned.ID != bobWelcome.You {
		t.Fatalf("alice saw a spawn for player %d, want bob (%d)", spawned.ID, bobWelcome.You)
	}

	const destX, destZ = 10.5, -4.25
	alice.moveTo(destX, destZ)

	// The assertion this unit exists for.
	seen := bob.path()
	if seen.ID != aliceWelcome.You {
		t.Fatalf("bob got a path for player %d, want alice (%d)", seen.ID, aliceWelcome.You)
	}
	if len(seen.Points) != 2 {
		t.Fatalf("path has %d points, want 2 for a straight line: %v", len(seen.Points), seen.Points)
	}
	if seen.Points[0] != mnet.Pt(0, 0) {
		t.Fatalf("points[0] = %v, want alice's position at start_tick (the spawn point)", seen.Points[0])
	}
	if seen.Points[len(seen.Points)-1] != mnet.Pt(destX, destZ) {
		t.Fatalf("path ends at %v, want the requested destination [%v %v]",
			seen.Points[len(seen.Points)-1], destX, destZ)
	}
	if seen.Speed != game.WalkSpeed {
		t.Fatalf("path speed %v, want %v", seen.Speed, game.WalkSpeed)
	}
	if seen.StartTick < bobWelcome.Tick {
		t.Fatalf("start_tick %d precedes the tick bob was welcomed at (%d)", seen.StartTick, bobWelcome.Tick)
	}

	// The mover is not excluded from its own path broadcast: the client's
	// position is the server's, not one it predicted.
	mine := alice.path()
	if mine.ID != aliceWelcome.You || mine.StartTick != seen.StartTick {
		t.Fatalf("alice got path %+v, want the same one bob got: %+v", mine, seen)
	}

	assigned := h.awaitEvents(game.EvPathAssigned, 1)
	if got := assigned[0]["player"]; got != float64(aliceWelcome.You) {
		t.Fatalf("path_assigned logged player %v, want %d", got, aliceWelcome.You)
	}
}

// TestLateJoinLearnsInFlightPath covers a client arriving while someone else is
// already walking. The replayed path is re-anchored, not resent verbatim, so it
// agrees with the position the same welcome reported.
func TestLateJoinLearnsInFlightPath(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	// Far enough that alice is still walking well after bob arrives.
	const destX = 30.0
	alice.moveTo(destX, 0)
	first := alice.path()
	if first.Points[0] != mnet.Pt(0, 0) {
		t.Fatalf("points[0] = %v, want the spawn point", first.Points[0])
	}

	// Let her get under way, so "in flight" means something.
	time.Sleep(4 * game.TickDuration)

	bob := h.dial("bob")

	// Welcome first, always.
	bobWelcome := bob.welcomeFrame()
	var alicePos mnet.PlayerState
	found := false
	for _, p := range bobWelcome.Players {
		if p.ID == aliceWelcome.You {
			alicePos, found = p, true
		}
	}
	if !found {
		t.Fatalf("bob's welcome does not list alice: %+v", bobWelcome.Players)
	}
	if alicePos.X <= 0 || alicePos.X >= destX {
		t.Fatalf("welcome puts alice at x=%v, want her partway along the walk (0, %v)", alicePos.X, destX)
	}

	// Then the in-flight walk, as an ordinary path message. No snapshot format.
	inFlight := bob.path()
	if inFlight.ID != aliceWelcome.You {
		t.Fatalf("path is for player %d, want alice (%d)", inFlight.ID, aliceWelcome.You)
	}
	if inFlight.StartTick != bobWelcome.Tick {
		t.Fatalf("path start_tick %d, want the tick bob was welcomed at (%d)", inFlight.StartTick, bobWelcome.Tick)
	}
	if inFlight.Points[0] != mnet.Pt(alicePos.X, alicePos.Z) {
		t.Fatalf("points[0] = %v, want alice's position from welcome %v", inFlight.Points[0], alicePos)
	}
	if len(inFlight.Points) != 2 {
		t.Fatalf("replayed path has %d points, want the walker plus the waypoints still ahead: %v",
			len(inFlight.Points), inFlight.Points)
	}
	if inFlight.Points[len(inFlight.Points)-1] != mnet.Pt(destX, 0) {
		t.Fatalf("path ends at %v, want her original destination", inFlight.Points[len(inFlight.Points)-1])
	}
}

// TestSecondMoveStartsFromTheInterpolatedPosition covers replacing a path
// mid-walk.
func TestSecondMoveStartsFromTheInterpolatedPosition(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.moveTo(30, 0)
	first := alice.path()

	time.Sleep(4 * game.TickDuration)

	alice.moveTo(0, 20)
	second := alice.path()

	elapsed := second.StartTick - first.StartTick
	if elapsed <= 0 {
		t.Fatalf("second path start_tick %d does not follow the first (%d)", second.StartTick, first.StartTick)
	}

	if second.Points[0] == first.Points[0] {
		t.Fatalf("points[0] = %v, the origin of the abandoned path; want where alice actually is",
			second.Points[0])
	}

	// Position at start_tick is exactly the ticks elapsed times the per-tick
	// step, because a player's position changes only on a tick.
	wantX := float64(elapsed) * tickStep
	if math.Abs(second.Points[0].X()-wantX) > 1e-6 {
		t.Fatalf("points[0].x = %v after %d ticks, want %v", second.Points[0].X(), elapsed, wantX)
	}
	if math.Abs(second.Points[0].Z()) > 1e-6 {
		t.Fatalf("points[0].z = %v, want 0: the first walk was along x only", second.Points[0].Z())
	}
	if second.Points[len(second.Points)-1] != mnet.Pt(0, 20) {
		t.Fatalf("path ends at %v, want the new destination [0 20]", second.Points[len(second.Points)-1])
	}
}

// TestOutOfBoundsMoveIsRejected covers a destination the server refuses.
//
// 1e30 is the hazard worth naming: it decodes cleanly as a finite float and
// only becomes a problem once 32-bit vector math on the client overflows on it.
// Rejected means rejected: not clamped to the edge, not snapped to the nearest
// legal point.
func TestOutOfBoundsMoveIsRejected(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn() // bob joining

	alice.moveTo(1e30, 0)

	// The sender is told, in as many words.
	refusal := alice.errorFrame()
	if refusal.Re != mnet.MsgMoveTo {
		t.Fatalf("error attributed to %q, want %q", refusal.Re, mnet.MsgMoveTo)
	}
	if refusal.Msg == "" {
		t.Fatal("error carries no message for a human to read")
	}

	rejected := h.awaitEvents(game.EvMoveToRejected, 1)
	if len(rejected) != 1 {
		t.Fatalf("logged %d rejections, want exactly 1: %+v", len(rejected), rejected)
	}
	if got := rejected[0]["reason"]; got != string(mnet.ReasonOutOfBounds) {
		t.Fatalf("rejection reason %v, want %q", got, mnet.ReasonOutOfBounds)
	}

	// Nobody is told to walk anywhere. Not the sender, and not anyone else.
	bob.expectSilence()
	alice.expectSilence()

	if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 0 {
		t.Fatalf("a rejected move still assigned a path: %+v", assigned)
	}

	// The connection survives its own bad input.
	alice.moveTo(1, 1)
	if p := bob.path(); p.ID != aliceWelcome.You {
		t.Fatalf("after a rejection, bob got a path for %d, want alice (%d)", p.ID, aliceWelcome.You)
	}
}

// TestWorldEdgeIsInsideTheBounds pins the bound as inclusive, so that the one
// number in PROTOCOL.md and the one constant here cannot drift by an epsilon.
func TestWorldEdgeIsInsideTheBounds(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.moveTo(game.WorldHalfExtent, -game.WorldHalfExtent)
	got := alice.path()
	if got.Points[len(got.Points)-1] != mnet.Pt(game.WorldHalfExtent, -game.WorldHalfExtent) {
		t.Fatalf("path ends at %v, want the corner of the world", got.Points[len(got.Points)-1])
	}
}

// TestNaNMoveIsRejected covers the coordinate that has no JSON literal. A
// client that tries to send one is refused while the frame is still text.
func TestNaNMoveIsRejected(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.sendRaw(`{"move_to":{"x":NaN,"z":0}}`)

	if refusal := alice.errorFrame(); refusal.Msg == "" {
		t.Fatal("error carries no message for a human to read")
	}

	rejected := h.awaitEvents(game.EvMoveToRejected, 1)
	if len(rejected) != 1 {
		t.Fatalf("logged %d rejections, want exactly 1: %+v", len(rejected), rejected)
	}
	reason := rejected[0]["reason"]
	if reason != string(mnet.ReasonMalformedJSON) && reason != string(mnet.ReasonNonFinite) {
		t.Fatalf("rejection reason %v, want %q or %q",
			reason, mnet.ReasonMalformedJSON, mnet.ReasonNonFinite)
	}

	alice.expectSilence()
	if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 0 {
		t.Fatalf("a rejected move still assigned a path: %+v", assigned)
	}
}

// TestDegenerateClickWhileStationaryIsAnswered covers clicking the ground you
// are already standing on while standing still. Somebody does this in the first
// minute of any demo. Nothing changes, so nothing is broadcast, but the sender
// is told: without a reply the click is indistinguishable from a dropped frame.
func TestDegenerateClickWhileStationaryIsAnswered(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	// Exactly where she stands, and then near enough to make no difference.
	alice.moveTo(0, 0)
	alice.moveTo(game.MinPathLength/2, 0)

	for i := range 2 {
		refusal := alice.errorFrame()
		if refusal.Re != mnet.MsgMoveTo {
			t.Fatalf("click %d: error attributed to %q, want %q", i, refusal.Re, mnet.MsgMoveTo)
		}
		if refusal.Msg != "already there" {
			t.Fatalf("click %d: error says %q, want %q", i, refusal.Msg, "already there")
		}
	}

	rejected := h.awaitEvents(game.EvMoveToRejected, 2)
	if len(rejected) != 2 {
		t.Fatalf("logged %d rejections, want 2: %+v", len(rejected), rejected)
	}
	for i, ev := range rejected {
		if got := ev["reason"]; got != string(mnet.ReasonDegenerate) {
			t.Fatalf("rejection %d reason %v, want %q", i, got, mnet.ReasonDegenerate)
		}
	}

	// Nothing changed, so nobody is told anything.
	alice.expectSilence()
	bob.expectSilence()
	if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 0 {
		t.Fatalf("a degenerate click by a stationary player assigned a path: %+v", assigned)
	}
}

// TestDegenerateClickWhileWalkingHalts covers the other branch: the same click
// from a player who is moving means stop. It is broadcast like any other path,
// because everyone watching has to stop drawing her walking.
func TestDegenerateClickWhileWalkingHalts(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	halt := haltMidWalk(t, alice)

	if len(halt.Points) != 1 {
		t.Fatalf("halt path has %d points, want exactly 1: %v", len(halt.Points), halt.Points)
	}
	if halt.ID != aliceWelcome.You {
		t.Fatalf("halt path is for player %d, want alice (%d)", halt.ID, aliceWelcome.You)
	}

	// Everyone including the mover, as with any other path.
	seen := bob.awaitHaltPath(aliceWelcome.You)
	if seen.Points[0] != halt.Points[0] {
		t.Fatalf("bob was told alice halts at %v, alice was told %v", seen.Points[0], halt.Points[0])
	}
	if seen.StartTick != halt.StartTick {
		t.Fatalf("bob got start_tick %d, alice got %d; it is one broadcast", seen.StartTick, halt.StartTick)
	}
}

// TestHaltedPlayerStaysHalted is the assertion that makes a halt a halt: no
// further path, and a position that stops advancing.
//
// The position is read back through a third client's welcome, because welcome
// reports every player's position as of the current tick and is the only way to
// ask the server where somebody is without moving them.
func TestHaltedPlayerStaysHalted(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	halt := haltMidWalk(t, alice)
	bob.drain()

	// Several ticks pass. Had she still been walking she would have covered
	// four steps in this time.
	time.Sleep(4 * game.TickDuration)

	alice.expectSilence()
	bob.expectSilence()

	carol := h.dial("carol")
	carolWelcome := carol.welcome()
	if carolWelcome.Tick <= halt.StartTick {
		t.Fatalf("carol joined at tick %d, not after the halt at %d; the test proved nothing",
			carolWelcome.Tick, halt.StartTick)
	}

	var alicePos mnet.PlayerState
	found := false
	for _, p := range carolWelcome.Players {
		if p.ID == aliceWelcome.You {
			alicePos, found = p, true
		}
	}
	if !found {
		t.Fatalf("carol's welcome does not list alice: %+v", carolWelcome.Players)
	}
	if alicePos.X != halt.Points[0].X() || alicePos.Z != halt.Points[0].Z() {
		t.Fatalf("alice is at [%v %v] several ticks after halting at %v; she is still moving",
			alicePos.X, alicePos.Z, halt.Points[0])
	}

	// A halted player is not mid-walk, so there is no in-flight path to replay.
	carol.expectSilence()
}

// haltMidWalk gets a walking player to stop and returns the halt path.
//
// Stopping means clicking within an epsilon of where the player is, and the
// only position a black-box test knows exactly is the one the server just
// reported in points[0] of a fresh path. That position is only current until
// the next tick, so the click has to land in the same tick that reported it.
// On loopback it does; when it does not, the click is an ordinary move and the
// attempt simply repeats.
func haltMidWalk(t *testing.T, c *client) mnet.Path {
	t.Helper()

	const attempts = 20
	for range attempts {
		// A destination far enough away that she is still walking when the
		// second click arrives.
		c.moveTo(30, 0)
		walking := c.path()
		if len(walking.Points) != 2 {
			t.Fatalf("expected an ordinary two-point walk, got %v", walking.Points)
		}

		// Click exactly where the server just said she is.
		here := walking.Points[0]
		c.moveTo(here.X(), here.Z())

		halt := c.path()
		if len(halt.Points) != 1 {
			// The tick turned over between the two frames, so the click was an
			// ordinary move to where she used to be. Try again.
			continue
		}
		if halt.Points[0] != here {
			t.Fatalf("halt point %v, want the position the server reported, %v", halt.Points[0], here)
		}
		if halt.StartTick != walking.StartTick {
			t.Fatalf("halt at tick %d but the position was reported at tick %d; "+
				"a one-point path can only mean a position that has not moved",
				halt.StartTick, walking.StartTick)
		}
		return halt
	}

	t.Fatalf("could not land a click inside one tick in %d attempts", attempts)
	return mnet.Path{}
}

// TestUnknownMessageIsIgnored covers compatibility rule 1: a message this
// server does not know is logged loudly and ignored, so that a client written
// against a later protocol version keeps working against this one.
func TestUnknownMessageIsIgnored(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	alice.sendRaw(`{"tick":{"t":9000}}`)
	alice.sendRaw(`{"cast":{"spell":1}}`)

	ignored := h.awaitEvents(game.EvIntentIgnored, 2)
	for _, ev := range ignored {
		if got := ev["reason"]; got != string(mnet.ReasonUnknownMessage) {
			t.Fatalf("ignored for %v, want %q", got, mnet.ReasonUnknownMessage)
		}
	}

	// Nothing sent back, and the connection is untouched.
	alice.expectSilence()
	alice.moveTo(2, 3)
	if p := alice.path(); p.ID != aliceWelcome.You {
		t.Fatalf("after two unknown messages, alice got a path for %d, want herself (%d)", p.ID, aliceWelcome.You)
	}
}

// TestReservedFieldsAreIgnored covers compatibility rule 2. M2's seq must land
// as a filled-in field, not as a renegotiation of every intent's contract.
func TestReservedFieldsAreIgnored(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	alice.sendRaw(`{"move_to":{"x":4,"z":6,"seq":17,"invented_later":"whatever"}}`)

	got := alice.path()
	if got.ID != aliceWelcome.You {
		t.Fatalf("path is for player %d, want alice (%d)", got.ID, aliceWelcome.You)
	}
	if got.Points[len(got.Points)-1] != mnet.Pt(4, 6) {
		t.Fatalf("path ends at %v, want [4 6]", got.Points[len(got.Points)-1])
	}
}

// TestMalformedFramesAreRejectedWithAReason walks the failure modes a frame can
// have that still leave the connection usable. Each gets one error naming what
// went wrong, and none of them drops the client: a broken frame is a broken
// frame, not a broken client.
func TestMalformedFramesAreRejectedWithAReason(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	cases := []struct {
		frame string
		want  mnet.RejectReason
	}{
		{`this is not json`, mnet.ReasonMalformedJSON},
		{`{"move_to":{"x":5}}`, mnet.ReasonMissingField},
		{`{"move_to":{"x":"over there","z":0}}`, mnet.ReasonMalformedJSON},
		{`{"move_to":{"x":1e400,"z":0}}`, mnet.ReasonMalformedJSON},
	}
	for _, tc := range cases {
		alice.sendRaw(tc.frame)
	}

	rejected := h.awaitEvents(game.EvMoveToRejected, len(cases))
	if len(rejected) != len(cases) {
		t.Fatalf("logged %d rejections, want %d: %+v", len(rejected), len(cases), rejected)
	}
	for i, tc := range cases {
		if got := rejected[i]["reason"]; got != string(tc.want) {
			t.Fatalf("frame %s rejected with %v, want %q", tc.frame, got, tc.want)
		}
		if refusal := alice.errorFrame(); refusal.Msg == "" {
			t.Fatalf("frame %s produced an error with no message", tc.frame)
		}
	}

	alice.expectSilence()

	// Still a working client.
	alice.moveTo(2, 3)
	if p := alice.path(); p.ID != aliceWelcome.You {
		t.Fatalf("after four bad frames, alice got a path for %d, want herself (%d)", p.ID, aliceWelcome.You)
	}
}

// TestUninterpretableFrameClosesTheConnection covers the frames that name no
// message at all. Those are not a compatibility question, and the client is
// told why before the socket goes away.
func TestUninterpretableFrameClosesTheConnection(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		send   func(*client)
		reason mnet.RejectReason
	}{
		{"no keys", func(c *client) { c.sendRaw(`{}`) }, mnet.ReasonProtocolError},
		{"two keys", func(c *client) { c.sendRaw(`{"move_to":{"x":1,"z":2},"use":{}}`) }, mnet.ReasonProtocolError},
		{"binary frame", func(c *client) { c.sendBinary([]byte(`{"move_to":{"x":1,"z":2}}`)) }, mnet.ReasonBinaryFrame},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)

			alice := h.dial("alice")
			alice.welcome()
			tc.send(alice)

			// The error arrives before the close, because both go through the
			// one ordered send queue.
			if refusal := alice.errorFrame(); refusal.Msg == "" {
				t.Fatal("error carries no message for a human to read")
			}

			rejected := h.awaitEvents(game.EvMoveToRejected, 1)
			if got := rejected[0]["reason"]; got != string(tc.reason) {
				t.Fatalf("rejection reason %v, want %q", got, tc.reason)
			}

			alice.expectClosed()
			h.awaitEvents(game.EvDisconnected, 1)
		})
	}
}

// TestDisconnectDespawns covers a client leaving.
func TestDisconnectDespawns(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.close()

	gone := bob.despawn()
	if gone.ID != aliceWelcome.You {
		t.Fatalf("bob saw a despawn for player %d, want alice (%d)", gone.ID, aliceWelcome.You)
	}

	disconnects := h.awaitEvents(game.EvDisconnected, 1)
	if got := disconnects[0]["player"]; got != float64(aliceWelcome.You) {
		t.Fatalf("client_disconnected logged player %v, want %d", got, aliceWelcome.You)
	}
	// The reason reaches the log at all, and it is the cause rather than a
	// detector name. This is the only place the net layer's classification is
	// checked end to end through the world; net's own tests stop at the event.
	if got := disconnects[0]["reason"]; got != mnet.DisconnectClosed {
		t.Fatalf("client_disconnected logged reason %v for a clean logout, want %q", got, mnet.DisconnectClosed)
	}
	if got, ok := disconnects[0]["detail"]; ok {
		t.Fatalf("client_disconnected logged detail %v for a clean logout; only one path can reach it, so the key must be absent", got)
	}
}

// TestPlayerIdsAreNotReused covers the id counter. A departed player's id must
// never come back within a process, because a client that has not yet processed
// the despawn would attach the new player's movement to the old avatar.
func TestPlayerIdsAreNotReused(t *testing.T) {
	h := newHarness(t)

	observer := h.dial("observer")
	if got := observer.welcome().You; got != 1 {
		t.Fatalf("first player got id %d, want ids to start at 1", got)
	}

	first := h.dial("first")
	firstID := first.welcome().You
	if got := observer.spawn().ID; got != firstID {
		t.Fatalf("observer saw spawn %d, want %d", got, firstID)
	}
	first.close()
	if got := observer.despawn().ID; got != firstID {
		t.Fatalf("observer saw despawn %d, want %d", got, firstID)
	}

	second := h.dial("second")
	secondID := second.welcome().You
	if secondID == firstID {
		t.Fatalf("second player got the departed player's id (%d)", secondID)
	}
}

// TestSimultaneousJoinsAgreeOnWhoIsThere covers the join race: two clients
// arriving inside one tick.
//
// Getting this wrong produces a duplicated avatar or a player nobody hears
// about, and both look like client bugs. The invariant is that welcome and
// spawn partition the world for each client: a player is in one or the other,
// never both and never neither.
func TestSimultaneousJoinsAgreeOnWhoIsThere(t *testing.T) {
	const attempts = 5

	for attempt := range attempts {
		h := newHarness(t)

		var (
			wg      sync.WaitGroup
			mu      sync.Mutex
			clients []*client
		)
		for i := range 2 {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				c := h.dial("joiner")
				mu.Lock()
				defer mu.Unlock()
				clients = append(clients, c)
			}(i)
		}
		wg.Wait()

		ids := make(map[mnet.PlayerID]bool)
		known := make([]map[mnet.PlayerID]bool, len(clients))
		for i, c := range clients {
			w := c.welcome()
			ids[w.You] = true
			known[i] = make(map[mnet.PlayerID]bool)
			for _, p := range w.Players {
				known[i][p.ID] = true
			}
		}
		if len(ids) != 2 {
			t.Fatalf("attempt %d: two clients share an id: %v", attempt, ids)
		}

		for i, c := range clients {
			for _, f := range c.collect(2 * game.TickDuration) {
				if f.Spawn == nil {
					t.Fatalf("attempt %d: joiner %d got a %s frame, want only spawns: %s",
						attempt, i, f.kind(), f.raw)
				}
				if known[i][f.Spawn.ID] {
					t.Fatalf("attempt %d: joiner %d was told to spawn player %d, "+
						"which its own welcome already listed", attempt, i, f.Spawn.ID)
				}
				known[i][f.Spawn.ID] = true
			}
			for id := range ids {
				if !known[i][id] {
					t.Fatalf("attempt %d: joiner %d never learned about player %d", attempt, i, id)
				}
			}
		}

		h.shutdown()
	}
}

// TestConcurrentTrafficStaysConsistent gives the race detector something to
// find: several clients moving at once, plus a client repeatedly joining and
// leaving so that connections come and go in the middle of broadcasts.
func TestConcurrentTrafficStaysConsistent(t *testing.T) {
	h := newHarness(t)

	const (
		movers    = 5
		moveEvery = 25 * time.Millisecond
		duration  = time.Second
	)

	clients := make([]*client, movers)
	for i := range clients {
		clients[i] = h.dial("mover")
		clients[i].welcome()
	}

	stop := make(chan struct{})
	var wg sync.WaitGroup

	// None of the goroutines below may touch *testing.T -- only the test's own
	// goroutine may fail a test, which is the rule drainUntil already states
	// and parseFrame's bad field already exists for. They report here instead,
	// and the test goroutine fails on their behalf once they have all stopped.
	bg := newBackgroundErr()

	// Movers: send intents and keep draining, so nobody is dropped for being
	// slow while the interesting concurrency happens.
	for i, c := range clients {
		wg.Add(1)
		go func(i int, c *client) {
			defer wg.Done()
			go c.drainUntil(stop)
			ticker := time.NewTicker(moveEvery)
			defer ticker.Stop()
			for {
				select {
				case <-stop:
					return
				case <-ticker.C:
					if err := c.moveToBackground(float64(i)+1, float64(i)-1); err != nil {
						bg.report(err)
						return
					}
				}
			}
		}(i, c)
	}

	// Churn: connect and disconnect underneath the broadcasts. This is the case
	// where sending to a connection nobody is draining any more would deadlock
	// the tick, if the design allowed it to.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			if err := h.churnOnce(); err != nil {
				bg.report(err)
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()

	time.Sleep(duration)
	close(stop)
	wg.Wait()
	bg.check(t)

	// The world survived, and still answers.
	for _, c := range clients {
		c.drain()
	}
	alice, bob := clients[0], clients[1]
	aliceID := h.awaitEvents(game.EvConnected, 1)[0]["player"].(float64)

	alice.moveTo(7, 8)
	seen := bob.awaitPath(mnet.PlayerID(aliceID))
	if seen.Points[len(seen.Points)-1] != mnet.Pt(7, 8) {
		t.Fatalf("after the storm, path ends at %v, want [7 8]", seen.Points[len(seen.Points)-1])
	}
}

// TestShutdownWithOpenConnections covers the server going away while clients
// are attached: the world stops, the sockets close, and nothing hangs.
func TestShutdownWithOpenConnections(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.moveTo(5, 5)
	alice.path()
	bob.path()

	done := make(chan struct{})
	go func() {
		defer close(done)
		h.shutdown()
	}()

	select {
	case <-done:
	case <-time.After(readTimeout):
		t.Fatal("shutdown did not complete with connections open")
	}

	alice.expectClosed()
	bob.expectClosed()

	stopping := h.eventsNamed(game.EvServerStopping)
	if len(stopping) != 1 {
		t.Fatalf("logged %d server_stopping events, want 1: %+v", len(stopping), stopping)
	}
}
