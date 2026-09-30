package transport

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math/rand/v2"
	"testing"

	"github.com/devarminas/marque/server/internal/netsim"
)

const (
	testHash uint64 = 0x0123456789abcdef
	tick     uint64 = 40_000
)

type side struct {
	ep        *Endpoint
	dir       netsim.Direction
	reliable  [][]byte
	stamps    []uint32
	datagrams int
	reading   bool
}

type session struct {
	t        *testing.T
	sim      *netsim.Simulator
	srv, cli *side
	now      uint64
}

func newSession(t *testing.T, profile string, seed uint64, cfg Config) *session {
	t.Helper()
	seed = netsim.SeedFromEnv(seed)
	t.Logf("seed=%d profile=%s", seed, profile)
	srv, err := NewEndpoint(Server, cfg, 0)
	if err != nil {
		t.Fatal(err)
	}
	cli, err := NewEndpoint(Client, cfg, 0)
	if err != nil {
		t.Fatal(err)
	}
	return &session{
		t:   t,
		sim: netsim.New(netsim.Profiles[profile], seed),
		srv: &side{ep: srv, dir: netsim.AToB, reading: true},
		cli: &side{ep: cli, dir: netsim.BToA, reading: true},
	}
}

func (s *session) peer(x *side) *side {
	if x == s.srv {
		return s.cli
	}
	return s.srv
}

func (s *session) step(srvU, cliU Unreliable) {
	s.now += tick
	for _, x := range []*side{s.srv, s.cli} {
		for _, d := range s.sim.Poll(s.peer(x).dir, s.now) {
			if !x.reading {
				continue
			}
			r, err := x.ep.Receive(d.Packet, s.now)
			if err != nil {
				continue
			}
			x.reliable = append(x.reliable, r.Reliable...)
			if r.Unreliable.Items != nil {
				x.stamps = append(x.stamps, r.Unreliable.Stamp)
			}
		}
	}
	for _, f := range []struct {
		x *side
		u Unreliable
	}{{s.srv, srvU}, {s.cli, cliU}} {
		x := f.x
		for _, d := range must(x.ep.Flush(s.now, f.u)).Datagrams {
			x.datagrams++
			s.sim.Send(x.dir, d, s.now)
		}
	}
}

func message(r *rand.Rand, i int) []byte {
	n := 4 + r.IntN(200)
	if r.IntN(10) == 0 {
		n = FragmentSize + 1 + r.IntN(4*FragmentSize)
	}
	b := make([]byte, n)
	binary.LittleEndian.PutUint32(b, uint32(i))
	for j := 4; j < n; j++ {
		b[j] = byte(r.Uint32())
	}
	return b
}

func TestReliableExactlyOnceInOrder(t *testing.T) {
	for _, tc := range []struct {
		profile              string
		ticks, fragmented    int
		srvDgrams, cliDgrams int
	}{
		{"lossy_5pct", 1501, 591, 2307, 2237},
		{"bad_wifi", 1507, 591, 3498, 3394},
	} {
		t.Run(tc.profile, func(t *testing.T) {
			s := newSession(t, tc.profile, 352, DefaultConfig(testHash))
			r := rand.New(rand.NewPCG(352, 1))
			const perSide = 3000
			var wantEvents, wantIntents [][]byte
			fragmented := 0
			for i := 0; i < perSide; i++ {
				e, in := message(r, i), message(r, i)
				for _, m := range [][]byte{e, in} {
					if len(m) > FragmentSize {
						fragmented++
					}
				}
				wantEvents = append(wantEvents, e)
				wantIntents = append(wantIntents, in)
			}
			ticks := 0
			for len(s.cli.reliable) < perSide || len(s.srv.reliable) < perSide {
				if ticks >= 5000 {
					t.Fatalf("stalled: client has %d events, server has %d intents", len(s.cli.reliable), len(s.srv.reliable))
				}
				for k := 0; k < 2 && ticks*2+k < perSide; k++ {
					if err := s.srv.ep.Send(wantEvents[ticks*2+k]); err != nil {
						t.Fatal(err)
					}
					if err := s.cli.ep.Send(wantIntents[ticks*2+k]); err != nil {
						t.Fatal(err)
					}
				}
				s.step(Unreliable{}, Unreliable{})
				ticks++
			}
			assertMessages(t, "events", s.cli.reliable, wantEvents)
			assertMessages(t, "intents", s.srv.reliable, wantIntents)
			got := fmt.Sprintf("ticks=%d fragmented=%d srv_datagrams=%d cli_datagrams=%d", ticks, fragmented, s.srv.datagrams, s.cli.datagrams)
			want := fmt.Sprintf("ticks=%d fragmented=%d srv_datagrams=%d cli_datagrams=%d", tc.ticks, tc.fragmented, tc.srvDgrams, tc.cliDgrams)
			if got != want {
				t.Fatalf("got %s, want %s", got, want)
			}
		})
	}
}

func assertMessages(t *testing.T, name string, got, want [][]byte) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: got %d messages, want %d", name, len(got), len(want))
	}
	for i := range want {
		if !bytes.Equal(got[i], want[i]) {
			t.Fatalf("%s: message %d differs (got index %d, len %d; want len %d)", name, i, binary.LittleEndian.Uint32(got[i]), len(got[i]), len(want[i]))
		}
	}
}

func stateItems(n uint32) Unreliable {
	return Unreliable{Stamp: n, Items: [][]byte{{byte(n), 1}, {byte(n), 2, 3}}}
}

func TestStaleUnreliableDropped(t *testing.T) {
	for _, tc := range []struct {
		profile                            string
		cliGot, cliStale, srvGot, srvStale int
	}{
		{"lossy_5pct", 1904, 0, 1912, 0},
		{"bad_wifi", 1607, 93, 1611, 119},
	} {
		t.Run(tc.profile, func(t *testing.T) {
			s := newSession(t, tc.profile, 352, DefaultConfig(testHash))
			for n := uint32(1); n <= 2000; n++ {
				s.step(stateItems(n), stateItems(n))
			}
			for _, x := range []*side{s.cli, s.srv} {
				for i := 1; i < len(x.stamps); i++ {
					if x.stamps[i] <= x.stamps[i-1] {
						t.Fatalf("stamp %d delivered after %d", x.stamps[i], x.stamps[i-1])
					}
				}
			}
			got := fmt.Sprintf("cli got=%d stale=%d srv got=%d stale=%d", len(s.cli.stamps), s.cli.ep.Stats().Stale, len(s.srv.stamps), s.srv.ep.Stats().Stale)
			want := fmt.Sprintf("cli got=%d stale=%d srv got=%d stale=%d", tc.cliGot, tc.cliStale, tc.srvGot, tc.srvStale)
			if got != want {
				t.Fatalf("got %s, want %s", got, want)
			}
		})
	}
}

func TestStoppedReaderTriggersSlowClient(t *testing.T) {
	for _, tc := range []struct {
		profile string
		tick    int
		sent    int
	}{
		{"lossy_5pct", 184, 2201},
		{"bad_wifi", 179, 2141},
	} {
		t.Run(tc.profile, func(t *testing.T) {
			s := newSession(t, tc.profile, 352, DefaultConfig(testHash))
			sent := 0
			for n := 1; n <= 2000; n++ {
				if n == 100 {
					s.cli.reading = false
				}
				for k := 0; k < 12; k++ {
					if s.srv.ep.Send(binary.LittleEndian.AppendUint32(make([]byte, 0, 32), uint32(sent))) == nil {
						sent++
					}
				}
				s.step(Unreliable{}, Unreliable{})
				if s.srv.ep.State() == SlowClient {
					got := fmt.Sprintf("tick=%d backlog=%d sent=%d", n, s.srv.ep.Backlog(), sent)
					want := fmt.Sprintf("tick=%d backlog=0 sent=%d", tc.tick, tc.sent)
					if got != want {
						t.Fatalf("got %s, want %s", got, want)
					}
					return
				}
			}
			t.Fatal("no slow_client")
		})
	}
}

func TestSilenceKeepalivesThenTimeout(t *testing.T) {
	for _, tc := range []struct {
		profile   string
		timeoutAt uint64
	}{
		{"lossy_5pct", 6_000_000},
		{"bad_wifi", 6_080_000},
	} {
		t.Run(tc.profile, func(t *testing.T) {
			s := newSession(t, tc.profile, 352, DefaultConfig(testHash))
			var sizes []int
			for n := 0; n < 25; n++ {
				s.step(Unreliable{}, Unreliable{})
			}
			sizes = append(sizes, s.srv.datagrams, s.cli.datagrams)
			if got, want := fmt.Sprint(sizes), "[8 8]"; got != want {
				t.Fatalf("keepalives in 1 s (server, client): got %s, want %s", got, want)
			}

			for s.now < 10_000_000 {
				s.now += tick
				for _, d := range s.sim.Poll(s.cli.dir, s.now) {
					s.srv.ep.Receive(d.Packet, s.now)
				}
				if f := must(s.srv.ep.Flush(s.now, Unreliable{})); f.State == TimedOut {
					if s.now != tc.timeoutAt {
						t.Fatalf("timed out at %d, want %d", s.now, tc.timeoutAt)
					}
					return
				}
			}
			t.Fatal("no timeout")
		})
	}
}
