package net_test

// Condemnation: why a connection died, and which observation gets to say so.
//
// PROTOCOL.md, "Which reason is authoritative", settles two rules. Classify by
// cause, so a full send queue and a write timeout both report slow_client and
// differ only in a detail naming the detector. Latch on first condemnation, so
// the read error a torn-down socket provokes is logged under the reason that
// killed it rather than replacing it.
//
// The tests here drive the hub directly rather than through newHarness, for the
// reason TestSlowClientIsDroppedWhenItsSendQueueFills gives: the behaviour is
// the net layer's, and the harness owns no way to hand a test the *Conn that
// the world would be broadcasting to.

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// fatFrame is deliberately larger than any socket buffer this test expects to
// meet, so that blocking a write takes a frame or two rather than a flood. The
// probe that sized it measured 1MiB accepted on this machine's loopback before
// the second write blocked.
const fatFrame = 1 << 20

// testWriteTimeout is short enough that the branch is reachable in well under a
// second, and long enough that a loaded box does not trip it on a healthy write.
const testWriteTimeout = 400 * time.Millisecond

// sendPace throttles the flood into a jammed socket. It is the whole reason
// this test is deterministic rather than a coin flip between the two
// slow-client detectors: at one frame per testWriteTimeout/8, at most eight
// frames can pile into the 64-deep send queue while the write that is already
// in flight runs out its deadline, so the queue cannot fill first.
const sendPace = testWriteTimeout / 8

// TestClosingTheSocketUnblocksABlockedWrite pins the claim about
// coder/websocket that the write pump's deadline now rests on: that CloseNow
// from another goroutine makes a Write blocked on a jammed socket return.
//
// writePump condemns from its own timer and lets that timer's CloseNow abort
// the write, which only terminates if this holds. It replaces an earlier test
// that pinned a different dependency claim -- that a deadline-bearing Write
// fails with something errors.Is-comparable to context.DeadlineExceeded. That
// claim is true, and building on it was still wrong: the library closes the
// connection from its own timer goroutine before returning that error, so the
// read pump could condemn the connection first and a consequence overwrote the
// cause in five runs out of ten.
func TestClosingTheSocketUnblocksABlockedWrite(t *testing.T) {
	server, _ := websocketPair(t)

	failed := make(chan error, 1)
	go func() {
		payload := []byte(strings.Repeat("x", fatFrame))
		for {
			// No deadline: this write must be unblocked by the close below and
			// by nothing else, which is the whole point of the test.
			if err := server.Write(context.Background(), websocket.MessageText, payload); err != nil {
				failed <- err
				return
			}
		}
	}()

	// Long enough for the writer to fill the socket buffers and jam. The probe
	// that sized fatFrame measured one megabyte accepted before the second
	// write blocked.
	time.Sleep(200 * time.Millisecond)
	select {
	case err := <-failed:
		t.Fatalf("the write failed before the socket was closed: %v; this test never observed a blocked write", err)
	default:
	}

	if err := server.CloseNow(); err != nil {
		t.Fatalf("closing the server side: %v", err)
	}

	select {
	case <-failed:
	case <-time.After(readTimeout):
		t.Fatalf("a blocked write was still blocked %v after CloseNow; writePump's timer cannot abort a jammed write and a slow client would never be dropped", readTimeout)
	}
}

// TestTheReadPumpWouldCondemnATornDownSocketAsPeerGone states, as the fact the
// latch test leans on, that the read pump reaches a different answer from the
// write pump for the failure it sees when a slow client is torn down. Without
// it, "the reported reason is slow_client" would be consistent with the read
// pump never having run at all.
func TestTheReadPumpWouldCondemnATornDownSocketAsPeerGone(t *testing.T) {
	// net.ErrClosed is what a blocked read returns once another goroutine has
	// closed the socket under it, which is exactly what condemning a slow
	// client does.
	reason, detail := mnet.ClassifyRead(errWrapped(net.ErrClosed))
	if reason != mnet.DisconnectPeerGone || detail != mnet.DetailReadError {
		t.Fatalf("a read on a torn-down socket classifies as %q/%q, want %q/%q",
			reason, detail, mnet.DisconnectPeerGone, mnet.DetailReadError)
	}
	if reason == mnet.DisconnectSlow {
		t.Fatalf("the read pump classifies a torn-down socket as %q too, so asserting that reason cannot show which observation won", reason)
	}
}

// TestAReadContextDeadlineIsNotACleanClose is a regression test for a wrong
// classification that shipped in this unit's first commit and was caught in
// review.
//
// readReason used to map context deadlines to closed, on the reasoning that
// readPump passes context.Background() so no deadline could ever expire. The
// library falsifies that: it derives its own five-second contexts for control
// frames from whatever it is handed (read.go:303, write.go:277), arms a close
// timer on any context carrying a Done channel (conn.go:171), and finishRead's
// last act is to overwrite the returned error with ctx.Err() (read.go:255). A
// peer that pings while its receive side is jammed is a slow client, and the
// old branch logged it as a clean logout.
//
// This asserts the classifier rather than staging the real thing. Forcing a
// control-frame timeout end to end would mean jamming a peer's receive side,
// getting it to ping, and then waiting out a five-second constant that lives in
// the dependency and cannot be shortened from here -- several times the runtime
// of every other test in this file, to reach a branch one line long. The
// mechanism is established by reading the dependency; what is worth pinning is
// that nobody reinstates the branch.
func TestAReadContextDeadlineIsNotACleanClose(t *testing.T) {
	for _, err := range []error{
		errWrapped(context.DeadlineExceeded),
		errWrapped(context.Canceled),
	} {
		reason, detail := mnet.ClassifyRead(err)
		if reason == mnet.DisconnectClosed {
			t.Fatalf("a read failing with %v classifies as %q, the reason reserved for a peer that sent a close frame; a jammed slow client would be logged as a clean logout", err, reason)
		}
		if reason != mnet.DisconnectPeerGone || detail != mnet.DetailReadError {
			t.Fatalf("a read failing with %v classifies as %q/%q, want %q/%q",
				err, reason, detail, mnet.DisconnectPeerGone, mnet.DetailReadError)
		}
	}
}

// TestWriteTimeoutCondemnsASlowClientAndTheReadErrorDoesNotOverwriteIt is the
// latch, proven by forcing the ordering rather than by reading closeOnce.
//
// The peer is alive, handshaken, and simply never reads. A write blocks, runs
// out its deadline, and condemns the connection as slow_client/write_timeout,
// which tears the socket down. The read pump, blocked in Read on that same
// socket, then wakes with net.ErrClosed and classifies it -- differently, as
// TestClassifiersDisagreeAboutTheSameDyingConnection establishes.
//
// That the read pump really did run is not an assumption. ServeHTTP emits
// EventDisconnected only after readPump returns, and readPump returns only from
// the branch that has just called close with its own classification. So
// receiving the event at all proves the consequence was observed and lost, and
// the reason on it says which observation survived.
func TestWriteTimeoutCondemnsASlowClientAndTheReadErrorDoesNotOverwriteIt(t *testing.T) {
	hub := mnet.NewHub()
	hub.SetWriteTimeout(testWriteTimeout)
	server := httptest.NewServer(hub)
	t.Cleanup(func() {
		hub.Close()
		server.Close()
	})

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	url := "ws" + strings.TrimPrefix(server.URL, "http") + "/"
	ws, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	t.Cleanup(func() { _ = ws.CloseNow() })
	ws.SetReadLimit(1 << 21)

	conn := awaitEvent(t, hub, mnet.EventConnected).Conn

	// The pipe works before it is jammed. Without this the test could pass
	// against a connection that was broken from the start, which is peer_gone
	// wearing a slow client's clothes.
	greeting := encodeFrame(t, mnet.Spawn{ID: 1})
	if !conn.Send(greeting) {
		t.Fatalf("the first send was refused; the connection was never healthy")
	}
	if _, got, err := ws.Read(ctx); err != nil {
		t.Fatalf("the peer could not read the first frame: %v", err)
	} else if string(got) != string(greeting) {
		t.Fatalf("the peer read %q, want the greeting", got)
	}

	// From here the peer never reads again. It is neither closed nor broken; it
	// has simply stopped draining.
	fat := encodeFrame(t, mnet.Error{Re: mnet.MsgMoveTo, Msg: strings.Repeat("x", fatFrame)})

	deadline := time.Now().Add(readTimeout)
	queued := 0
	for conn.Send(fat) {
		queued++
		if time.Now().After(deadline) {
			t.Fatalf("queued %d frames of %d bytes in %v without the write timing out; the branch was never reached",
				queued, len(fat), readTimeout)
		}
		time.Sleep(sendPace)
	}

	disconnect := awaitEvent(t, hub, mnet.EventDisconnected)
	if disconnect.Conn != conn {
		t.Fatalf("the disconnect is for a different connection than the one that was jammed")
	}
	if disconnect.Reason != mnet.DisconnectSlow {
		t.Fatalf("a jammed client died of %q/%q after %d queued frames, want reason %q; the cause did not survive the consequence",
			disconnect.Reason, disconnect.Detail, queued, mnet.DisconnectSlow)
	}
	if disconnect.Detail != mnet.DetailWriteTimeout {
		t.Fatalf("a jammed client died of %q/%q after %d queued frames, want detail %q; %d frames means the send queue won the race this test exists to avoid",
			disconnect.Reason, disconnect.Detail, queued, mnet.DetailWriteTimeout, queued)
	}
}

// TestAbruptPeerDeathReportsPeerGone covers a read error that is not downstream
// of a condemnation: nothing has condemned this connection, so the read pump's
// own classification is the one that lands.
//
// The peer is destroyed without a close handshake, which is what a pulled cable
// or a killed process looks like from the server. A clean close is the other
// test below, and the two must not collapse into one reason.
func TestAbruptPeerDeathReportsPeerGone(t *testing.T) {
	hub := mnet.NewHub()
	server := httptest.NewServer(hub)
	t.Cleanup(func() {
		hub.Close()
		server.Close()
	})

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	url := "ws" + strings.TrimPrefix(server.URL, "http") + "/"
	ws, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}

	conn := awaitEvent(t, hub, mnet.EventConnected).Conn

	// CloseNow drops the TCP connection without sending a close frame, so the
	// server has no way to be told this was on purpose.
	if err := ws.CloseNow(); err != nil {
		t.Fatalf("destroying the peer: %v", err)
	}

	disconnect := awaitEvent(t, hub, mnet.EventDisconnected)
	if disconnect.Conn != conn {
		t.Fatalf("the disconnect is for a different connection than the one that was destroyed")
	}
	if disconnect.Reason != mnet.DisconnectPeerGone || disconnect.Detail != mnet.DetailReadError {
		t.Fatalf("a peer that vanished mid-connection reported %q/%q, want %q/%q",
			disconnect.Reason, disconnect.Detail, mnet.DisconnectPeerGone, mnet.DetailReadError)
	}
}

// TestCleanPeerCloseIsNotACondemnation is the contrast. A client that closes on
// purpose is not a failure of anything, so it must stay distinct from
// peer_gone: a log full of peer_gone for ordinary logouts tells an operator
// nothing.
func TestCleanPeerCloseIsNotACondemnation(t *testing.T) {
	hub := mnet.NewHub()
	server := httptest.NewServer(hub)
	t.Cleanup(func() {
		hub.Close()
		server.Close()
	})

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	url := "ws" + strings.TrimPrefix(server.URL, "http") + "/"
	ws, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	t.Cleanup(func() { _ = ws.CloseNow() })

	conn := awaitEvent(t, hub, mnet.EventConnected).Conn

	if err := ws.Close(websocket.StatusNormalClosure, "logging out"); err != nil {
		t.Fatalf("closing the peer cleanly: %v", err)
	}

	disconnect := awaitEvent(t, hub, mnet.EventDisconnected)
	if disconnect.Conn != conn {
		t.Fatalf("the disconnect is for a different connection than the one that left")
	}
	if disconnect.Reason != mnet.DisconnectClosed {
		t.Fatalf("a clean logout reported %q, want %q", disconnect.Reason, mnet.DisconnectClosed)
	}
	if disconnect.Detail != "" {
		t.Fatalf("a clean logout carried detail %q; only one path can reach it, so naming a detector is a lie", disconnect.Detail)
	}
}

// TestAbruptDisconnectLogsTheCauseAndTheDetector is the end-to-end half: a
// reason and a detail have to survive the trip from the hub, through the
// world's event handling, into the NDJSON log a human actually reads.
//
// It uses a vanished peer rather than a slow client because both carry a
// non-empty detail and only this one is cheap to stage through a real world.
// TestDisconnectDespawns covers the same path for the empty case.
func TestAbruptDisconnectLogsTheCauseAndTheDetector(t *testing.T) {
	h := newHarness(t)

	victim := h.dial("victim")
	victimWelcome := victim.welcome()

	victim.destroy()

	disconnects := h.awaitEvents(game.EvDisconnected, 1)
	if got := disconnects[0]["player"]; got != float64(victimWelcome.You) {
		t.Fatalf("client_disconnected logged player %v, want %d", got, victimWelcome.You)
	}
	if got := disconnects[0]["reason"]; got != mnet.DisconnectPeerGone {
		t.Fatalf("client_disconnected logged reason %v for a vanished peer, want %q", got, mnet.DisconnectPeerGone)
	}
	if got := disconnects[0]["detail"]; got != mnet.DetailReadError {
		t.Fatalf("client_disconnected logged detail %v for a vanished peer, want %q; the detector never reached the log",
			got, mnet.DetailReadError)
	}
}

// websocketPair returns a connected server and client, with the client doing no
// reading at all. The caller writes on the server side.
func websocketPair(t *testing.T) (server, peer *websocket.Conn) {
	t.Helper()

	accepted := make(chan *websocket.Conn, 1)
	failed := make(chan error, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			failed <- err
			return
		}
		accepted <- ws
		// Hold the handler open for the test's lifetime; httptest.Server.Close
		// waits for it, and t.Cleanup closes the socket first.
		<-r.Context().Done()
	}))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/"
	client, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	t.Cleanup(func() { _ = client.CloseNow() })

	select {
	case ws := <-accepted:
		t.Cleanup(func() { _ = ws.CloseNow() })
		return ws, client
	case err := <-failed:
		t.Fatalf("accept: %v", err)
	case <-time.After(readTimeout):
		t.Fatalf("the server never accepted the connection")
	}
	return nil, nil
}

// errWrapped mimics the layers coder/websocket puts between a cause and the
// error a caller sees, so the classifier tests exercise errors.Is rather than
// equality.
func errWrapped(cause error) error {
	return wrapErr{cause}
}

type wrapErr struct{ cause error }

func (w wrapErr) Error() string {
	return "failed to write msg: failed to write frame: " + w.cause.Error()
}
func (w wrapErr) Unwrap() error { return w.cause }
