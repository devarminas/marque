// Package gamelog writes the server's NDJSON event log.
//
// One JSON object per line, each line prefixed with "GAMELOG " so that library
// and runtime noise on the same stream can be filtered out with a single grep:
//
//	GAMELOG {"t":142,"ev":"path_assigned","player":1,"speed":3}
//
// Every object carries "t", the tick number. Wall-clock never appears in the
// log, because a replayed run must diff cleanly against the recorded one and
// wall-clock makes every run differ (NOTES.md, "Determinism").
//
// The schema is deliberately flat: "t", "ev", and then whatever fields that
// event carries. M1's inventory mutations are new "ev" values with new fields,
// not a new envelope.
package gamelog

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"strconv"
	"sync"
)

// Prefix tags every log line. Callers grep for it at line start.
const Prefix = "GAMELOG "

// Fields carries the event-specific payload. Keys "t" and "ev" are reserved and
// are rejected with a panic, because silently shadowing them would corrupt the
// log for every downstream reader.
type Fields map[string]any

// Logger serializes event lines to a writer.
//
// Safe for concurrent use, though in this server essentially all events come
// from the single goroutine that owns world state. The mutex exists so that
// boot and shutdown lines from main cannot interleave with it.
//
// A disabled Logger is a no-op that still validates nothing and costs one
// atomic-free branch per call.
type Logger struct {
	mu      sync.Mutex
	w       io.Writer
	enabled bool
}

// New returns a Logger writing to w. When enabled is false every Event call is
// a no-op and w is never touched.
func New(w io.Writer, enabled bool) *Logger {
	if w == nil {
		panic("gamelog: nil writer")
	}
	return &Logger{w: w, enabled: enabled}
}

// Event writes one line: the prefix, then a JSON object of "t", "ev", and f.
//
// t is a tick number, never a timestamp. ev names the event.
//
// Encoding failures panic. A value that cannot be marshaled is a programming
// error, and a log that silently drops lines is worse than a crash: it is the
// evidence trail for every later milestone. Non-finite floats are the one
// expected hazard and are converted to their string form ("NaN", "+Inf") rather
// than failing, because rejected client coordinates are exactly the values the
// log most needs to record.
func (l *Logger) Event(t int64, ev string, f Fields) {
	if l == nil || !l.enabled {
		return
	}
	if ev == "" {
		panic("gamelog: empty event name")
	}

	obj := make(map[string]any, len(f)+2)
	obj["t"] = t
	obj["ev"] = ev
	for k, v := range f {
		if k == "t" || k == "ev" {
			panic(fmt.Sprintf("gamelog: field %q is reserved (event %q)", k, ev))
		}
		obj[k] = jsonSafe(v)
	}

	line, err := json.Marshal(obj)
	if err != nil {
		panic(fmt.Sprintf("gamelog: marshal event %q: %v", ev, err))
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if _, err := fmt.Fprintf(l.w, "%s%s\n", Prefix, line); err != nil {
		panic(fmt.Sprintf("gamelog: write event %q: %v", ev, err))
	}
}

// jsonSafe replaces values encoding/json refuses with values it accepts.
//
// Only non-finite float64 needs this today. NaN and +/-Inf have no JSON literal
// form, so they are emitted as strings; a reader that sees a string where it
// expected a number is reading a rejected value, which is the only way one gets
// into the log.
func jsonSafe(v any) any {
	switch x := v.(type) {
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return strconv.FormatFloat(x, 'g', -1, 64)
		}
		return x
	case []float64:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = jsonSafe(e)
		}
		return out
	default:
		return v
	}
}
