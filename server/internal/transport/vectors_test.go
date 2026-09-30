package transport

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite shared/wire/vectors/transport from the scenarios")

const vectorDir = "../../../shared/wire/vectors/transport"

// script drives one endpoint and records each op followed by its outputs, in
// the vector format of shared/wire/transport.md.
type script struct {
	ep    *Endpoint
	lines []string
}

type start struct{ seq, sendID, recvID uint16 }

func newScript(desc string, role Role, cfg Config, now uint64) *script {
	return newScriptAt(desc, role, cfg, start{}, now)
}

func newScriptAt(desc string, role Role, cfg Config, st start, now uint64) *script {
	s := &script{}
	for _, l := range strings.Split(desc, "\n") {
		s.lines = append(s.lines, "# "+l)
	}
	seal := "plain"
	if _, ok := cfg.Seal.(testSeal); ok {
		seal = "test"
	}
	s.exec(fmt.Sprintf("endpoint %s %016x %d %d %d %d %s %d %d %d %d", role, cfg.SchemaHash, cfg.TickBudget, cfg.BacklogLimit, cfg.BacklogBytes, cfg.ResendAfter, seal, st.seq, st.sendID, st.recvID, now))
	return s
}

func (s *script) exec(line string) []string {
	out, err := runOp(&s.ep, line)
	if err != nil {
		panic(err)
	}
	s.lines = append(s.lines, line)
	for _, o := range out {
		s.lines = append(s.lines, "> "+o)
	}
	return out
}

func (s *script) send(msg []byte) { s.exec("send " + hex.EncodeToString(msg)) }

func (s *script) flush(now uint64, u Unreliable) [][]byte {
	line := fmt.Sprintf("flush %d", now)
	if len(u.Items) > 0 {
		line += fmt.Sprintf(" %d", u.Stamp)
		for _, it := range u.Items {
			line += " " + hex.EncodeToString(it)
		}
	}
	var ds [][]byte
	for _, o := range s.exec(line) {
		if h, ok := strings.CutPrefix(o, "datagram "); ok {
			d, _ := hex.DecodeString(h)
			ds = append(ds, d)
		}
	}
	return ds
}

func (s *script) recv(now uint64, d []byte) {
	s.exec(fmt.Sprintf("recv %d %s", now, hex.EncodeToString(d)))
}

func (s *script) text() string { return strings.Join(s.lines, "\n") + "\n" }

var errNames = []struct {
	err  error
	name string
}{
	{ErrMalformed, "malformed"},
	{ErrForeign, "foreign"},
	{ErrDuplicate, "duplicate"},
	{ErrTooOld, "too_old"},
	{ErrClosed, "closed"},
	{ErrMessage, "message"},
	{ErrItem, "item"},
}

func errName(err error) string {
	for _, e := range errNames {
		if errors.Is(err, e.err) {
			return e.name
		}
	}
	return err.Error()
}

// runOp executes one vector op line and returns its output lines. This is
// the whole vector interpreter; the C++ runner mirrors it.
func runOp(ep **Endpoint, line string) ([]string, error) {
	f := strings.Fields(line)
	num := func(i int) uint64 {
		v, err := strconv.ParseUint(f[i], 10, 64)
		if err != nil {
			panic(fmt.Sprintf("%q: %v", line, err))
		}
		return v
	}
	unhex := func(s string) []byte {
		b, err := hex.DecodeString(s)
		if err != nil {
			panic(fmt.Sprintf("%q: %v", line, err))
		}
		return b
	}
	var out []string
	switch f[0] {
	case "endpoint":
		role := Server
		if f[1] == "client" {
			role = Client
		}
		hash, err := strconv.ParseUint(f[2], 16, 64)
		if err != nil {
			return nil, err
		}
		cfg := DefaultConfig(hash)
		cfg.TickBudget, cfg.BacklogLimit, cfg.BacklogBytes, cfg.ResendAfter = int(num(3)), int(num(4)), int(num(5)), num(6)
		switch f[7] {
		case "plain":
		case "test":
			cfg.Seal = testSeal{}
		default:
			return nil, fmt.Errorf("unknown seal %q", f[7])
		}
		e, err := NewEndpoint(role, cfg, num(11))
		if err != nil {
			return nil, err
		}
		e.tx.nextSeq, e.tx.front, e.rx.next = uint16(num(8)), num(9), uint16(num(10))
		*ep = e
	case "send":
		if err := (*ep).Send(unhex(f[1])); err != nil {
			out = append(out, "error "+errName(err))
		}
	case "flush":
		var u Unreliable
		if len(f) > 2 {
			u.Stamp = uint32(num(2))
			for _, h := range f[3:] {
				u.Items = append(u.Items, unhex(h))
			}
		}
		r, err := (*ep).Flush(num(1), u)
		if err != nil {
			out = append(out, "error "+errName(err))
			break
		}
		for _, d := range r.Datagrams {
			out = append(out, "datagram "+hex.EncodeToString(d))
		}
		if len(u.Items) > 0 {
			out = append(out, fmt.Sprintf("unreliable_sent %d", r.UnreliableSent))
		}
		if r.State != Open {
			out = append(out, "state "+r.State.String())
		}
	case "recv":
		r, err := (*ep).Receive(unhex(f[2]), num(1))
		if err != nil {
			out = append(out, "error "+errName(err))
			break
		}
		if r.Stale {
			out = append(out, "stale")
		}
		if r.Unreliable.Items != nil {
			l := fmt.Sprintf("unreliable %d", r.Unreliable.Stamp)
			for _, it := range r.Unreliable.Items {
				l += " " + hex.EncodeToString(it)
			}
			out = append(out, l)
		}
		for _, m := range r.Reliable {
			out = append(out, "reliable "+hex.EncodeToString(m))
		}
	default:
		return nil, fmt.Errorf("unknown op %q", f[0])
	}
	return out, nil
}

func replay(text string) error {
	var ep *Endpoint
	var want []string
	var got []string
	check := func(at int) error {
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			return fmt.Errorf("before line %d:\ngot:\n%s\nwant:\n%s", at, strings.Join(got, "\n"), strings.Join(want, "\n"))
		}
		return nil
	}
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(nil, 1<<20)
	n := 0
	for sc.Scan() {
		n++
		line := sc.Text()
		switch {
		case line == "" || strings.HasPrefix(line, "#"):
		case strings.HasPrefix(line, "> "):
			want = append(want, line[2:])
		default:
			if err := check(n); err != nil {
				return err
			}
			out, err := runOp(&ep, line)
			if err != nil {
				return fmt.Errorf("line %d: %v", n, err)
			}
			got, want = out, nil
		}
	}
	return check(n + 1)
}

func TestVectors(t *testing.T) {
	scenarios := vectorScenarios()
	if *update {
		if err := os.MkdirAll(vectorDir, 0o755); err != nil {
			t.Fatal(err)
		}
		old, _ := filepath.Glob(filepath.Join(vectorDir, "*.vec"))
		for _, p := range old {
			os.Remove(p)
		}
		for name, text := range scenarios {
			if err := os.WriteFile(filepath.Join(vectorDir, name+".vec"), []byte(text), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	files, err := filepath.Glob(filepath.Join(vectorDir, "*.vec"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != len(scenarios) {
		t.Fatalf("%d vector files, %d scenarios; run go test ./internal/transport -run TestVectors -update", len(files), len(scenarios))
	}
	for _, p := range files {
		name := strings.TrimSuffix(filepath.Base(p), ".vec")
		t.Run(name, func(t *testing.T) {
			b, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(b, []byte(scenarios[name])) {
				t.Fatalf("%s is stale; run go test ./internal/transport -run TestVectors -update", p)
			}
			if err := replay(string(b)); err != nil {
				t.Fatal(err)
			}
		})
	}
}
