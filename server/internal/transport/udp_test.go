package transport

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"go/build"
	"net"
	"net/netip"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

func listen(t *testing.T) *net.UDPConn {
	t.Helper()
	c, err := net.ListenUDP("udp", net.UDPAddrFromAddrPort(netip.MustParseAddrPort("127.0.0.1:0")))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func next(t *testing.T, ch <-chan Inbound) Inbound {
	t.Helper()
	select {
	case in, ok := <-ch:
		if !ok {
			t.Fatal("reader closed its channel")
		}
		return in
	case <-time.After(5 * time.Second):
		t.Fatal("no Inbound within 5 s")
	}
	return Inbound{}
}

type shard struct {
	srv, cli         *net.UDPConn
	srvAddr, cliAddr netip.AddrPort
	gate             *Gate
	rd               *Reader
	inbound          chan Inbound
	done             chan error
}

func startShard(t *testing.T) *shard {
	t.Helper()
	s := &shard{srv: listen(t), cli: listen(t), inbound: make(chan Inbound, 1024), done: make(chan error, 1)}
	t.Cleanup(func() { s.cli.Close() })
	s.srvAddr = s.srv.LocalAddr().(*net.UDPAddr).AddrPort()
	s.cliAddr = s.cli.LocalAddr().(*net.UDPAddr).AddrPort()
	g, err := NewGate(GateConfig{SchemaHash: wire.SchemaHash, Shard: s.srvAddr, Issuer: testIssuer()})
	if err != nil {
		t.Fatal(err)
	}
	s.gate = g
	s.rd, err = NewReader(s.srv, DefaultConfig(wire.SchemaHash), g, MonotonicClock(), func() uint64 { return testNow })
	if err != nil {
		t.Fatal(err)
	}
	go func() { s.done <- s.rd.Run(s.inbound) }()
	return s
}

func (s *shard) token(account uint64) ConnectToken {
	var n TokenNonce
	binary.LittleEndian.PutUint64(n[:], account)
	g := testGrant(account)
	g.Shard = s.srvAddr
	return IssueToken(testIssuer(), n, g)
}

func (s *shard) send(t *testing.T, d []byte) {
	t.Helper()
	if _, err := s.cli.WriteToUDPAddrPort(d, s.srvAddr); err != nil {
		t.Fatal(err)
	}
}

func (s *shard) replies(t *testing.T, wait time.Duration) [][]byte {
	t.Helper()
	var out [][]byte
	buf := make([]byte, 2*MaxDatagram)
	for {
		s.cli.SetReadDeadline(time.Now().Add(wait))
		n, _, err := s.cli.ReadFromUDPAddrPort(buf)
		if err != nil {
			return out
		}
		out = append(out, bytes.Clone(buf[:n]))
	}
}

func (s *shard) connect(t *testing.T, tok ConnectToken) *Endpoint {
	t.Helper()
	s.send(t, tok.Request(wire.SchemaHash))
	c := s.replies(t, 200*time.Millisecond)
	if len(c) != 1 {
		t.Fatalf("got %d replies to a request, want 1 challenge", len(c))
	}
	s.send(t, must(tok.Respond(c[0])))
	in := next(t, s.inbound)
	want := Inbound{From: s.cliAddr, At: in.At, Admission: Admission{Peer: s.cliAddr, Account: 7, Session: 1007, Expires: testNow + 30, Keys: tok.Keys}}
	if !reflect.DeepEqual(in, want) {
		t.Fatalf("got %+v, want %+v", in, want)
	}
	return must(NewEndpoint(Client, DefaultConfig(wire.SchemaHash), NewSessionSeal(Client, tok.Keys), 0))
}

func (s *shard) stop(t *testing.T) []Inbound {
	t.Helper()
	time.Sleep(50 * time.Millisecond)
	s.srv.Close()
	if err := <-s.done; err != nil {
		t.Fatal(err)
	}
	var rest []Inbound
	for in := range s.inbound {
		rest = append(rest, in)
	}
	return rest
}

func (s *shard) flush(t *testing.T, ep *Endpoint, now uint64, u Unreliable) {
	t.Helper()
	for _, d := range must(ep.Flush(now, u)).Datagrams {
		s.send(t, d)
	}
}

func TestReaderAdmitsAHandshakeThenDecodesSealedInput(t *testing.T) {
	s := startShard(t)
	ep := s.connect(t, s.token(7))
	sample, err := wire.InputFields{Dx: 0.5, Dz: -1, Jump: true, Seq: 7}.Build()
	if err != nil {
		t.Fatal(err)
	}
	input, err := sample.Append(nil)
	if err != nil {
		t.Fatal(err)
	}
	s.flush(t, ep, tick, Unreliable{Stamp: 7, Items: [][]byte{input}})

	in := next(t, s.inbound)
	want := Inbound{From: s.cliAddr, At: in.At, PeerAck: NoAcks, InputStamp: 7, Input: []wire.InputMsg{sample}}
	if !reflect.DeepEqual(in, want) {
		t.Fatalf("got %+v, want %+v", in, want)
	}

	if err := ep.Send(input); err != nil {
		t.Fatal(err)
	}
	s.flush(t, ep, 2*tick, Unreliable{})
	if in := next(t, s.inbound); !errors.Is(in.Fault, codec.ErrUnknownMessage) {
		t.Fatalf("got fault %v, want ErrUnknownMessage", in.Fault)
	}
	s.flush(t, ep, 3*tick, Unreliable{Stamp: 8, Items: [][]byte{input}})
	if rest := s.stop(t); len(rest) != 0 {
		t.Fatalf("forgotten peer still delivered %+v", rest)
	}
	if len(s.rd.peers) != 0 || s.gate.Admissions() != 1 {
		t.Fatalf("reader holds %d peers and the gate %d admissions, want 0 and 1", len(s.rd.peers), s.gate.Admissions())
	}
}

func TestReaderDropsUnsealedDatagramsFromAnAdmittedPeer(t *testing.T) {
	s := startShard(t)
	s.connect(t, s.token(7))
	plain := must(NewEndpoint(Client, DefaultConfig(wire.SchemaHash), Plain{}, 0))
	s.flush(t, plain, KeepaliveAfter, Unreliable{})
	if rest := s.stop(t); len(rest) != 0 {
		t.Fatalf("unsealed datagram delivered %+v", rest)
	}
	if st := s.rd.peers[s.cliAddr].Stats(); st.Malformed != 1 || st.Accepted != 0 {
		t.Fatalf("receiver stats %+v, want one malformed and none accepted", st)
	}
}

func TestReaderHoldsNoStateForUnansweredRequests(t *testing.T) {
	s := startShard(t)
	const n = 500
	got := 0
	for i := range n {
		s.send(t, s.token(uint64(i)).Request(wire.SchemaHash))
		got += len(s.replies(t, 20*time.Millisecond))
	}
	if rest := s.stop(t); len(rest) != 0 {
		t.Fatalf("requests alone delivered %d Inbound values", len(rest))
	}
	if got != n || len(s.rd.peers) != 0 || s.gate.Admissions() != 0 {
		t.Fatalf("%d challenges, %d peers, %d admissions; want %d, 0, 0", got, len(s.rd.peers), s.gate.Admissions(), n)
	}
}

func TestShardRepliesNeverExceedTheirRequest(t *testing.T) {
	s := startShard(t)
	tok := s.token(7)
	expired := testGrant(8)
	expired.Shard, expired.Expires = s.srvAddr, testNow
	forged := tok.Request(wire.SchemaHash)
	forged[100] ^= 1

	s.send(t, tok.Request(wire.SchemaHash))
	challenge := s.replies(t, 200*time.Millisecond)[0]
	response := must(tok.Respond(challenge))

	var got []string
	for _, tc := range []struct {
		name string
		d    []byte
	}{
		{"request", tok.Request(wire.SchemaHash)},
		{"expired_request", IssueToken(testIssuer(), TokenNonce{8}, expired).Request(wire.SchemaHash)},
		{"forged_request", forged},
		{"wrong_shard_request", testTokenFor(tok, testShard).Request(wire.SchemaHash)},
		{"short_request", tok.Request(wire.SchemaHash)[:100]},
		{"response", response},
		{"replayed_response", response},
		{"replayed_request", tok.Request(wire.SchemaHash)},
		{"keepalive_sized", make([]byte, HeaderSize)},
	} {
		s.send(t, tc.d)
		var sizes []int
		for _, r := range s.replies(t, 100*time.Millisecond) {
			sizes = append(sizes, len(r))
			if len(r) > len(tc.d) {
				t.Errorf("%s: %d-byte reply to a %d-byte packet", tc.name, len(r), len(tc.d))
			}
		}
		got = append(got, fmt.Sprintf("%s %d -> %v", tc.name, len(tc.d), sizes))
	}
	want := []string{
		"request 512 -> [183]",
		"expired_request 512 -> []",
		"forged_request 512 -> []",
		"wrong_shard_request 512 -> []",
		"short_request 100 -> []",
		"response 199 -> []",
		"replayed_response 199 -> []",
		"replayed_request 512 -> []",
		"keepalive_sized 20 -> []",
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got\n%v\nwant\n%v", got, want)
	}
	s.stop(t)
}

func testTokenFor(tok ConnectToken, shard netip.AddrPort) ConnectToken {
	g := testGrant(9)
	g.Shard = shard
	return IssueToken(testIssuer(), TokenNonce{9}, g)
}

func TestReaderCannotReachGameState(t *testing.T) {
	const module = "github.com/devarminas/marque/server/"
	seen := map[string]bool{}
	var walk func(path, dir string)
	walk = func(path, dir string) {
		if seen[path] || !strings.HasPrefix(path, module) {
			return
		}
		seen[path] = true
		for _, banned := range []string{"internal/game", "internal/net"} {
			if strings.HasPrefix(path, module+banned) && !strings.HasPrefix(path, module+"internal/netsim") {
				t.Errorf("transport depends on %s", path)
			}
		}
		pkg, err := build.Import(path, dir, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, imp := range pkg.Imports {
			walk(imp, pkg.Dir)
		}
	}
	walk(module+"internal/transport", ".")

	run := reflect.TypeOf((*Reader).Run)
	want := reflect.TypeOf(func(*Reader, chan<- Inbound) error { return nil })
	if run != want {
		t.Fatalf("Reader.Run is %v, want %v", run, want)
	}

	opaque := map[reflect.Type]bool{
		reflect.TypeFor[netip.AddrPort]():  true,
		reflect.TypeFor[wire.InputMsg]():   true,
		reflect.TypeFor[wire.IntentsMsg](): true,
		reflect.TypeFor[error]():           true,
	}
	var check func(reflect.Type, string)
	check = func(ty reflect.Type, at string) {
		if opaque[ty] {
			return
		}
		switch ty.Kind() {
		case reflect.Struct:
			for i := 0; i < ty.NumField(); i++ {
				check(ty.Field(i).Type, at+"."+ty.Field(i).Name)
			}
		case reflect.Slice:
			check(ty.Elem(), at+"[]")
		case reflect.Pointer, reflect.Map, reflect.Chan, reflect.Func, reflect.UnsafePointer, reflect.Interface:
			t.Errorf("%s is a %v, which could share state across the boundary", at, ty.Kind())
		}
	}
	check(reflect.TypeFor[Inbound](), "Inbound")

	if m, err := wire.DecodeInput([]byte{0x01, 0x96, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00}); err != nil || reflect.TypeOf(m).Kind() != reflect.Struct {
		t.Fatalf("DecodeInput gave %T, %v; want a struct value", m, err)
	}
}

func TestReaderForgetsPeerTheTickLoopDropped(t *testing.T) {
	s := startShard(t)
	ep := s.connect(t, s.token(7))
	s.flush(t, ep, KeepaliveAfter, Unreliable{})
	if in := next(t, s.inbound); in.From != s.cliAddr || in.PeerAck != NoAcks {
		t.Fatalf("got %+v, want a keepalive from %v", in, s.cliAddr)
	}
	s.rd.Forget(s.cliAddr)
	s.flush(t, ep, 2*KeepaliveAfter, Unreliable{})
	if rest := s.stop(t); len(rest) != 0 {
		t.Fatalf("forgotten peer still delivered %+v", rest)
	}
	if len(s.rd.peers) != 0 {
		t.Fatalf("reader holds %d peers, want 0", len(s.rd.peers))
	}
}
