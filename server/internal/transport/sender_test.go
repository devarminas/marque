package transport

import "testing"

func mustSender(t *testing.T, role Role, cfg Config, now uint64) *Sender {
	t.Helper()
	s, err := NewSender(role, cfg, now)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestObserveStampedAfterFlushClockStaysOpen(t *testing.T) {
	s := mustSender(t, Server, testConfig(), 0)
	s.Observe(NoAcks, NoAcks, 1_000_001)
	if got := s.Flush(1_000_000, Unreliable{}).State; got != Open {
		t.Fatalf("Flush(1000000) after Observe(1000001) is %v, want open", got)
	}
}

func TestObserveNeverMovesLastReceiveBack(t *testing.T) {
	s := mustSender(t, Server, testConfig(), 0)
	s.Observe(NoAcks, NoAcks, 3_000_000)
	s.Observe(NoAcks, NoAcks, 1_000_000)
	if got := s.Flush(7_999_999, Unreliable{}).State; got != Open {
		t.Fatalf("Flush(7999999) is %v, want open", got)
	}
	if got := s.Flush(8_000_000, Unreliable{}).State; got != TimedOut {
		t.Fatalf("Flush(8000000) is %v, want timed_out", got)
	}
}

func TestFlushBeforeLastSendSendsNoKeepalive(t *testing.T) {
	s := mustSender(t, Client, testConfig(), 500_000)
	f := s.Flush(400_000, Unreliable{})
	if len(f.Datagrams) != 0 || f.State != Open {
		t.Fatalf("Flush(400000) on a sender created at 500000 gave %d datagrams, %v; want 0, open", len(f.Datagrams), f.State)
	}
}
