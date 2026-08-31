package net_test

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// TestSlowClientIsDroppedWhenItsSendQueueFills covers rule 4 of PROTOCOL.md's
// "Ordering and the join race": a connection whose send queue is full is
// closed, never waited on. It is the tick loop's only protection against a
// client that has stopped reading, and it is the branch in Conn.Send that
// TestConcurrentTrafficStaysConsistent does not reach -- that test's churn
// client is closed, which leaves Send by the already-closed early return one
// line above.
//
// The peer here is the opposite: alive, handshaken, answering at the TCP level,
// and simply never calling Read. Frames pile up in its kernel receive buffer,
// then in the server's send buffer, then writePump blocks in ws.Write, and only
// then does the 64-frame channel fill. Every layer in front of the branch has
// to be full before the branch is reachable at all, which is why this needs
// large frames rather than many: volume alone would have to outrun the socket
// buffers for long enough to run into the 5s write timeout instead, and a drop
// for the wrong reason is not this test passing.
//
// The hub is driven directly rather than through newHarness because the branch
// is the net layer's, and the harness owns no way to hand a test the *Conn that
// the world would be broadcasting to. Nothing about the connection is faked:
// real Hub, real HTTP upgrade, real socket, real writePump, and Send called
// exactly as World.broadcast calls it.
func TestSlowClientIsDroppedWhenItsSendQueueFills(t *testing.T) {
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
	// The frames below are deliberately larger than the library's 32KiB
	// default, and a peer that refused them on a read limit would be a
	// different failure from a peer that never read them.
	ws.SetReadLimit(1 << 20)

	conn := awaitEvent(t, hub, mnet.EventConnected).Conn

	// The peer is alive and the pipe works. Without this the test could pass
	// against a connection that was already broken, which is the failure mode
	// it exists to distinguish from.
	greeting := encodeFrame(t, mnet.Spawn{ID: 1})
	if !conn.Send(greeting) {
		t.Fatalf("the first send was refused; the connection was never healthy")
	}
	if _, got, err := ws.Read(ctx); err != nil {
		t.Fatalf("the peer could not read the first frame: %v", err)
	} else if string(got) != string(greeting) {
		t.Fatalf("the peer read %q, want %q", got, greeting)
	}

	// From here the peer never reads again. It is not closed and it is not
	// broken; it has simply stopped draining, which is the case the branch is
	// for.
	fat := encodeFrame(t, mnet.Error{Re: mnet.MsgMoveTo, Msg: strings.Repeat("x", 1<<16)})

	deadline := time.Now().Add(readTimeout)
	accepted := 0
	for conn.Send(fat) {
		accepted++
		if time.Now().After(deadline) {
			t.Fatalf("the send queue took %d frames of %d bytes in %v without filling; the drop branch was never reached",
				accepted, len(fat), readTimeout)
		}
	}

	// Send refused a frame. It refuses for two reasons and they are not the
	// same event, so the disconnect has to name which one happened.
	disconnect := awaitEvent(t, hub, mnet.EventDisconnected)
	if disconnect.Conn != conn {
		t.Fatalf("the disconnect is for a different connection than the one that was flooded")
	}
	if disconnect.Reason != mnet.DisconnectSlow {
		t.Fatalf("the connection was dropped for %q after %d queued frames, want %q; a drop for any other reason means this test did not exercise the full send queue",
			disconnect.Reason, accepted, mnet.DisconnectSlow)
	}

	// A dropped connection stays dropped, so the world cannot go on queueing
	// frames for a player it is about to be told has left.
	if conn.Send(greeting) {
		t.Fatalf("a send was accepted after the connection was dropped")
	}

	// And the socket really is gone, rather than only the server's opinion of
	// it. The peer's own reads are what say so.
	expectPeerClosed(t, ws)
}

// awaitEvent takes the next hub event and insists it is the kind expected.
func awaitEvent(t *testing.T, hub *mnet.Hub, kind mnet.EventKind) mnet.Event {
	t.Helper()

	select {
	case ev, open := <-hub.Events():
		if !open {
			t.Fatalf("the hub's event stream closed while waiting for %v", kind)
		}
		if ev.Kind != kind {
			t.Fatalf("got a %v event, want %v", ev.Kind, kind)
		}
		return ev
	case <-time.After(readTimeout):
		t.Fatalf("no %v event within %v", kind, readTimeout)
		return mnet.Event{}
	}
}

// expectPeerClosed reads until the peer's socket reports an error, which is how
// a client learns the server hung up on it. Whatever the server had already
// pushed into the socket may still be waiting there, so this reads through it
// rather than expecting the very next read to fail.
func expectPeerClosed(t *testing.T, ws *websocket.Conn) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		if _, _, err := ws.Read(ctx); err != nil {
			return
		}
	}
	t.Fatalf("the peer's socket was still readable %v after the server dropped it", readTimeout)
}

func encodeFrame(t *testing.T, msg mnet.ServerMessage) []byte {
	t.Helper()

	payload, err := mnet.Encode(msg)
	if err != nil {
		t.Fatalf("encode %T: %v", msg, err)
	}
	return payload
}
