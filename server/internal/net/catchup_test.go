package net_test

import (
	"bytes"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
)

func TestCatchUpBoundHoldsUnderAStalledLoop(t *testing.T) {
	const (
		stall    = 8 * game.TickDuration
		leastDue = 6
		stallOn  = `"ev":"` + game.EvMove + `"`
	)

	h := newHarness(t)

	stalling := make(chan struct{})
	var once sync.Once
	h.logs.onWrite(func(line []byte) {
		if !bytes.Contains(line, []byte(stallOn)) {
			return
		}
		once.Do(func() {
			close(stalling)
			time.Sleep(stall)
		})
	})

	alice := h.dial("alice")
	alice.welcome()

	alice.move(1, 1)

	select {
	case <-stalling:
	case <-time.After(readTimeout):
		t.Fatalf("the log hook never fired, so the tick loop was never stalled\nlog:\n%s", h.logs.String())
	}

	drop := h.awaitEvents(game.EvTicksDropped, 1)[0]
	due := logNumber(t, drop, "due")
	ran := logNumber(t, drop, "ran")
	dropped := logNumber(t, drop, "dropped")

	if ran != game.MaxCatchUpTicks {
		t.Errorf("the loop ran %v catch-up ticks, want the bound of %d", ran, game.MaxCatchUpTicks)
	}
	if due <= game.MaxCatchUpTicks {
		t.Errorf("the backlog was %v ticks, which is not over the bound of %d, so this event should not exist", due, game.MaxCatchUpTicks)
	}
	if due < leastDue {
		t.Errorf("a stall of %v produced a backlog of only %v ticks, want at least %d; the loop was not held for as long as this test believes", stall, due, leastDue)
	}
	if dropped != due-ran {
		t.Errorf("the loop reports due=%v ran=%v dropped=%v, which do not add up", due, ran, dropped)
	}

	alice.move(0, 0)
	halt := alice.awaitPose()
	alice.noteSelfPose(halt)
	alice.drain()
	alice.walkTo(9, 9)
	if math.Hypot(alice.x-9, alice.z-9) > tickStep*1.5 {
		t.Fatalf("after the stall alice ended at (%v,%v), want near [9 9]", alice.x, alice.z)
	}
}

func logNumber(t *testing.T, obj map[string]any, key string) float64 {
	t.Helper()

	v, ok := obj[key]
	if !ok {
		t.Fatalf("log line has no %q field: %+v", key, obj)
	}
	n, ok := v.(float64)
	if !ok {
		t.Fatalf("log field %q is %T (%v), want a number", key, v, v)
	}
	return n
}
