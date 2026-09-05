package net_test

// The sender's half of PROTOCOL.md's rule that an empty list on the wire is [],
// never null. Asserted on the bytes that crossed the socket, because that is the
// only place the defect is visible: every one of these lists is already an empty
// non-nil slice in Go, and a test that read the decoded struct would pass just
// as happily against a server that sent null.

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// TestTheJoinStepSendsEmptyListsAsArrays covers the three frames that matter
// most, because every single join sends all of them: the welcome of a world with
// no items, the first inventory of a player holding nothing, and the first
// equipment of a player wearing nothing.
//
// A Go nil slice marshals as null, silently. A strict client reading
// "items":null as "not an array" drops the whole frame, and for welcome that
// means it never joins and sits frozen, with nothing wrong-looking on either
// side. Found by a verifier reading across the two halves before either shipped.
func TestTheJoinStepSendsEmptyListsAsArrays(t *testing.T) {
	h := newHarness(t)

	alice := h.dial("alice")

	welcome := alice.welcomeEnvelope()
	if !strings.Contains(welcome.raw, `"items":[]`) {
		t.Errorf("an empty world's welcome encodes as %s, want it to carry \"items\":[]", welcome.raw)
	}
	if !strings.Contains(welcome.raw, `"nodes":[]`) {
		t.Errorf("an empty world's welcome encodes as %s, want it to carry \"nodes\":[]", welcome.raw)
	}
	if !strings.Contains(welcome.raw, `"players":[{`) {
		t.Errorf("welcome encodes as %s, want \"players\" to be an array", welcome.raw)
	}
	assertNoNulls(t, "welcome", welcome.raw)

	inv := alice.awaitInventoryFrame()
	if !strings.Contains(inv.raw, `"slots":[]`) {
		t.Errorf("a fresh player's inventory encodes as %s, want it to carry \"slots\":[]", inv.raw)
	}
	assertNoNulls(t, "inventory", inv.raw)

	// M3a's frame, and the one where an empty list is the ordinary case rather
	// than the edge: a joining player is wearing nothing, every time.
	worn := alice.equipmentFrame()
	if !strings.Contains(worn.raw, `"slots":[]`) {
		t.Errorf("a fresh player's equipment encodes as %s, want it to carry \"slots\":[]", worn.raw)
	}
	if !strings.Contains(worn.raw, `"worn":["`) {
		t.Errorf("equipment encodes as %s, want \"worn\" to be an array of slot names", worn.raw)
	}
	assertNoNulls(t, "equipment", worn.raw)
}

// TestNoFrameOfASessionCarriesANull is the same rule applied to every list the
// server can send, rather than to the two that are easiest to get wrong. It
// drives one session through a walk, a pickup, a halt and a refusal, and holds
// every frame that comes back to the rule.
//
// A path's "points" is the third list on the wire and the one with no empty
// case: a path always carries at least one point, and a client that read null
// there would drop a walk instead of a join.
func TestNoFrameOfASessionCarriesANull(t *testing.T) {
	// Far enough that both racers are still mid-walk when the contest is
	// decided, so the loser's halt path is a real one, and near enough that the
	// walk costs the suite a handful of ticks rather than a couple of seconds.
	const contested = 2.0
	h := newHarness(t, acornAt(contested, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	// A walk, then a contested pickup, which is what produces an ordinary path,
	// a one-element halt path, an item_despawn, an inventory and an error, and
	// then a drop, which is the only thing that produces an item_spawn once the
	// world is running.
	//
	// The session is driven entirely through the log, never by reading a
	// client's frames: everything either client is sent has to still be sitting
	// in its queue for the collect below to walk.
	alice.moveTo(2, 2)
	alice.pickup(item)
	bob.pickup(item)
	h.awaitEvents(game.EvPickupLost, 1)
	h.awaitEvents(game.EvPickupResolved, 1) // alice joined first, so alice holds it, in slot 0
	alice.drop(0)
	h.awaitEvents(game.EvDrop, 1)
	alice.pickup(item) // now stale, so an error comes back
	h.awaitEvents(game.EvPickupRejected, 1)

	kinds := make(map[string]int)
	for _, c := range []*client{alice, bob} {
		for _, f := range c.collect(silenceWindow) {
			assertNoNulls(t, c.name+"'s "+f.kind(), f.raw)
			if f.Path != nil && !strings.Contains(f.raw, `"points":[[`) {
				t.Errorf("%s carries no array of points: %s", f.kind(), f.raw)
			}
			kinds[f.kind()]++
		}
	}

	// The assertion above is vacuous if the session produced no frames, and
	// weaker than it looks if it produced only one kind of them.
	for _, want := range []string{"path", "item_spawn", "item_despawn", "inventory", "error"} {
		if kinds[want] == 0 {
			t.Fatalf("the session produced no %s frame, so nothing checked one: saw %v", want, kinds)
		}
	}
}

// TestANilListWouldGoOutAsNull is the hazard itself, pinned so that the two
// tests above are not mistaken for tests of encoding/json.
//
// It asserts the marshaller's behaviour, deliberately: the rule that every list
// is initialised before it reaches Encode is only load-bearing while this is
// true, and a reader who does not know it cannot tell whether "items":[] is
// guaranteed by the type or by the care taken at every construction site.
func TestANilListWouldGoOutAsNull(t *testing.T) {
	payload, err := mnet.Encode(mnet.Welcome{You: 1, TickMS: 150})
	if err != nil {
		t.Fatalf("encoding a welcome: %v", err)
	}
	if !strings.Contains(string(payload), `"items":null`) {
		t.Fatalf("a welcome built with nil lists encodes as %s; if the marshaller now writes [] for a "+
			"nil slice, the initialise-every-list rule has a second reason to exist and this test should "+
			"say so rather than be deleted", payload)
	}
}

// assertNoNulls fails if any value anywhere inside one frame is JSON null.
//
// No field of any server message is legitimately null: an empty list is [], and
// an absent scalar is omitted rather than nulled. Checked structurally rather
// than by searching the text, so that an item kind spelled "null" cannot fail it
// and a null nested inside a list cannot slip past it.
func assertNoNulls(t *testing.T, what, raw string) {
	t.Helper()

	var decoded any
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		t.Fatalf("%s is not JSON: %v: %s", what, err, raw)
	}

	var walk func(path string, v any)
	walk = func(path string, v any) {
		switch v := v.(type) {
		case nil:
			t.Errorf("%s carries a null at %s: %s", what, path, raw)
		case map[string]any:
			for key, child := range v {
				walk(path+"."+key, child)
			}
		case []any:
			for i, child := range v {
				walk(fmt.Sprintf("%s[%d]", path, i), child)
			}
		}
	}
	walk("", decoded)
}
