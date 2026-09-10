package net_test

import (
	"math"
	"net"
	"regexp"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

var sessionToken = regexp.MustCompile(`^[0-9a-f]{32}$`)

const shortGrace = 4

const unknownToken = "ffffffffffffffffffffffffffffffff"

const waitInsideTheGrace = 4 * game.TickDuration

type joinStep struct {
	welcome   mnet.Welcome
	paths     []mnet.Path
	inventory mnet.Inventory
	equipment mnet.Equipment
	class     mnet.Class
	skills    mnet.Skills
	questLog  mnet.QuestLog
}

func (s joinStep) pathFor(id mnet.PlayerID) (mnet.Path, bool) {
	for _, p := range s.paths {
		if p.ID == id {
			return p, true
		}
	}
	return mnet.Path{}, false
}

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
			if cl := c.next(); cl.Class != nil {
				step.class = *cl.Class
			} else {
				c.t.Fatalf("client %s: got a %s frame, want class after equipment: %s", c.name, cl.kind(), cl.raw)
			}
			if sk := c.next(); sk.Skills != nil {
				step.skills = *sk.Skills
			} else {
				c.t.Fatalf("client %s: got a %s frame, want skills after class: %s", c.name, sk.kind(), sk.raw)
			}
			if ql := c.next(); ql.QuestLog != nil {
				step.questLog = *ql.QuestLog
			} else {
				c.t.Fatalf("client %s: got a %s frame, want quest_log after skills: %s", c.name, ql.kind(), ql.raw)
			}
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
	if got := h.awaitEvents(game.EvDisconnected, 1)[0]["reason"]; got != mnet.DisconnectPeerGone {
		t.Fatalf("an abrupt death logged reason %v, want %q", got, mnet.DisconnectPeerGone)
	}
}

const tokenScanGrace = 20

func TestNoSessionTokenIsLoggedAnywhere(t *testing.T) {
	h := newHarnessWithGrace(t, tokenScanGrace, acornAt(1, 0))

	alice := h.dial("alice")
	first := alice.welcome()
	alice.pickup(first.Items[0].ID)
	alice.awaitInventory()

	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	resumed := h.dialResume("alice-again", first.Session)
	readJoinStep(resumed)
	h.awaitEvents(game.EvPlayerResumed, 1)

	intruder := h.dialResume("intruder", first.Session)
	intruder.errorFrame()
	intruder.expectClosed()
	h.awaitEvents(game.EvResumeRefused, 1)

	readJoinStep(h.dialResume("stranger", unknownToken))
	h.awaitEvents(game.EvResumeUnknown, 1)

	bob := h.dial("bob")
	bobFirst := readJoinStep(bob).welcome
	bob.destroy()
	h.awaitEvents(game.EvPlayerExpired, 1)

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

func TestEveryResumeEventNamesTheConnectionItIsAbout(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()
	aliceRemote := remoteOf(t, h.awaitEvents(game.EvConnected, 1)[0])

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

	stranger := h.dialResume("stranger", unknownToken)
	stranger.welcome()
	unknown := h.awaitEvents(game.EvResumeUnknown, 1)[0]
	remoteOf(t, unknown)
	if _, named := unknown["player"]; named {
		t.Fatalf("resume_unknown names a player: %+v; the token named nobody", unknown)
	}

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
	if items := step.welcome.Items; len(items) != 0 {
		t.Fatalf("the world holds %+v, want the acorn to be in alice's inventory", items)
	}
}

func TestAResumedWalkerIsToldWhereItsOwnBodyIs(t *testing.T) {
	const destination = 100.0

	h := newHarness(t)

	alice := h.dial("alice")
	first := alice.welcome()
	alice.move(1, 0)
	alice.awaitPose()

	time.Sleep(4 * game.TickDuration)
	alice.destroy()
	h.awaitEvents(game.EvPlayerSuspended, 1)
	time.Sleep(waitInsideTheGrace)

	step := readJoinStep(h.dialResume("alice-again", first.Session))
	if _, ok := step.pathFor(first.You); ok {
		t.Fatalf("resume replayed a path for a steering player; steer is pose-only")
	}
	here := positionOf(t, step.welcome, first.You)
	if here.X <= 0 {
		t.Fatalf("welcome puts resumed body at x=%v, want progress along +x", here.X)
	}
	if here.Y != 0 {
		t.Fatalf("welcome y=%v, want 0", here.Y)
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

	alice.walkTo(5, 5)
	if math.Hypot(alice.x-5, alice.z-5) > tickStep*1.5 {
		t.Fatalf("alice ended at (%v,%v), want near [5 5]", alice.x, alice.z)
	}

	h.awaitEvents(game.EvResumeRefused, 1)
	if joins := h.eventsNamed(game.EvConnected); len(joins) != 1 {
		t.Fatalf("the log holds %d client_connected events, want 1: a refused connection is never admitted", len(joins))
	}
	if resumed := h.eventsNamed(game.EvPlayerResumed); len(resumed) != 0 {
		t.Fatalf("a refused connection was recorded as a resume: %+v", resumed)
	}
	if left := h.eventsNamed(game.EvDisconnected); len(left) != 0 {
		t.Fatalf("a refused connection produced %+v", left)
	}
}

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

	h.awaitEvents(game.EvPickupResolved, 1)
	bob.awaitItemDespawn(item)

	step := readJoinStep(h.dialResume("alice-again", first.Session))
	if len(step.inventory.Slots) != 1 || step.inventory.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("the resumed inventory holds %+v, want the acorn the body walked to while nobody was listening", step.inventory.Slots)
	}
}
