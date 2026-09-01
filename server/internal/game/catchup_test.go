package game

// In-package, unlike path_test.go, because the catch-up bound lives in stepAll:
// unexported, taking the accumulator by pointer, and reachable from game_test
// only by exporting something or injecting a clock. Go's internal test package
// buys the same access for nothing, so production code stays as it is.
//
// The companion test in internal/net drives the bound through the real loop and
// a real wall-clock stall. That one proves Run can reach the branch; this one
// pins the arithmetic, and does it without a timer.

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// idleTransport satisfies Transport without ever producing an event. These
// tests call stepAll directly and never call Run, so the channel is never read;
// NewWorld only insists it is not nil.
type idleTransport struct{}

func (idleTransport) Events() <-chan mnet.Event { return nil }

// newStepWorld returns a world nobody is connected to, plus the log it writes.
func newStepWorld(t *testing.T) (*World, *bytes.Buffer) {
	t.Helper()
	logs := &bytes.Buffer{}
	return NewWorld(idleTransport{}, gamelog.New(logs, true), NewMemoryStore()), logs
}

// TestCatchUpStopsAtTheBound is the arithmetic of PROTOCOL.md's "Clock": at
// most MaxCatchUpTicks run in one iteration, the remainder is discarded, and
// the discard is logged.
//
// The discard is the whole point. If the surplus stayed in owed it would be
// re-owed on the next iteration and the bound would only delay the spiral it
// exists to stop, so this asserts what owed holds afterwards and not only what
// the log says.
func TestCatchUpStopsAtTheBound(t *testing.T) {
	const (
		overdue   = MaxCatchUpTicks + 3
		remainder = TickDuration / 3 // a sub-tick tail, which survives
	)

	w, logs := newStepWorld(t)
	owed := overdue*TickDuration + remainder
	w.stepAll(&owed)

	if w.tick != MaxCatchUpTicks {
		t.Fatalf("ran %d ticks for a backlog of %d, want the bound of %d", w.tick, overdue, MaxCatchUpTicks)
	}
	if owed != remainder {
		t.Fatalf("owed is %v after the drop, want the sub-tick remainder %v; the dropped backlog must not be carried forward", owed, remainder)
	}

	drops := eventsNamed(t, logs, EvTicksDropped)
	if len(drops) != 1 {
		t.Fatalf("logged %d %s events, want 1: %+v", len(drops), EvTicksDropped, drops)
	}
	drop := drops[0]

	if got := number(t, drop, "due"); got != overdue {
		t.Errorf("%s reports due=%v, want %d", EvTicksDropped, got, overdue)
	}
	if got := number(t, drop, "ran"); got != MaxCatchUpTicks {
		t.Errorf("%s reports ran=%v, want %d", EvTicksDropped, got, MaxCatchUpTicks)
	}
	if got := number(t, drop, "dropped"); got != overdue-MaxCatchUpTicks {
		t.Errorf("%s reports dropped=%v, want %d", EvTicksDropped, got, overdue-MaxCatchUpTicks)
	}
	if got := number(t, drop, "t"); got != 0 {
		t.Errorf("%s logged at tick %v, want 0: the drop belongs to the tick the loop was still on", EvTicksDropped, got)
	}
}

// TestCatchUpRunsTheWholeBacklogUpToTheBound covers the other side of the
// comparison. A backlog exactly at the bound is not a drop, and nothing short
// of it is either, so the >-not->= in stepAll is pinned from both directions.
func TestCatchUpRunsTheWholeBacklogUpToTheBound(t *testing.T) {
	for _, due := range []int{0, 1, MaxCatchUpTicks - 1, MaxCatchUpTicks} {
		w, logs := newStepWorld(t)
		owed := time.Duration(due) * TickDuration
		w.stepAll(&owed)

		if int(w.tick) != due {
			t.Errorf("backlog of %d ran %d ticks, want all %d", due, w.tick, due)
		}
		if owed != 0 {
			t.Errorf("backlog of %d left %v owed, want 0", due, owed)
		}
		if drops := eventsNamed(t, logs, EvTicksDropped); len(drops) != 0 {
			t.Errorf("backlog of %d logged %d %s events, want none: %+v", due, len(drops), EvTicksDropped, drops)
		}
	}
}

// TestRepeatedOverrunsDoNotAccumulate is the spiral itself, run twice. Two
// stalls in a row each cost exactly the bound, because the first one left
// nothing behind for the second to inherit.
func TestRepeatedOverrunsDoNotAccumulate(t *testing.T) {
	const overdue = MaxCatchUpTicks * 4

	w, logs := newStepWorld(t)
	for range 2 {
		owed := overdue * TickDuration
		w.stepAll(&owed)
		if owed != 0 {
			t.Fatalf("owed is %v after a whole-tick backlog, want 0", owed)
		}
	}

	if w.tick != 2*MaxCatchUpTicks {
		t.Fatalf("two overruns ran %d ticks in total, want %d", w.tick, 2*MaxCatchUpTicks)
	}
	if drops := eventsNamed(t, logs, EvTicksDropped); len(drops) != 2 {
		t.Fatalf("logged %d %s events for two overruns, want 2: %+v", len(drops), EvTicksDropped, drops)
	}
}

// eventsNamed parses the NDJSON log and returns the objects for one event name.
func eventsNamed(t *testing.T, logs *bytes.Buffer, name string) []map[string]any {
	t.Helper()

	var matched []map[string]any
	for _, line := range strings.Split(logs.String(), "\n") {
		if line == "" {
			continue
		}
		if !strings.HasPrefix(line, gamelog.Prefix) {
			t.Fatalf("log line lacks the %q prefix: %s", gamelog.Prefix, line)
		}
		var obj map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, gamelog.Prefix)), &obj); err != nil {
			t.Fatalf("log line is not valid JSON: %s: %v", line, err)
		}
		if obj["ev"] == name {
			matched = append(matched, obj)
		}
	}
	return matched
}

// number reads one numeric field out of a parsed log line. Every JSON number
// decodes into a float64, so an int field has to be read back as one.
func number(t *testing.T, obj map[string]any, key string) float64 {
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
