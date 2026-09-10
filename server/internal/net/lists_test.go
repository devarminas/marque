package net_test


import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

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

	worn := alice.equipmentFrame()
	if !strings.Contains(worn.raw, `"slots":[]`) {
		t.Errorf("a fresh player's equipment encodes as %s, want it to carry \"slots\":[]", worn.raw)
	}
	if !strings.Contains(worn.raw, `"worn":["`) {
		t.Errorf("equipment encodes as %s, want \"worn\" to be an array of slot names", worn.raw)
	}
	assertNoNulls(t, "equipment", worn.raw)
}

func TestNoFrameOfASessionCarriesANull(t *testing.T) {
	const contested = 2.0
	h := newHarness(t, acornAt(contested, 0))

	alice := h.dial("alice")
	welcome := alice.welcome()
	item := welcome.Items[0].ID

	bob := h.dial("bob")
	bob.welcome()
	alice.spawn()

	alice.moveTo(2, 2)
	alice.pickup(item)
	bob.pickup(item)
	h.awaitEvents(game.EvPickupLost, 1)
	h.awaitEvents(game.EvPickupResolved, 1)
	alice.drop(0)
	h.awaitEvents(game.EvDrop, 1)
	alice.pickup(item)
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

	for _, want := range []string{"path", "item_spawn", "item_despawn", "inventory", "error"} {
		if kinds[want] == 0 {
			t.Fatalf("the session produced no %s frame, so nothing checked one: saw %v", want, kinds)
		}
	}
}

func TestANilListWouldGoOutAsNull(t *testing.T) {
	payload, err := mnet.Encode(mnet.Welcome{You: 1, TickMS: 40})
	if err != nil {
		t.Fatalf("encoding a welcome: %v", err)
	}
	if !strings.Contains(string(payload), `"items":null`) {
		t.Fatalf("a welcome built with nil lists encodes as %s; if the marshaller now writes [] for a "+
			"nil slice, the initialise-every-list rule has a second reason to exist and this test should "+
			"say so rather than be deleted", payload)
	}
}

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
