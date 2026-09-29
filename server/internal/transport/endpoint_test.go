package transport

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"testing"
)

// TestSpecExample is the worked example in shared/wire/transport.md.
func TestSpecExample(t *testing.T) {
	ep := mustEndpoint(Server, testConfig(), 0)
	if err := ep.Send([]byte{0x04, 0x07, 0x09, 0x06}); err != nil {
		t.Fatal(err)
	}
	f := ep.Flush(40_000, Unreliable{Stamp: 1, Items: [][]byte{{0x03, 0x01, 0x02}}})
	got := hex.EncodeToString(f.Datagrams[0])
	want := "4d525131" + "efcdab8967452301" + "0000" + "ffff" + "00000000" +
		"01" + "01000000" + "0100" + "03" + "030102" +
		"02" + "0100" + "0000" + "00" + "01" + "04" + "04070906"
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

// TestIDsAndSequencesWrap runs 70000 ticks, one event each, over a lossless
// link, so packet sequences and reliable message ids both pass 65535.
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
		for _, d := range srv.Flush(now, Unreliable{}).Datagrams {
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
		for _, d := range cli.Flush(now, Unreliable{Stamp: uint32(i), Items: [][]byte{{0x01}}}).Datagrams {
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
	if _, err := NewEndpoint(Server, cfg, 0); err == nil {
		t.Fatal("TickBudget 1199 accepted")
	}
}
