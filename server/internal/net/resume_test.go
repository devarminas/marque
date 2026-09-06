package net_test

// A player outliving its socket. PROTOCOL.md, "The session token" and "When
// the connection dies", is the contract.

import (
	"net"
	"regexp"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// The shape PROTOCOL.md fixes: 32 lowercase hex characters.
var sessionToken = regexp.MustCompile(`^[0-9a-f]{32}$`)

// Resume grace in ticks for the one test that waits one out: long enough not
// to expire by accident, short enough to sit through.
const shortGrace = 4

// Well-formed and names nobody. Spelled out rather than derived from a real
// token: an issued-then-retired token is a different case with its own tests.
const unknownToken = "ffffffffffffffffffffffffffffffff"

// Lets several ticks of the grace pass before a resume. Resuming within a tick
// of the suspension proves only that state survives a socket death; sleeping
// here makes the tests fail under a one-tick grace.
const waitInsideTheGrace = 4 * game.TickDuration

// A test cannot assume how many frames the join step holds: any player
// mid-walk puts one more path in it, including the resuming player's own.
type joinStep struct {
	welcome   mnet.Welcome
	paths     []mnet.Path
	inventory mnet.Inventory
	equipment mnet.Equipment
}

// pathFor returns the replayed path for one player, and whether the step
// carried one at all.
func (s joinStep) pathFor(id mnet.PlayerID) (mnet.Path, bool) {
	for _, p := range s.paths {
		if p.ID == id {
			return p, true
		}
	}
	return mnet.Path{}, false
}

// readJoinStep consumes the step in order, insisting on the shape PROTOCOL.md's
// "Ordering and the join race" fixes: welcome first, then path replays, then the
// inventory, then the equipment that ends it.
func readJoinStep(c *client) joinStep {
	c.t.Helper()

	step := joinStep{welcome: c.welcomeFrame()}
	var carried bool
	for {
		f := c.next()
		switch {
		case f.Equipment != nil:
			if !carried {
				c.t.Fatalf("client %s: equipment arrived before the inventory, which the join step sends first: %s", c.name, f.raw)
			}
			step.equipment = *f.Equipment
			return step
		case f.Inventory != nil:
			step.inventory = *f.Inventory
			carried = true
		case f.Path != nil:
			if carried {
				c.t.Fatalf("client %s: a path replay arrived after the inventory, which the replays precede: %s", c.name, f.raw)
			}
			step.paths = append(step.paths, *f.Path)
		default:
			c.t.Fatalf("client %s: a %s frame arrived inside the join step, which carries only path replays between welcome and inventory: %s",
				c.name, f.kind(), f.raw)
		}
	}
}

func TestEveryPlayerGetsItsOwnSessionToken(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice").welcome()
	bob := h.dial("bob").welcome()

	for _, got := range []mnet.Welcome{alice, bob} {
		if !sessionToken.MatchString(got.Session) {
			t.Fatalf("player %d got session %q, want 32 hex characters", got.You, got.Session)
		}
	}
	if alice.Session == bob.Session {
		t.Fatalf("two players share the session token %q; a token names one player", alice.Session)
	}
}

func TestAResumedPlayerIsTheSamePlayer(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)

	bob.expectSilence()

	resumed := h.dialResume("alice-again", first.Session)
	second := resumed.welcome()

	if second.You != first.You {
		t.Fatalf("resumed as player %d, want the player the token names (%d)", second.You, first.You)
	}
	if second.Session != first.Session {
		t.Fatalf("resume reissued session %q, want the same token across every resume (%q)", second.Session, first.Session)
	}
	bob.expectSilence()

	suspended := h.awaitEvents(game.EvPlayerSuspended, 1)
	if got := suspended[0]["player"]; got != float64(first.You) {
		t.Fatalf("player_suspended named player %v, want %d", got, first.You)
	}
	if _, ok := suspended[0]["expires_tick"]; !ok {
		t.Fatalf("player_suspended carries no expires_tick: %+v", suspended[0])
	}
	resumes := h.awaitEvents(game.EvPlayerResumed, 1)
	if got := resumes[0]["player"]; got != float64(first.You) {
		t.Fatalf("player_resumed named player %v, want %d", got, first.You)
	}
	if expired := h.eventsNamed(game.EvPlayerExpired); len(expired) != 0 {
		t.Fatalf("the body expired inside its own grace: %+v", expired)
	}
	// The socket died, and its latched reason is what decided the suspension.
	if got := h.awaitEvents(game.EvDisconnected, 1)[0]["reason"]; got != mnet.DisconnectPeerGone {
		t.Fatalf("an abrupt death logged reason %v, want %q", got, mnet.DisconnectPeerGone)
	}
}

// tokenScanGrace is short enough to sit through an expiry and long enough that
// a resume comfortably lands inside it. Both have to happen in one run of
// TestNoSessionTokenIsLoggedAnywhere, which is what fixes it between the two.
const tokenScanGrace = 20

// Scans every field of every line, not just the resume events: the rule is
// about the log, so a token added to any other line later is caught without
// anybody remembering to come back and look. The run drives all six paths a
// token can take (join, suspend, resume, unknown, refuse, expire), because a
// scan can only catch a leak on a path it actually walked.
func TestNoSessionTokenIsLoggedAnywhere(t *testing.T) {
	h := newHarnessWithGrace(t, tokenScanGrace, acornAt(1, 0))

	// Join, and carry something, so the item events are in the scan too.
	alice := h.dial("alice")
	first := alice.welcome()
	alice.pickup(first.Items[0].ID)
	alice.awaitInventory()

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	resumed := h.dialResume("alice-again", first.Session)
	readJoinStep(resumed)
	h.awaitEvents(game.EvPlayerResumed, 1)

	// Refuse: alice's token while alice is connected.
	intruder := h.dialResume("intruder", first.Session)
	intruder.errorFrame()
	intruder.expectClosed()
	h.awaitEvents(game.EvResumeRefused, 1)

	// Unknown: a well-formed token naming nobody.
	readJoinStep(h.dialResume("stranger", unknownToken))
	h.awaitEvents(game.EvResumeUnknown, 1)

	// Expire: a second player left to run its grace out.
	bob := h.dial("bob")
	// readJoinStep, not welcome: alice may still be walking to the acorn, and
	// then bob's join step carries a replay for her between the two frames.
	bobFirst := readJoinStep(bob).welcome
	bob.destroy()
	h.awaitEvents(game.EvPlayerExpired, 1)

	// Every event name the six paths can produce is now in the log.
	for _, name := range []string{
		game.EvConnected, game.EvDisconnected, game.EvPlayerSuspended,
		game.EvPlayerResumed, game.EvResumeRefused, game.EvResumeUnknown,
		game.EvPlayerExpired,
	} {
		if got := h.eventsNamed(name); len(got) == 0 {
			t.Fatalf("no %s event was written, so the scan below never looked at one", name)
		}
	}

	for _, token := range []string{first.Session, bobFirst.Session, unknownToken} {
		for _, ev := range h.logEvents() {
			for key, value := range ev {
				if s, isString := value.(string); isString && s == token {
					t.Fatalf("the event log carries a session token in %q of a %v line: %+v", key, ev["ev"], ev)
				}
			}
		}
	}
}

// Holds the field sets PROTOCOL.md's log-vocabulary table fixes. A refusal or
// an unknown token has no player to name, so a player id on those lines would
// file the connection under an uninvolved player's id.
func TestEveryResumeEventNamesTheConnectionItIsAbout(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()
	aliceRemote := remoteOf(t, h.awaitEvents(game.EvConnected, 1)[0])

	// Refused: a second live socket, so its remote must differ from alice's.
	intruder := h.dialResume("intruder", first.Session)
	intruder.errorFrame()
	intruder.expectClosed()
	refused := h.awaitEvents(game.EvResumeRefused, 1)[0]
	if got := remoteOf(t, refused); got == aliceRemote {
		t.Fatalf("resume_refused names %q, which is the remote of the connection that already holds the player", got)
	}
	if _, named := refused["player"]; named {
		t.Fatalf("resume_refused names a player: %+v; no player was created for it, and naming the one it asked for files it under an uninvolved id", refused)
	}

	// Unknown: same, and it also has no player to name.
	stranger := h.dialResume("stranger", unknownToken)
	stranger.welcome()
	unknown := h.awaitEvents(game.EvResumeUnknown, 1)[0]
	remoteOf(t, unknown)
	if _, named := unknown["player"]; named {
		t.Fatalf("resume_unknown names a player: %+v; the token named nobody", unknown)
	}

	// Resumed: this one does name a player, and the remote is the new socket's.
	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	readJoinStep(h.dialResume("alice-again", first.Session))
	resumed := h.awaitEvents(game.EvPlayerResumed, 1)[0]
	remoteOf(t, resumed)
	if got := resumed["player"]; got != float64(first.You) {
		t.Fatalf("player_resumed names player %v, want %d", got, first.You)
	}
}

func remoteOf(t *testing.T, ev map[string]any) string {
	t.Helper()

	value, present := ev["remote"]
	if !present {
		t.Fatalf("%v carries no remote: %+v", ev["ev"], ev)
	}
	remote, isString := value.(string)
	if !isString {
		t.Fatalf("%v carries a non-string remote %#v", ev["ev"], value)
	}
	if _, _, err := net.SplitHostPort(remote); err != nil {
		t.Fatalf("%v carries remote %q, which is not host:port: %v", ev["ev"], remote, err)
	}
	return remote
}
func TestAResumedPlayerKeepsItsInventory(t *testing.T) {
	h := newHarness(t, acornAt(1, 0))

	alice := h.dial("alice")
	first := alice.welcome()
	item := first.Items[0].ID

	alice.pickup(item)
	if held := alice.awaitInventory(); len(held.Slots) != 1 || held.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("alice holds %+v before the socket dies, want one acorn", held.Slots)
	}

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	time.Sleep(waitInsideTheGrace)

	step := readJoinStep(h.dialResume("alice-again", first.Session))
	if len(step.inventory.Slots) != 1 {
		t.Fatalf("the resumed inventory holds %+v, want the acorn alice was carrying", step.inventory.Slots)
	}
	if got := step.inventory.Slots[0]; got.Slot != 0 || got.Kind != game.KindAcorn {
		t.Fatalf("the resumed inventory holds %q in slot %d, want an acorn in slot 0", got.Kind, got.Slot)
	}
	// The acorn is in a pocket rather than back on the ground, and the world
	// restated in the same step says so.
	if items := step.welcome.Items; len(items) != 0 {
		t.Fatalf("the world holds %+v, want the acorn to be in alice's inventory", items)
	}
}

	// The walk does not stop when the socket dies: without a replay for its own
	// id the resumed client draws itself where it left and slides the rest of
	// the way.
func TestAResumedWalkerIsToldWhereItsOwnBodyIs(t *testing.T) {
	// Far enough that the walk is still running well after the reconnect: a
	// hundred units at three units a second is thirty-three seconds of it.
	const destination = 100.0

	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()
	alice.moveTo(destination, 0)
	if start := alice.path().Points[0]; start != mnet.Pt(0, 0) {
		t.Fatalf("the walk starts at %v, want the spawn point", start)
	}

	// Let the body get somewhere that the position it left at is wrong about.
	time.Sleep(4 * game.TickDuration)
	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	time.Sleep(waitInsideTheGrace)

	step := readJoinStep(h.dialResume("alice-again", first.Session))
	replay, ok := step.pathFor(first.You)
	if !ok {
		t.Fatalf("the resume step carried no path for the resuming player (%d), only %+v; a client with no replay for its own body draws it at a stale position",
			first.You, step.paths)
	}
	if replay.StartTick != step.welcome.Tick {
		t.Fatalf("the replayed path starts at tick %d, want the welcome's tick %d; a replay is re-anchored, never resent verbatim",
			replay.StartTick, step.welcome.Tick)
	}
	if got := replay.Points[len(replay.Points)-1]; got != mnet.Pt(destination, 0) {
		t.Fatalf("the replayed path ends at %v, want the destination alice was walking to", got)
	}

	// points[0] is where the body is right now, which is what the welcome in
	// the same step says, and it is past the spawn point it set off from.
	here := positionOf(t, step.welcome, first.You)
	if replay.Points[0] != mnet.Pt(here.X, here.Z) {
		t.Fatalf("the replay starts at %v but welcome puts the body at (%v, %v); those two would only agree by luck if the replay were not re-anchored",
			replay.Points[0], here.X, here.Z)
	}
	if here.X <= 0 {
		t.Fatalf("the body is at x=%v after four ticks of walking, want it to have kept walking while nobody was listening", here.X)
	}
}

func TestAnExpiredPlayerIsGoneForGood(t *testing.T) {
	h := newHarnessWithGrace(t, shortGrace)

	alice := h.dial("alice")
	first := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.destroy()
	expired := h.awaitEvents(game.EvPlayerExpired, 1)
	if got := expired[0]["player"]; got != float64(first.You) {
		t.Fatalf("player_expired named player %v, want %d", got, first.You)
	}

	if gone := bob.despawn(); gone.ID != first.You {
		t.Fatalf("bob saw a despawn for player %d, want alice (%d)", gone.ID, first.You)
	}

	// The same token, now naming nothing: a fresh join.
	second := readJoinStep(h.dialResume("alice-again", first.Session)).welcome
	if second.You == first.You {
		t.Fatalf("a token for an expired player was resumed as player %d; the id must not come back", second.You)
	}
	if second.Session == first.Session {
		t.Fatalf("a token for an expired player was reissued (%q); an expired token names nothing", second.Session)
	}
	h.awaitEvents(game.EvResumeUnknown, 1)
	if resumed := h.eventsNamed(game.EvPlayerResumed); len(resumed) != 0 {
		t.Fatalf("an expired player was resumed: %+v", resumed)
	}
}

func TestACleanLogoutDoesNotLinger(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.close()

	if gone := bob.despawn(); gone.ID != first.You {
		t.Fatalf("bob saw a despawn for player %d, want alice (%d)", gone.ID, first.You)
	}
	if got := h.awaitEvents(game.EvDisconnected, 1)[0]["reason"]; got != mnet.DisconnectClosed {
		t.Fatalf("a clean logout logged reason %v, want %q", got, mnet.DisconnectClosed)
	}
	if suspended := h.eventsNamed(game.EvPlayerSuspended); len(suspended) != 0 {
		t.Fatalf("a clean logout suspended the player: %+v; the body would stand there for the whole grace", suspended)
	}

	// And the token died with the player rather than merely going unused.
	second := readJoinStep(h.dialResume("alice-again", first.Session)).welcome
	if second.You == first.You {
		t.Fatalf("a token for a player who logged out cleanly was resumed as player %d", second.You)
	}
	h.awaitEvents(game.EvResumeUnknown, 1)
}

func TestATokenWhosePlayerIsConnectedIsRefused(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()

	intruder := h.dialResume("intruder", first.Session)
	refusal := intruder.errorFrame()
	if refusal.Msg != "session is still connected" {
		t.Fatalf("the refusal reads %q, want the still-connected refusal", refusal.Msg)
	}
	if refusal.Re != "" {
		t.Fatalf("the refusal names re=%q; nothing this connection sent was rejected, so there is nothing to name", refusal.Re)
	}
	intruder.expectClosed()

	// This round trip also makes the three negative assertions below sound: the
	// intruder's disconnect reached the ordered event channel before this
	// move_to was written, so a path back proves the world has drained past it.
	alice.moveTo(5, 5)
	if got := alice.path().ID; got != first.You {
		t.Fatalf("alice's move produced a path for player %d, want %d", got, first.You)
	}

	h.awaitEvents(game.EvResumeRefused, 1)
	if joins := h.eventsNamed(game.EvConnected); len(joins) != 1 {
		t.Fatalf("the log holds %d client_connected events, want 1: a refused connection is never admitted", len(joins))
	}
	if resumed := h.eventsNamed(game.EvPlayerResumed); len(resumed) != 0 {
		t.Fatalf("a refused connection was recorded as a resume: %+v", resumed)
	}
	// A reader counting client_disconnected to ask how many players left must
	// not be handed a refused connection.
	if left := h.eventsNamed(game.EvDisconnected); len(left) != 0 {
		t.Fatalf("a refused connection produced %+v", left)
	}
}

	// Separates a suspended player from a frozen one: the walk finishes and a
	// pending pickup resolves into the kept inventory, and nothing else in this
	// file would fail if the tick loop quietly skipped them.
func TestASuspendedPlayerFinishesWhatItStarted(t *testing.T) {
	h := newHarness(t, acornAt(farItem, 0))

	alice := h.dial("alice")
	first := alice.welcome()
	item := first.Items[0].ID
	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.pickup(item)
	alice.path()
	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)

	// The pickup resolves with nobody listening, and the observer is told,
	// because an item leaving the ground is the world changing for everyone.
	h.awaitEvents(game.EvPickupResolved, 1)
	bob.awaitItemDespawn(item)

	step := readJoinStep(h.dialResume("alice-again", first.Session))
	if len(step.inventory.Slots) != 1 || step.inventory.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("the resumed inventory holds %+v, want the acorn the body walked to while nobody was listening", step.inventory.Slots)
	}
}
