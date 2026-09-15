package net_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/wsprobe"
)

// TestWsprobeAdminAndMoveToRefuse drives the thin in-repo WS helper against a
// live in-process marqued hub: admin command path plus retired move_to refuse.
func TestWsprobeAdminAndMoveToRefuse(t *testing.T) {
	h := newHarnessWithSetup(t, nil, func(w *game.World) {
		w.SetAdminACL(game.AdminACL{DevAdmin: true})
		w.SetAdminRegistry(game.NewDefaultAdminRegistry())
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	c, err := wsprobe.Dial(ctx, h.wsURL())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = c.CloseNow() })

	if err := c.DrainJoin(ctx); err != nil {
		t.Fatalf("drain join: %v", err)
	}

	if err := c.SendAdmin(ctx, "/heal", 1); err != nil {
		t.Fatalf("send admin: %v", err)
	}
	reply, err := c.AwaitAdminReply(ctx)
	if err != nil {
		t.Fatalf("admin reply: %v", err)
	}
	if !strings.HasPrefix(reply, "ok: ") {
		t.Fatalf("admin_reply=%q, want ok: prefix", reply)
	}
	adminEv := h.awaitEvents(game.EvAdmin, 1)
	if adminEv[0]["cmd"] != "heal" || adminEv[0]["result"] != "ok" {
		t.Fatalf("GAMELOG admin=%v, want heal/ok", adminEv[0])
	}

	if err := c.SendRaw(ctx, `{"move_to":{"x":3,"z":4,"seq":2}}`); err != nil {
		t.Fatalf("send move_to: %v", err)
	}
	got, err := c.AwaitError(ctx)
	if err != nil {
		t.Fatalf("await error: %v", err)
	}
	if got.Re != "move_to" {
		t.Fatalf("error.re=%q, want move_to", got.Re)
	}
	if !strings.Contains(got.Msg, "illegal_sample") {
		t.Fatalf("error.msg=%q, want illegal_sample", got.Msg)
	}
	rejected := h.awaitEvents(game.EvMoveToRejected, 1)
	if rejected[0]["reason"] != "illegal_sample" {
		t.Fatalf("GAMELOG move_to_rejected=%v, want reason=illegal_sample", rejected[0])
	}
}
