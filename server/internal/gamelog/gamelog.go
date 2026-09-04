// Package gamelog writes the server's NDJSON event log, one object per line:
//
//	GAMELOG {"t":142,"ev":"path_assigned","player":1,"speed":3}
//
// "t" is the tick number, never wall-clock; "ev" names the event.
package gamelog

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"strconv"
	"sync"
)

// Prefix tags every log line.
const Prefix = "GAMELOG "

// Fields carries the event-specific payload. Keys "t" and "ev" are reserved
// and rejected with a panic.
type Fields map[string]any

// Logger serializes event lines to a writer. Safe for concurrent use.
type Logger struct {
	mu      sync.Mutex
	w       io.Writer
	enabled bool
}

// New returns a Logger writing to w. When enabled is false every Event call is
// a no-op.
func New(w io.Writer, enabled bool) *Logger {
	if w == nil {
		panic("gamelog: nil writer")
	}
	return &Logger{w: w, enabled: enabled}
}

// Event writes one line: the prefix, then a JSON object of "t", "ev", and f.
// Encoding failures panic; non-finite floats are written as strings.
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

// jsonSafe stringifies non-finite float64s: JSON has no NaN or Inf literal, so
// encoding/json refuses them.
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
