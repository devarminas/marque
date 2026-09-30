package transport

import (
	"errors"
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

func TestReaderHandsDecodedInputOverChannel(t *testing.T) {
	srv, cli := listen(t), listen(t)
	defer cli.Close()
	cliAddr := cli.LocalAddr().(*net.UDPAddr).AddrPort()
	cfg := DefaultConfig(wire.SchemaHash)
	rd, err := NewReader(srv, cfg, MonotonicClock(), cliAddr)
	if err != nil {
		t.Fatal(err)
	}
	inbound := make(chan Inbound, 4)
	done := make(chan error)
	go func() { done <- rd.Run(inbound) }()

	ep, err := NewEndpoint(Client, cfg, 0)
	if err != nil {
		t.Fatal(err)
	}
	write := func(f Flushed) {
		for _, d := range f.Datagrams {
			if _, err := cli.WriteToUDPAddrPort(d, srv.LocalAddr().(*net.UDPAddr).AddrPort()); err != nil {
				t.Fatal(err)
			}
		}
	}
	input, err := wire.Input{Dx: 0.5, Dz: -1, Jump: true, Seq: 7}.Append(nil)
	if err != nil {
		t.Fatal(err)
	}
	write(must(ep.Flush(tick, Unreliable{Stamp: 7, Items: [][]byte{input}})))

	in := next(t, inbound)
	want := Inbound{From: cliAddr, At: in.At, PeerAck: NoAcks, InputStamp: 7, Input: []wire.InputMsg{wire.Input{Dx: 0.5, Dz: -1, Jump: true, Seq: 7}}}
	if !reflect.DeepEqual(in, want) {
		t.Fatalf("got %+v, want %+v", in, want)
	}

	if err := ep.Send(input); err != nil {
		t.Fatal(err)
	}
	write(must(ep.Flush(2*tick, Unreliable{})))
	if in := next(t, inbound); !errors.Is(in.Fault, codec.ErrUnknownMessage) {
		t.Fatalf("got fault %v, want ErrUnknownMessage", in.Fault)
	}
	write(must(ep.Flush(3*tick, Unreliable{Stamp: 8, Items: [][]byte{input}})))
	time.Sleep(50 * time.Millisecond)
	srv.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if in, ok := <-inbound; ok {
		t.Fatalf("forgotten peer still delivered %+v", in)
	}
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
	srv, cli := listen(t), listen(t)
	defer cli.Close()
	srvAddr := srv.LocalAddr().(*net.UDPAddr).AddrPort()
	cliAddr := cli.LocalAddr().(*net.UDPAddr).AddrPort()
	cfg := DefaultConfig(wire.SchemaHash)
	rd, err := NewReader(srv, cfg, MonotonicClock(), cliAddr)
	if err != nil {
		t.Fatal(err)
	}
	inbound := make(chan Inbound, 4)
	done := make(chan error)
	go func() { done <- rd.Run(inbound) }()

	ep, err := NewEndpoint(Client, cfg, 0)
	if err != nil {
		t.Fatal(err)
	}
	flushTo := func(now uint64) {
		for _, d := range must(ep.Flush(now, Unreliable{})).Datagrams {
			if _, err := cli.WriteToUDPAddrPort(d, srvAddr); err != nil {
				t.Fatal(err)
			}
		}
	}
	flushTo(KeepaliveAfter)
	if in := next(t, inbound); in.From != cliAddr || in.PeerAck != NoAcks {
		t.Fatalf("got %+v, want a keepalive from %v", in, cliAddr)
	}
	rd.Forget(cliAddr)
	flushTo(2 * KeepaliveAfter)
	time.Sleep(50 * time.Millisecond)
	srv.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if in, ok := <-inbound; ok {
		t.Fatalf("forgotten peer still delivered %+v", in)
	}
}
