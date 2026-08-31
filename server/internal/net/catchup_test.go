package net_test

import (
	"bytes"
	"sync"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// TestCatchUpBoundHoldsUnderAStalledLoop drives the catch-up bound through the
// real loop, on the real server, against real wall-clock time.
//
// Nothing here asks the loop to fall behind, because nothing can: it is driven
// by a ticker and a monotonic clock, and no test-visible knob moves either. So
// the loop is stalled instead, by blocking the one thing it does that a test
// can get in front of -- writing a line to the event log. While that write is
// blocked the world goroutine is off its ticker, wall-clock runs on, and the
// backlog it finds when it comes back is a genuine overrun rather than a number
// handed to it.
//
// How large that backlog is belongs to the scheduler, so the assertions are on
// the arithmetic the bound guarantees whatever its size: the loop ran the bound
// and no more, and the number it says it dropped is the number it did drop.
// TestCatchUpStopsAtTheBound in internal/game pins the exact figures.
func TestCatchUpBoundHoldsUnderAStalledLoop(t *testing.T) {
	const (
		// Comfortably past the bound, so scheduler jitter cannot bring the
		// backlog back under it, and still short enough not to dominate the
		// suite.
		stall = 8 * game.TickDuration
		// stall/TickDuration, less two ticks of slack for the tick the ticker
		// had already buffered and for where the stall lands inside a period.
		leastDue = 6
		// The line the stall waits for. The closing quote matters: without it
		// this also matches move_to_rejected.
		stallOn = `"ev":"` + game.EvMoveTo + `"`
	)

	h := newHarness(t)

	stalling := make(chan struct{})
	var once sync.Once
	h.logs.onWrite(func(line []byte) {
		if !bytes.Contains(line, []byte(stallOn)) {
			return
		}
		// Only the first move_to stalls. The hook runs on the world goroutine,
		// which is exactly the goroutine this needs to hold still.
		once.Do(func() {
			close(stalling)
			time.Sleep(stall)
		})
	})

	alice := h.dial("alice")
	me := alice.welcome().You

	// A click the server accepts, so the loop is inside handle when it stalls
	// rather than somewhere incidental.
	alice.moveTo(4, 4)

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

	// The server is still a server afterwards. The backlog was discarded rather
	// than carried, so the next click is answered like any other.
	alice.drain()
	alice.moveTo(9, 9)
	points := alice.awaitPath(me).Points
	if got := points[len(points)-1]; got != mnet.Pt(9, 9) {
		t.Fatalf("after the stall a click ended at %v, want [9 9]", got)
	}
}

// logNumber reads one numeric field out of a parsed log line. Every JSON number
// decodes into a float64, so an int field has to be read back as one.
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
