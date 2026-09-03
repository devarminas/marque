package net_test

// Resume under contention: a token claimed twice, a player suspended and
// resumed more than once, and a suspended body losing a race it was walking to.
//
// Written by M2a's second verifier and adopted verbatim; the assertions are
// theirs. Against the real harness.

import (
	"sync"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
)

func expiresTickOf(t *testing.T, ev map[string]any) float64 {
	t.Helper()
	v, ok := ev["expires_tick"].(float64)
	if !ok {
		t.Fatalf("player_suspended without a numeric expires_tick: %+v", ev)
	}
	return v
}

func TestProbeResumeDestroyResumeInsideOneGrace(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)

	aliceTwo := h.dialResume("alice-2", first.Session)
	second := readJoinStep(aliceTwo)
	if second.welcome.You != first.You || second.welcome.Session != first.Session {
		t.Fatalf("first resume: you=%d session=%q, want %d/%q", second.welcome.You, second.welcome.Session, first.You, first.Session)
	}
	h.awaitEvents(game.EvPlayerResumed, 1)

	intruder := h.dialResume("intruder", first.Session)
	if r := intruder.errorFrame(); r.Msg != "session is still connected" {
		t.Fatalf("a token whose player was just resumed should be refused, got %q", r.Msg)
	}
	intruder.expectClosed()

	time.Sleep(2 * game.TickDuration)
	aliceTwo.destroy()
	suspended := h.awaitEvents(game.EvPlayerSuspended, 2)
	if expiresTickOf(t, suspended[1]) <= expiresTickOf(t, suspended[0]) {
		t.Fatalf("the second suspension did not restart the grace: %v then %v", suspended[0]["expires_tick"], suspended[1]["expires_tick"])
	}

	aliceThree := h.dialResume("alice-3", first.Session)
	third := readJoinStep(aliceThree)
	if third.welcome.You != first.You || third.welcome.Session != first.Session {
		t.Fatalf("second resume: you=%d session=%q, want %d/%q", third.welcome.You, third.welcome.Session, first.You, first.Session)
	}
	h.awaitEvents(game.EvPlayerResumed, 2)
	if got := h.eventsNamed(game.EvPlayerExpired); len(got) != 0 {
		t.Fatalf("expired inside the grace: %+v", got)
	}
	if got := h.eventsNamed(game.EvConnected); len(got) != 2 {
		t.Fatalf("client_connected logged %d times, want 2 (alice, bob)", len(got))
	}
	bob.expectSilence()

	aliceThree.moveTo(5, 5)
	if got := aliceThree.path().ID; got != first.You {
		t.Fatalf("the twice-resumed connection drives player %d, want %d", got, first.You)
	}
	if got := bob.awaitPath(first.You).ID; got != first.You {
		t.Fatalf("bob saw the walk for %d", got)
	}
}

func TestProbeTwoConnectionsRaceForOneSuspendedToken(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()
	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)

	claimants := make([]*client, 2)
	var wg sync.WaitGroup
	for i := range claimants {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			claimants[i] = h.dialResume([]string{"left", "right"}[i], first.Session)
		}(i)
	}
	wg.Wait()

	welcomed, refused := 0, 0
	for _, c := range claimants {
		f := c.next()
		switch {
		case f.Welcome != nil:
			welcomed++
			if f.Welcome.You != first.You || f.Welcome.Session != first.Session {
				t.Fatalf("client %s resumed as %d/%q, want %d/%q", c.name, f.Welcome.You, f.Welcome.Session, first.You, first.Session)
			}
			for g := c.next(); g.Inventory == nil; g = c.next() {
			}
		case f.Error != nil:
			refused++
			if f.Error.Msg != "session is still connected" {
				t.Fatalf("client %s refused with %q", c.name, f.Error.Msg)
			}
			c.expectClosed()
		default:
			t.Fatalf("client %s got %s first: %s", c.name, f.kind(), f.raw)
		}
	}
	if welcomed != 1 || refused != 1 {
		t.Fatalf("welcomed=%d refused=%d, want exactly one of each", welcomed, refused)
	}
	h.awaitEvents(game.EvPlayerResumed, 1)
	h.awaitEvents(game.EvResumeRefused, 1)
	if got := h.eventsNamed(game.EvPlayerResumed); len(got) != 1 {
		t.Fatalf("player_resumed logged %d times", len(got))
	}
	if got := h.eventsNamed(game.EvConnected); len(got) != 1 {
		t.Fatalf("client_connected logged %d times, want 1", len(got))
	}
}

func TestProbeRefusedConnectionThenFreshJoinWorks(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()

	intruder := h.dialResume("intruder", first.Session)
	intruder.errorFrame()
	intruder.expectClosed()
	h.awaitEvents(game.EvResumeRefused, 1)

	fresh := h.dial("fresh")
	fw := fresh.welcome()
	if fw.You == first.You || fw.Session == first.Session {
		t.Fatalf("fresh join after a refusal got %d/%q, alice's identity", fw.You, fw.Session)
	}
	if !sessionToken.MatchString(fw.Session) {
		t.Fatalf("fresh session %q is not 32 hex", fw.Session)
	}
	if len(fw.Players) != 2 {
		t.Fatalf("fresh welcome lists %d players, want 2", len(fw.Players))
	}
	if got := alice.spawn().ID; got != fw.You {
		t.Fatalf("alice saw spawn %d, want %d", got, fw.You)
	}
	if got := h.eventsNamed(game.EvConnected); len(got) != 2 {
		t.Fatalf("client_connected logged %d times, want 2", len(got))
	}
	if got := h.eventsNamed(game.EvDisconnected); len(got) != 0 {
		t.Fatalf("a refused connection produced client_disconnected: %+v", got)
	}
}

// A suspended player loses a contested pickup: losePickup sends to a nil conn
// and broadcasts a halt for a body nobody is driving.
func TestProbeSuspendedLoserOfAContestedPickupResumesEmptyHanded(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	bob := h.dial("bob")
	bw := bob.welcome()
	item := bw.Items[0].ID
	bob.moveTo(farItem, 0)
	bob.path()
	h.awaitEvents(game.EvArrived, 1)

	alice := h.dial("alice")
	aw := alice.welcome()
	bob.spawn()

	alice.pickup(item)
	alice.path()
	bob.path()
	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)

	bob.pickup(item)
	resolved := h.awaitEvents(game.EvPickupResolved, 1)
	if resolved[0]["player"] != float64(bw.You) {
		t.Fatalf("pickup resolved for %v, want bob (%d)", resolved[0]["player"], bw.You)
	}
	lost := h.awaitEvents(game.EvPickupLost, 1)
	if lost[0]["player"] != float64(aw.You) {
		t.Fatalf("pickup_lost for %v, want suspended alice (%d)", lost[0]["player"], aw.You)
	}
	bob.awaitItemDespawn(item)
	if halt := bob.awaitHaltPath(aw.You); len(halt.Points) != 1 {
		t.Fatalf("halt for the suspended loser has %d points", len(halt.Points))
	}

	step := readJoinStep(h.dialResume("alice-again", aw.Session))
	if step.welcome.You != aw.You {
		t.Fatalf("resumed as %d, want %d", step.welcome.You, aw.You)
	}
	if len(step.inventory.Slots) != 0 {
		t.Fatalf("the loser resumed holding %+v", step.inventory.Slots)
	}
	if len(step.welcome.Items) != 0 {
		t.Fatalf("the world still lists %+v", step.welcome.Items)
	}
	if _, walking := step.pathFor(aw.You); walking {
		t.Fatal("the halted loser was replayed as still walking")
	}
	if got := h.eventsNamed(game.EvPlayerExpired); len(got) != 0 {
		t.Fatalf("expired: %+v", got)
	}
}
