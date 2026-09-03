package net_test

// Condemnation: why a connection died, and which observation gets to say so
// (PROTOCOL.md, "Which reason is authoritative").

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

// fatFrame is larger than any socket buffer these tests expect to meet, so
// jamming a write takes a frame or two rather than a flood.
const fatFrame = 1 << 20

const testWriteTimeout = 400 * time.Millisecond

// sendPace throttles the flood into a jammed socket so that the write timeout
// fires before the send queue fills, making the detector deterministic.
const sendPace = testWriteTimeout / 8

func TestClosingTheSocketUnblocksABlockedWrite(t *testing.T) {
	server, _ := websocketPair(t)

	failed := make(chan error, 1)
	go func() {
		payload := []byte(strings.Repeat("x", fatFrame))
		for {
			if err := server.Write(context.Background(), websocket.MessageText, payload); err != nil {
				failed <- err
				return
			}
		}
	}()

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

func TestTheReadPumpWouldCondemnATornDownSocketAsPeerGone(t *testing.T) {
	// net.ErrClosed is what a blocked read returns once another goroutine has
	// closed the socket under it, which is what condemning a slow client does.
	reason, detail := mnet.ClassifyRead(errWrapped(net.ErrClosed))
	if reason != mnet.DisconnectPeerGone || detail != mnet.DetailReadError {
		t.Fatalf("a read on a torn-down socket classifies as %q/%q, want %q/%q",
			reason, detail, mnet.DisconnectPeerGone, mnet.DetailReadError)
	}
	if reason == mnet.DisconnectSlow {
		t.Fatalf("the read pump classifies a torn-down socket as %q too, so asserting that reason cannot show which observation won", reason)
	}
}

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

// TestWriteTimeoutCondemnsASlowClientAndTheReadErrorDoesNotOverwriteIt proves
// the read pump ran and lost: ServeHTTP emits EventDisconnected only after
// readPump has returned from a branch that called close with its own
// classification, so receiving the event at all means the consequence was
// observed, and the reason on it says which observation survived.
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

	greeting := encodeFrame(t, mnet.Spawn{ID: 1})
	if !conn.Send(greeting) {
		t.Fatalf("the first send was refused; the connection was never healthy")
	}
	if _, got, err := ws.Read(ctx); err != nil {
		t.Fatalf("the peer could not read the first frame: %v", err)
	} else if string(got) != string(greeting) {
		t.Fatalf("the peer read %q, want the greeting", got)
	}

	// From here the peer never reads again: not closed, not broken, just not
	// draining.
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

	// CloseNow, unlike Close, drops the TCP connection without sending a close
	// frame, so the server has no way to be told this was on purpose.
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

	expectNoFurtherEvents(t, hub)
}

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

// TestAJammedPongCondemnsTheClientAsPeerGone is the only thing establishing
// that a context deadline can reach the read goroutine at all, which is the
// scenario readReason's context handling exists for.
func TestAJammedPongCondemnsTheClientAsPeerGone(t *testing.T) {
	hub := mnet.NewHub()
	// Past the library's five-second control-frame deadline, so the library's
	// is the one that fires.
	hub.SetWriteTimeout(time.Minute)
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

	greeting := encodeFrame(t, mnet.Spawn{ID: 1})
	if !conn.Send(greeting) {
		t.Fatalf("the first send was refused; the connection was never healthy")
	}
	if _, got, err := ws.Read(ctx); err != nil {
		t.Fatalf("the peer could not read the first frame: %v", err)
	} else if string(got) != string(greeting) {
		t.Fatalf("the peer read %q, want the greeting", got)
	}

	// From here the peer never reads, so writePump ends up blocked inside
	// ws.Write holding the write mutex the pong will need.
	fat := encodeFrame(t, mnet.Error{Re: mnet.MsgMoveTo, Msg: strings.Repeat("x", fatFrame)})
	for i := 0; i < 3; i++ {
		if !conn.Send(fat) {
			t.Fatalf("send %d was refused; the connection died before the jam was set up", i)
		}
	}

	time.Sleep(500 * time.Millisecond)
	select {
	case ev := <-hub.Events():
		t.Fatalf("the connection was already condemned as %q/%q before the peer pinged; this test never reached its own scenario",
			ev.Reason, ev.Detail)
	default:
	}

	// Ping blocks for a pong that cannot arrive, so it is left to the cleanup:
	// the frame is what matters, not the round trip.
	pingCtx, pingCancel := context.WithCancel(context.Background())
	t.Cleanup(pingCancel)
	go func() { _ = ws.Ping(pingCtx) }()

	// Its own budget rather than awaitEvent's: the library's control-frame
	// deadline is five seconds on its own, so readTimeout cannot cover it.
	const pongBudget = 15 * time.Second
	start := time.Now()
	var disconnect mnet.Event
	select {
	case ev, open := <-hub.Events():
		if !open {
			t.Fatalf("the hub's event stream closed while waiting for the disconnect")
		}
		if ev.Kind != mnet.EventDisconnected {
			t.Fatalf("got a %v event, want disconnected", ev.Kind)
		}
		disconnect = ev
	case <-time.After(pongBudget):
		t.Fatalf("nothing condemned the connection within %v of the ping; the pong never blocked on the write mutex and this test did not reach its scenario", pongBudget)
	}
	if disconnect.Conn != conn {
		t.Fatalf("the disconnect is for a different connection than the one that was jammed")
	}
	if disconnect.Reason == mnet.DisconnectClosed {
		t.Fatalf("a jammed pong reported %q after %v, the reason reserved for a peer that sent a close frame; this peer sent a ping and never closed",
			disconnect.Reason, time.Since(start))
	}
	if disconnect.Reason != mnet.DisconnectPeerGone || disconnect.Detail != mnet.DetailReadError {
		t.Fatalf("a jammed pong reported %q/%q after %v, want %q/%q",
			disconnect.Reason, disconnect.Detail, time.Since(start), mnet.DisconnectPeerGone, mnet.DetailReadError)
	}
}

// websocketPair returns a connected server and client. The client never reads,
// so writes on the server side jam.
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

func expectNoFurtherEvents(t *testing.T, hub *mnet.Hub) {
	t.Helper()

	select {
	case ev, open := <-hub.Events():
		if !open {
			return
		}
		t.Fatalf("the hub emitted a second %v event for a connection it had already retired, reason %q; EventDisconnected is documented as exactly once per connection",
			ev.Kind, ev.Reason)
	case <-time.After(silenceWindow):
	}
}
