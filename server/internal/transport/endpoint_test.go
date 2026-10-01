package transport

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"testing"
)

func TestSpecExample(t *testing.T) {
	ep := mustEndpoint(Server, testConfig(), 0)
	if err := ep.Send([]byte{0x04, 0x07, 0x09, 0x06}); err != nil {
		t.Fatal(err)
	}
	f := must(ep.Flush(40_000, Unreliable{Stamp: 1, Items: [][]byte{{0x03, 0x01, 0x02}}}))
	got := hex.EncodeToString(f.Datagrams[0])
	want := "4d525131" + "efcdab8967452301" + "0000" + "ffff" + "00000000" +
		"01" + "01000000" + "0100" + "03" + "030102" +
		"02" + "0100" + "0000" + "00" + "01" + "04" + "04070906"
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestIDsAndSequencesWrap(t *testing.T) {
	srv := mustEndpoint(Server, testConfig(), 0)
	cli := mustEndpoint(Client, testConfig(), 0)
	const n = 70_000
	got := 0
	var last []byte
	for i := 1; i <= n; i++ {
		now := uint64(i) * tick
		if err := srv.Send(binary.LittleEndian.AppendUint32(nil, uint32(i))); err != nil {
			t.Fatal(err)
		}
		for _, d := range must(srv.Flush(now, Unreliable{})).Datagrams {
			r, err := cli.Receive(d, now)
			if err != nil {
				t.Fatalf("tick %d: %v", i, err)
			}
			for _, m := range r.Reliable {
				got++
				if v := binary.LittleEndian.Uint32(m); v != uint32(got) {
					t.Fatalf("delivery %d carried %d", got, v)
				}
			}
			last = d
		}
		for _, d := range must(cli.Flush(now, Unreliable{Stamp: uint32(i), Items: [][]byte{{0x01}}})).Datagrams {
			if _, err := srv.Receive(d, now); err != nil {
				t.Fatalf("tick %d: %v", i, err)
			}
		}
	}
	if got != n || srv.Backlog() != 0 {
		t.Fatalf("delivered %d of %d, backlog %d", got, n, srv.Backlog())
	}
	if seq := binary.LittleEndian.Uint16(last[12:]); seq != 4463 {
		t.Fatalf("last server sequence %d, want 4463 (69999 mod 65536)", seq)
	}
}

func TestSendRefusesEmptyAndOversized(t *testing.T) {
	ep := mustEndpoint(Server, testConfig(), 0)
	for _, n := range []int{0, MaxMessage + 1} {
		if err := ep.Send(make([]byte, n)); !errors.Is(err, ErrMessage) {
			t.Fatalf("Send(%d bytes) = %v, want ErrMessage", n, err)
		}
	}
	if err := ep.Send(make([]byte, MaxMessage)); err != nil {
		t.Fatalf("Send(MaxMessage) = %v", err)
	}
}

func TestConfigRefusesBudgetBelowOneDatagram(t *testing.T) {
	cfg := testConfig()
	cfg.TickBudget = MaxDatagram - 1
	if _, err := NewEndpoint(Server, cfg, Plain{}, Plain{}, 0); err == nil {
		t.Fatal("TickBudget 1199 accepted")
	}
}

func TestEndpointRefusesAMissingSealHalf(t *testing.T) {
	_, noOpen := NewEndpoint(Server, testConfig(), nil, Plain{}, 0)
	_, noSeal := NewEndpoint(Server, testConfig(), Plain{}, nil, 0)
	got := fmt.Sprintf("%v | %v", noOpen, noSeal)
	if want := "transport: Opener is nil | transport: Sealer is nil"; got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestFlushRefusesEmptyItemWithoutLosingEvents(t *testing.T) {
	srv := mustEndpoint(Server, testConfig(), 0)
	cli := mustEndpoint(Client, testConfig(), 0)
	if err := srv.Send([]byte{0x04, 0x01}); err != nil {
		t.Fatal(err)
	}
	for i := uint64(1); i <= 50; i++ {
		f, err := srv.Flush(i*tick, Unreliable{Stamp: uint32(i), Items: [][]byte{{0x02}, {}}})
		if !errors.Is(err, ErrItem) || len(f.Datagrams) != 0 {
			t.Fatalf("tick %d: got %d datagrams, %v; want 0, ErrItem", i, len(f.Datagrams), err)
		}
	}
	var delivered [][]byte
	for _, d := range must(srv.Flush(51*tick, Unreliable{Stamp: 51, Items: [][]byte{{0x02}}})).Datagrams {
		r, err := cli.Receive(d, 51*tick)
		if err != nil {
			t.Fatal(err)
		}
		delivered = append(delivered, r.Reliable...)
	}
	for _, d := range must(cli.Flush(52*tick, Unreliable{})).Datagrams {
		if _, err := srv.Receive(d, 52*tick); err != nil {
			t.Fatal(err)
		}
	}
	if got := fmt.Sprintf("delivered=%x backlog=%d", delivered, srv.Backlog()); got != "delivered=[0401] backlog=0" {
		t.Fatalf("got %s, want delivered=[0401] backlog=0", got)
	}
}

func TestFlushItemLimit(t *testing.T) {
	for _, tc := range []struct {
		size int
		err  error
	}{
		{1171, nil},
		{1172, ErrItem},
		{16384, ErrItem},
	} {
		ep := mustEndpoint(Server, testConfig(), 0)
		f, err := ep.Flush(tick, Unreliable{Stamp: 1, Items: [][]byte{make([]byte, tc.size)}})
		if !errors.Is(err, tc.err) {
			t.Fatalf("item of %d bytes: got %v, want %v", tc.size, err, tc.err)
		}
		if tc.err == nil && (len(f.Datagrams) != 1 || len(f.Datagrams[0]) != MaxDatagram || f.UnreliableSent != 1) {
			t.Fatalf("item of %d bytes: got %d datagrams, sent %d; want one full datagram", tc.size, len(f.Datagrams), f.UnreliableSent)
		}
	}
}
