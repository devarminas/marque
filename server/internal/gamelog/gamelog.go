package gamelog

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"strconv"
	"sync"
)

const Prefix = "GAMELOG "

type Fields map[string]any

type Logger struct {
	mu      sync.Mutex
	w       io.Writer
	enabled bool
}

func New(w io.Writer, enabled bool) *Logger {
	if w == nil {
		panic("gamelog: nil writer")
	}
	return &Logger{w: w, enabled: enabled}
}

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
