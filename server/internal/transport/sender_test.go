package transport

import (
	"fmt"
	"testing"
)

func mustSender(t *testing.T, role Role, cfg Config, now uint64) *Sender {
	t.Helper()
	s, err := NewSender(role, cfg, Plain{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestObserveStampedAfterFlushClockStaysOpen(t *testing.T) {
	s := mustSender(t, Server, testConfig(), 0)
	s.Observe(NoAcks, NoAcks, 1_000_001)
	if got := must(s.Flush(1_000_000, Unreliable{})).State; got != Open {
		t.Fatalf("Flush(1000000) after Observe(1000001) is %v, want open", got)
	}
}

func TestObserveNeverMovesLastReceiveBack(t *testing.T) {
	s := mustSender(t, Server, testConfig(), 0)
	s.Observe(NoAcks, NoAcks, 3_000_000)
	s.Observe(NoAcks, NoAcks, 1_000_000)
	if got := must(s.Flush(7_999_999, Unreliable{})).State; got != Open {
		t.Fatalf("Flush(7999999) is %v, want open", got)
	}
	if got := must(s.Flush(8_000_000, Unreliable{})).State; got != TimedOut {
		t.Fatalf("Flush(8000000) is %v, want timed_out", got)
	}
}

func TestFlushBeforeLastSendSendsNoKeepalive(t *testing.T) {
	s := mustSender(t, Client, testConfig(), 500_000)
	f := must(s.Flush(400_000, Unreliable{}))
	if len(f.Datagrams) != 0 || f.State != Open {
		t.Fatalf("Flush(400000) on a sender created at 500000 gave %d datagrams, %v; want 0, open", len(f.Datagrams), f.State)
	}
}

func TestBacklogBytesTripsSlowClient(t *testing.T) {
	cfg := testConfig()
	cfg.BacklogBytes = 3000
	s := mustSender(t, Server, cfg, 0)
	var got []string
	for _, n := range []int{1000, 1000, 1000, 1, 1} {
		err := s.Send(make([]byte, n))
		got = append(got, fmt.Sprintf("%d:%v:%v:%d", n, err, s.State(), s.Backlog()))
	}
	want := "[1000:<nil>:open:1 1000:<nil>:open:2 1000:<nil>:open:3 1:<nil>:slow_client:0 1:transport: connection closed:slow_client:0]"
	if fmt.Sprint(got) != want {
		t.Fatalf("got  %v\nwant %s", got, want)
	}
}

func retained(s *Sender) string {
	refs := 0
	for _, p := range s.sent {
		refs += len(p.frags)
	}
	return fmt.Sprintf("queued=%d msgs=%d refs=%d", s.queued, len(s.queue), refs)
}

func TestClosingReleasesQueueAndRing(t *testing.T) {
	for _, tc := range []struct {
		name  string
		close func(s *Sender)
		state State
	}{
		{"slow_client", func(s *Sender) {
			for s.Send(make([]byte, MaxMessage)) == nil {
			}
		}, SlowClient},
		{"timed_out", func(s *Sender) { must(s.Flush(TimeoutAfter, Unreliable{})) }, TimedOut},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := mustSender(t, Server, testConfig(), 0)
			for i := 0; i < 3; i++ {
				if err := s.Send(make([]byte, 3000)); err != nil {
					t.Fatal(err)
				}
			}
			for i := uint64(1); i <= 4; i++ {
				must(s.Flush(i*tick, Unreliable{}))
			}
			before := retained(s)
			tc.close(s)
			got := fmt.Sprintf("%v before %s after %s", s.State(), before, retained(s))
			want := fmt.Sprintf("%v before queued=9000 msgs=3 refs=9 after queued=0 msgs=0 refs=0", tc.state)
			if got != want {
				t.Fatalf("got  %s\nwant %s", got, want)
			}
		})
	}
}

func TestConfigCapsBacklogLimit(t *testing.T) {
	var got []string
	for _, n := range []int{0, 1, 65280, 65281} {
		cfg := testConfig()
		cfg.BacklogLimit = n
		_, err := NewSender(Server, cfg, Plain{}, 0)
		got = append(got, fmt.Sprintf("%d:%v", n, err))
	}
	want := "[0:transport: BacklogLimit 0 outside 1 to 65280 1:<nil> 65280:<nil> 65281:transport: BacklogLimit 65281 outside 1 to 65280]"
	if fmt.Sprint(got) != want {
		t.Fatalf("got  %v\nwant %s", got, want)
	}
}

func TestFlushedNamesTheDatagramCarryingTheUnreliableSection(t *testing.T) {
	srv := mustEndpoint(Server, testConfig(), 0)
	cli := mustEndpoint(Client, testConfig(), 0)
	must(srv.Flush(0, Unreliable{Stamp: 1, Items: [][]byte{{1}}}))
	if err := srv.Send(make([]byte, 3000)); err != nil {
		t.Fatal(err)
	}
	f := must(srv.Flush(0, Unreliable{Stamp: 2, Items: [][]byte{make([]byte, 100)}}))
	var got []string
	for _, d := range f.Datagrams {
		r := must(cli.Receive(d, 0))
		got = append(got, fmt.Sprintf("seq=%d items=%d", readHeader(d).seq, len(r.Unreliable.Items)))
	}
	want := "[seq=1 items=0 seq=2 items=0 seq=3 items=1]"
	if fmt.Sprint(got) != want || f.UnreliableSent != 1 || f.UnreliableSeq != 3 {
		t.Fatalf("datagrams %v, unreliable sent %d in seq %d; want %s, sent 1 in seq 3", got, f.UnreliableSent, f.UnreliableSeq, want)
	}
}
