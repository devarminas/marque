package gamelog_test

import (
	"bytes"
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/gamelog"
)

func TestEventWritesOnePrefixedJSONObjectPerLine(t *testing.T) {
	t.Parallel()

	var out bytes.Buffer
	log := gamelog.New(&out, true)
	log.Event(0, "server_started", gamelog.Fields{"tick_ms": 150})
	log.Event(7, "path_assigned", gamelog.Fields{"player": 1, "speed": 3.0})

	lines := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("wrote %d lines, want 2: %q", len(lines), out.String())
	}

	wantTicks := []float64{0, 7}
	for i, line := range lines {
		if !strings.HasPrefix(line, gamelog.Prefix) {
			t.Fatalf("line %d lacks the %q prefix: %s", i, gamelog.Prefix, line)
		}
		var obj map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, gamelog.Prefix)), &obj); err != nil {
			t.Fatalf("line %d is not valid JSON: %s: %v", i, line, err)
		}
		if obj["t"] != wantTicks[i] {
			t.Fatalf("line %d has t=%v, want %v", i, obj["t"], wantTicks[i])
		}
	}
}

// TestNonFiniteFieldsStillEncode covers the value that would otherwise take the
// log down with it. A rejected coordinate is exactly what the log most needs to
// record, and encoding/json refuses NaN and infinity outright.
func TestNonFiniteFieldsStillEncode(t *testing.T) {
	t.Parallel()

	var out bytes.Buffer
	log := gamelog.New(&out, true)
	log.Event(3, "move_to_rejected", gamelog.Fields{
		"x": math.NaN(),
		"z": math.Inf(1),
	})

	var obj map[string]any
	line := strings.TrimPrefix(strings.TrimSuffix(out.String(), "\n"), gamelog.Prefix)
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		t.Fatalf("line is not valid JSON: %s: %v", line, err)
	}
	if obj["x"] != "NaN" {
		t.Fatalf("x logged as %#v, want the string \"NaN\"", obj["x"])
	}
	if obj["z"] != "+Inf" {
		t.Fatalf("z logged as %#v, want the string \"+Inf\"", obj["z"])
	}
}

func TestDisabledLoggerWritesNothing(t *testing.T) {
	t.Parallel()

	var out bytes.Buffer
	gamelog.New(&out, false).Event(1, "client_connected", gamelog.Fields{"player": 1})

	if out.Len() != 0 {
		t.Fatalf("a disabled logger wrote %q", out.String())
	}
}

func TestReservedFieldNamesPanic(t *testing.T) {
	t.Parallel()

	for _, name := range []string{"t", "ev"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			defer func() {
				if recover() == nil {
					t.Fatalf("shadowing %q was allowed; it would corrupt the log for every reader", name)
				}
			}()
			gamelog.New(&bytes.Buffer{}, true).Event(1, "whatever", gamelog.Fields{name: "shadow"})
		})
	}
}
