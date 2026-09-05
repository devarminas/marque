package net_test

import (
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestUseConvertsLogsIntoSticksInOneTransaction(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindLogs})

	alice := h.dial("alice")
	alice.welcome()

	alice.use(0, 0)

	inv := alice.awaitInventory()
	if len(inv.Slots) != 1 || inv.Slots[0].Kind != game.KindSticks || inv.Slots[0].Slot != 0 {
		t.Fatalf("inventory %+v, want one sticks in slot 0", inv.Slots)
	}
	done := h.awaitEvents(game.EvUse, 1)
	if got := done[0]["from"]; got != game.KindLogs {
		t.Errorf("%s from=%v, want %q", game.EvUse, got, game.KindLogs)
	}
	if got := done[0]["to"]; got != game.KindSticks {
		t.Errorf("%s to=%v, want %q", game.EvUse, got, game.KindSticks)
	}
	alice.expectSilence()
}

func TestUseOfNonLogsIsRefusedAndInventoryUnchanged(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindAcorn})

	alice := h.dial("alice")
	world := alice.welcome()

	alice.use(0, 0)

	got := alice.awaitError()
	if got.Re != mnet.MsgUse {
		t.Fatalf("refusal names %q, want %q: %+v", got.Re, mnet.MsgUse, got)
	}
	rejected := h.awaitEvents(game.EvUseRejected, 1)
	if r := rejected[0]["reason"]; r != string(mnet.ReasonNoRecipe) {
		t.Errorf("%s reason %v, want %q", game.EvUseRejected, r, mnet.ReasonNoRecipe)
	}

	alice.destroy()
	resumed := readJoinStep(h.dialResume("alice-again", world.Session))
	if len(resumed.inventory.Slots) != 1 || resumed.inventory.Slots[0].Kind != game.KindAcorn {
		t.Fatalf("bag %+v after refuse, want the acorn untouched", resumed.inventory.Slots)
	}
	if crafted := h.eventsNamed(game.EvUse); len(crafted) != 0 {
		t.Fatalf("logged %s on a refuse: %+v", game.EvUse, crafted)
	}
}

func TestUseIntoAFullBagIsRefusedAndLogsStay(t *testing.T) {
	kit := make([]string, 0, game.InventorySize)
	kit = append(kit, game.KindLogs)
	for len(kit) < game.InventorySize {
		kit = append(kit, game.KindAcorn)
	}
	h := newHarnessWithKit(t, kit)

	alice := h.dial("alice")
	world := alice.welcomeFrame()
	full := alice.inventory()
	alice.equipment()
	if len(full.Slots) != game.InventorySize {
		t.Fatalf("bag holds %d of %d slots before use, want it full", len(full.Slots), game.InventorySize)
	}

	alice.use(0, 0)

	got := alice.awaitError()
	if got.Re != mnet.MsgUse {
		t.Fatalf("refusal names %q, want %q", got.Re, mnet.MsgUse)
	}
	if !strings.Contains(got.Msg, "full") {
		t.Errorf("refusal reads %q, want it to say full", got.Msg)
	}
	rejected := h.awaitEvents(game.EvUseRejected, 1)
	if r := rejected[0]["reason"]; r != string(mnet.ReasonInventoryFull) {
		t.Errorf("%s reason %v, want %q", game.EvUseRejected, r, mnet.ReasonInventoryFull)
	}
	for _, f := range alice.collect(silenceWindow) {
		t.Errorf("a refused use sent alice a %s frame: %s", f.kind(), f.raw)
	}

	alice.destroy()
	again := readJoinStep(h.dialResume("alice-again", world.Session))
	if len(again.inventory.Slots) != game.InventorySize {
		t.Fatalf("bag holds %d after refuse, want full %d", len(again.inventory.Slots), game.InventorySize)
	}
	if again.inventory.Slots[0].Kind != game.KindLogs {
		t.Fatalf("slot 0 is %q after refuse, want logs", again.inventory.Slots[0].Kind)
	}
}

func TestUseSelfUseRuleRejectsDifferingOn(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindLogs, game.KindAcorn})

	alice := h.dial("alice")
	world := alice.welcome()

	alice.use(0, 1)

	got := alice.awaitError()
	if got.Re != mnet.MsgUse {
		t.Fatalf("refusal names %q, want %q", got.Re, mnet.MsgUse)
	}
	rejected := h.awaitEvents(game.EvUseRejected, 1)
	if r := rejected[0]["reason"]; r != string(mnet.ReasonNoRecipe) {
		t.Errorf("%s reason %v, want %q", game.EvUseRejected, r, mnet.ReasonNoRecipe)
	}

	alice.destroy()
	again := readJoinStep(h.dialResume("alice-again", world.Session))
	if len(again.inventory.Slots) != 2 {
		t.Fatalf("bag %+v after refuse, want logs and acorn", again.inventory.Slots)
	}
	kinds := map[string]bool{}
	for _, s := range again.inventory.Slots {
		kinds[s.Kind] = true
	}
	if !kinds[game.KindLogs] || !kinds[game.KindAcorn] {
		t.Fatalf("bag %+v lost a kind on refuse", again.inventory.Slots)
	}
}

func TestDuplicateUseSeqDoesNotCraftTwice(t *testing.T) {
	h := newHarnessWithKit(t, []string{game.KindLogs})

	alice := h.dial("alice")
	alice.welcome()

	alice.sendRaw(`{"use":{"slot":0,"on":0,"seq":1}}`)
	inv := alice.awaitInventory()
	if len(inv.Slots) != 1 || inv.Slots[0].Kind != game.KindSticks {
		t.Fatalf("first use left %+v, want sticks", inv.Slots)
	}
	h.awaitEvents(game.EvUse, 1)

	alice.sendRaw(`{"use":{"slot":0,"on":0,"seq":1}}`)
	h.awaitEvents(game.EvIntentDuplicate, 1)
	alice.expectSilence()
	if crafted := h.eventsNamed(game.EvUse); len(crafted) != 1 {
		t.Fatalf("%d %s events, want 1: duplicate must not craft", len(crafted), game.EvUse)
	}
}

func TestDecodeUse(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name     string
		frame    string
		wantSlot int
		wantOn   int
	}{
		{"self-use", `{"use":{"slot":3,"on":3}}`, 3, 3},
		{"zero slots", `{"use":{"slot":0,"on":0}}`, 0, 0},
		{"with seq", `{"use":{"slot":2,"on":2,"seq":4}}`, 2, 2},
		{"extra field", `{"use":{"slot":1,"on":1,"whatever":true}}`, 1, 1},
		{"mismatched on is still a valid frame", `{"use":{"slot":1,"on":2}}`, 1, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			msg, _, err := mnet.Decode([]byte(tc.frame))
			if err != nil {
				t.Fatalf("Decode(%s): %v", tc.frame, err)
			}
			got, ok := msg.(mnet.Use)
			if !ok {
				t.Fatalf("Decode(%s) returned %T", tc.frame, msg)
			}
			if got.Slot != tc.wantSlot || got.On != tc.wantOn {
				t.Fatalf("Decode(%s) = %+v, want slot=%d on=%d", tc.frame, got, tc.wantSlot, tc.wantOn)
			}
		})
	}
}

func TestDecodeUseRejections(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		frame  string
		reason mnet.RejectReason
	}{
		{"no fields", `{"use":{}}`, mnet.ReasonMissingField},
		{"no on", `{"use":{"slot":1}}`, mnet.ReasonMissingField},
		{"no slot", `{"use":{"on":1}}`, mnet.ReasonMissingField},
		{"null payload", `{"use":null}`, mnet.ReasonMissingField},
		{"string slot", `{"use":{"slot":"logs","on":1}}`, mnet.ReasonMalformedJSON},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, _, err := mnet.Decode([]byte(tc.frame))
			if err == nil {
				t.Fatalf("Decode(%s) accepted, want %q", tc.frame, tc.reason)
			}
			rejection, ok := mnet.Rejection(err)
			if !ok {
				t.Fatalf("Decode(%s) returned %v, not a rejection", tc.frame, err)
			}
			if rejection.Reason != tc.reason {
				t.Fatalf("reason %q, want %q", rejection.Reason, tc.reason)
			}
			if rejection.Re != mnet.MsgUse {
				t.Fatalf("re %q, want %q", rejection.Re, mnet.MsgUse)
			}
		})
	}
}
