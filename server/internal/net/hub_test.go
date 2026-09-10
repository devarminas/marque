package net_test

import (
	"math"
	"sync"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

var tickStep = game.WalkSpeed * game.TickDuration.Seconds()

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
	for _, p := range bobWelcome.Players {
		if p.Y != 0 {
			t.Fatalf("welcome player %d has y=%v, want 0", p.ID, p.Y)
		}
	}

	if spawned := alice.spawn(); spawned.ID != bobWelcome.You {
		t.Fatalf("alice saw a spawn for player %d, want bob (%d)", spawned.ID, bobWelcome.You)
	}

	alice.move(1, 0)

	seen := bob.awaitPlayerPose(aliceWelcome.You)
	if seen.ID != aliceWelcome.You {
		t.Fatalf("bob got a pose for player %d, want alice (%d)", seen.ID, aliceWelcome.You)
	}
	if seen.Y != 0 {
		t.Fatalf("pose y=%v, want 0", seen.Y)
	}
	if math.Abs(seen.X-tickStep) > 1e-6 || seen.Z != 0 {
		t.Fatalf("pose=(%v,%v), want first step (~%v, 0)", seen.X, seen.Z, tickStep)
	}
	if seen.Tick < bobWelcome.Tick {
		t.Fatalf("pose tick %d precedes the tick bob was welcomed at (%d)", seen.Tick, bobWelcome.Tick)
	}

	mine := alice.awaitPlayerPose(aliceWelcome.You)
	if mine.ID != aliceWelcome.You || mine.Tick != seen.Tick {
		t.Fatalf("alice got pose %+v, want the same one bob got: %+v", mine, seen)
	}

	if assigned := h.eventsNamed(game.EvPathAssigned); len(assigned) != 0 {
		t.Fatalf("WASD steer must not assign path: %+v", assigned)
	}
}

func TestLateJoinSeesSteerPoseNotPath(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	alice.move(1, 0)
	for range 5 {
		alice.noteSelfPose(alice.awaitPose())
	}
	alice.move(0, 0)
	alice.noteSelfPose(alice.awaitPose())
	alice.drain()

	bob := h.dial("bob")

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
	if alicePos.X <= 0 {
		t.Fatalf("welcome puts alice at x=%v, want her past the origin after steering", alicePos.X)
	}
	if alicePos.Y != 0 {
		t.Fatalf("welcome alice y=%v, want 0", alicePos.Y)
	}
	if math.Abs(alicePos.X-alice.x) > tickStep || math.Abs(alicePos.Z-alice.z) > tickStep {
		t.Fatalf("welcome alice (%v,%v) disagrees with her last pose (%v,%v)", alicePos.X, alicePos.Z, alice.x, alice.z)
	}

	bob.inventory()
	bob.equipment()
	bob.classFrame()
	bob.skillsFrame()
	bob.questLogFrame()
	bob.expectSilence()
	if assigned := h.eventsNamed(game.EvPathReplayed); len(assigned) != 0 {
		t.Fatalf("late join must not replay player path for WASD: %+v", assigned)
	}
}

func TestSecondMoveContinuesFromIntegratedPose(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.move(1, 0)
	first := alice.awaitPose()

	time.Sleep(4 * game.TickDuration)
	deadline := time.Now().Add(6 * game.TickDuration)
	for time.Now().Before(deadline) {
		f, ok := alice.tryNext(2 * game.TickDuration)
		if !ok {
			break
		}
		if f.Pose != nil {
			first = *f.Pose
			alice.noteSelfPose(first)
		}
	}

	alice.move(0, 1)
	second := alice.awaitPose()

	if second.Tick <= first.Tick {
		t.Fatalf("second pose tick %d does not follow the first (%d)", second.Tick, first.Tick)
	}
	if second.X <= 0 {
		t.Fatalf("second pose x=%v, want continued progress along prior x walk", second.X)
	}
}

func TestMoveToIsRefused(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.sendRaw(`{"move_to":{"x":4,"z":6}}`)

	refusal := alice.errorFrame()
	if refusal.Re != mnet.MsgMoveTo {
		t.Fatalf("error attributed to %q, want %q", refusal.Re, mnet.MsgMoveTo)
	}
	if refusal.Msg == "" {
		t.Fatal("error carries no message for a human to read")
	}

	rejected := h.awaitEvents(game.EvMoveToRejected, 1)
	if got := rejected[0]["reason"]; got != string(mnet.ReasonIllegalSample) {
		t.Fatalf("rejection reason %v, want %q", got, mnet.ReasonIllegalSample)
	}

	bob.expectSilence()
	alice.expectSilence()
}

func TestIllegalSamplePoseFactIsRejected(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.sendRaw(`{"move":{"dx":1,"dz":0,"x":0}}`)

	refusal := alice.errorFrame()
	if refusal.Re != mnet.MsgMove {
		t.Fatalf("error attributed to %q, want %q", refusal.Re, mnet.MsgMove)
	}

	rejected := h.awaitEvents(game.EvMoveRejected, 1)
	if got := rejected[0]["reason"]; got != string(mnet.ReasonIllegalSample) {
		t.Fatalf("rejection reason %v, want %q", got, mnet.ReasonIllegalSample)
	}
	alice.expectSilence()
}

func TestWorldEdgeClampViaMove(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.walkTo(game.WorldHalfExtent-tickStep, 0)
	alice.move(1, 0)
	for range 5 {
		p := alice.awaitPose()
		alice.noteSelfPose(p)
		if math.Abs(p.X-game.WorldHalfExtent) < 1e-6 {
			return
		}
	}
	if math.Abs(alice.x-game.WorldHalfExtent) > 1e-6 {
		t.Fatalf("x=%v, want clamped at %v", alice.x, game.WorldHalfExtent)
	}
}

func TestNaNMoveIsRejected(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()

	alice.sendRaw(`{"move":{"dx":NaN,"dz":0}}`)

	if refusal := alice.errorFrame(); refusal.Msg == "" {
		t.Fatal("error carries no message for a human to read")
	}

	rejected := h.awaitEvents(game.EvMoveToRejected, 1)
	if len(rejected) != 1 {
		t.Fatalf("logged %d rejections, want exactly 1: %+v", len(rejected), rejected)
	}
	reason := rejected[0]["reason"]
	if reason != string(mnet.ReasonMalformedJSON) && reason != string(mnet.ReasonIllegalSample) {
		t.Fatalf("rejection reason %v, want malformed_json or illegal_sample", reason)
	}

	alice.expectSilence()
}

func TestZeroWishHaltsWithPose(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	halt := haltMidSteer(t, alice)

	if halt.ID != aliceWelcome.You {
		t.Fatalf("halt pose is for player %d, want alice (%d)", halt.ID, aliceWelcome.You)
	}

	seen := bob.awaitPlayerPose(aliceWelcome.You)
	if math.Abs(seen.X-halt.X) > 1e-6 || math.Abs(seen.Z-halt.Z) > 1e-6 {
		t.Fatalf("bob was told alice halts at (%v,%v), alice was told (%v,%v)", seen.X, seen.Z, halt.X, halt.Z)
	}
}

func TestHaltedPlayerStaysHalted(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	halt := haltMidSteer(t, alice)
	bob.drain()

	time.Sleep(4 * game.TickDuration)

	alice.expectSilence()
	bob.expectSilence()

	carol := h.dial("carol")
	carolWelcome := carol.welcome()
	if carolWelcome.Tick <= halt.Tick {
		t.Fatalf("carol joined at tick %d, not after the halt at %d; the test proved nothing",
			carolWelcome.Tick, halt.Tick)
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
	if math.Abs(alicePos.X-halt.X) > 1e-6 || math.Abs(alicePos.Z-halt.Z) > 1e-6 {
		t.Fatalf("alice is at [%v %v] several ticks after halting at (%v,%v); she is still moving",
			alicePos.X, alicePos.Z, halt.X, halt.Z)
	}

	carol.expectSilence()
}

func haltMidSteer(t *testing.T, c *client) mnet.Pose {
	t.Helper()
	c.move(1, 0)
	walking := c.awaitPose()
	c.move(0, 0)
	halt := c.awaitPose()
	if halt.Tick < walking.Tick {
		t.Fatalf("halt tick %d before walk tick %d", halt.Tick, walking.Tick)
	}
	return halt
}

func TestUnknownMessageIsIgnored(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	alice.sendRaw(`{"tick":{"t":9000}}`)
	alice.sendRaw(`{"teleport":{"x":1}}`)

	ignored := h.awaitEvents(game.EvIntentIgnored, 2)
	for _, ev := range ignored {
		if got := ev["reason"]; got != string(mnet.ReasonUnknownMessage) {
			t.Fatalf("ignored for %v, want %q", got, mnet.ReasonUnknownMessage)
		}
	}

	alice.expectSilence()
	alice.move(1, 0)
	if p := alice.awaitPose(); p.ID != aliceWelcome.You {
		t.Fatalf("after two unknown messages, alice got a pose for %d, want herself (%d)", p.ID, aliceWelcome.You)
	}
}

func TestReservedFieldsAreIgnored(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	alice.sendRaw(`{"move":{"dx":1,"dz":0,"seq":17,"invented_later":"whatever"}}`)

	got := alice.awaitPose()
	if got.ID != aliceWelcome.You {
		t.Fatalf("pose is for player %d, want alice (%d)", got.ID, aliceWelcome.You)
	}
	if got.X <= 0 {
		t.Fatalf("pose x=%v, want progress along +x", got.X)
	}
}

func TestMalformedFramesAreRejectedWithAReason(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	aliceWelcome := alice.welcome()

	cases := []struct {
		frame   string
		want    mnet.RejectReason
		wantEv  string
	}{
		{`this is not json`, mnet.ReasonMalformedJSON, game.EvMoveToRejected},
		{`{"move":{"dx":5}}`, mnet.ReasonMissingField, game.EvMoveRejected},
		{`{"move":{"dx":"over there","dz":0}}`, mnet.ReasonMalformedJSON, game.EvMoveRejected},
		{`{"move":{"dx":1e400,"dz":0}}`, mnet.ReasonMalformedJSON, game.EvMoveRejected},
	}
	for _, tc := range cases {
		before := len(h.eventsNamed(tc.wantEv))
		alice.sendRaw(tc.frame)
		rejected := h.awaitEvents(tc.wantEv, before+1)
		got := rejected[len(rejected)-1]
		if reason := got["reason"]; reason != string(tc.want) {
			t.Fatalf("frame %s rejected with %v, want %q", tc.frame, reason, tc.want)
		}
		if refusal := alice.errorFrame(); refusal.Msg == "" {
			t.Fatalf("frame %s produced an error with no message", tc.frame)
		}
	}

	alice.expectSilence()

	alice.move(1, 0)
	if p := alice.awaitPose(); p.ID != aliceWelcome.You {
		t.Fatalf("after four bad frames, alice got a pose for %d, want herself (%d)", p.ID, aliceWelcome.You)
	}
}

func TestUninterpretableFrameClosesTheConnection(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		send   func(*client)
		reason mnet.RejectReason
	}{
		{"no keys", func(c *client) { c.sendRaw(`{}`) }, mnet.ReasonProtocolError},
		{"two keys", func(c *client) { c.sendRaw(`{"move":{"dx":1,"dz":2},"use":{}}`) }, mnet.ReasonProtocolError},
		{"binary frame", func(c *client) { c.sendBinary([]byte(`{"move":{"dx":1,"dz":2}}`)) }, mnet.ReasonBinaryFrame},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)

			alice := h.dial("alice")
			alice.welcome()
			tc.send(alice)

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
	if got := disconnects[0]["reason"]; got != mnet.DisconnectClosed {
		t.Fatalf("client_disconnected logged reason %v for a clean logout, want %q", got, mnet.DisconnectClosed)
	}
	if got, ok := disconnects[0]["detail"]; ok {
		t.Fatalf("client_disconnected logged detail %v for a clean logout; only one path can reach it, so the key must be absent", got)
	}
}

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

func TestConcurrentTrafficStaysConsistent(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	stop := make(chan struct{})
	var wg sync.WaitGroup
	bg := newBackgroundErr()

	wg.Add(1)
	go func() {
		defer wg.Done()
		go alice.drainUntil(stop)
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				_ = alice.moveBackground(0, 0)
				return
			case <-ticker.C:
				if err := alice.moveBackground(1, 0); err != nil {
					bg.report(err)
					return
				}
			}
		}
	}()

	time.Sleep(time.Second)
	close(stop)
	wg.Wait()
	bg.check(t)

	time.Sleep(3 * game.TickDuration)
	alice.move(0, 1)
	seen := bob.awaitPlayerPose(alice.id)
	if seen.ID != alice.id {
		t.Fatalf("after the storm, bob saw pose for %d, want alice %d", seen.ID, alice.id)
	}
}

func TestShutdownWithOpenConnections(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.move(1, 0)
	alice.awaitPose()
	bob.awaitPlayerPose(alice.id)

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
