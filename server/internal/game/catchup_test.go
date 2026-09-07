package game


import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

type idleTransport struct{}

func (idleTransport) Events() <-chan mnet.Event { return nil }

func newStepWorld(t *testing.T) (*World, *bytes.Buffer) {
	t.Helper()
	logs := &bytes.Buffer{}
	return NewWorld(idleTransport{}, gamelog.New(logs, true), NewMemoryStore(NoWearables), ResumeGraceTicks, nil), logs
}

func TestCatchUpStopsAtTheBound(t *testing.T) {
	const (
		overdue   = MaxCatchUpTicks + 3
		remainder = TickDuration / 3
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
