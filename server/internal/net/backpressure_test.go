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
	ws.SetReadLimit(1 << 20)

	conn := awaitEvent(t, hub, mnet.EventConnected).Conn

	greeting := encodeFrame(t, mnet.Spawn{ID: 1})
	if !conn.Send(greeting) {
		t.Fatalf("the first send was refused; the connection was never healthy")
	}
	if _, got, err := ws.Read(ctx); err != nil {
		t.Fatalf("the peer could not read the first frame: %v", err)
	} else if string(got) != string(greeting) {
		t.Fatalf("the peer read %q, want %q", got, greeting)
	}

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

	disconnect := awaitEvent(t, hub, mnet.EventDisconnected)
	if disconnect.Conn != conn {
		t.Fatalf("the disconnect is for a different connection than the one that was flooded")
	}
	if disconnect.Reason != mnet.DisconnectSlow {
		t.Fatalf("the connection was dropped for %q after %d queued frames, want %q; a drop for any other reason means this test did not exercise the full send queue",
			disconnect.Reason, accepted, mnet.DisconnectSlow)
	}
	if disconnect.Detail != mnet.DetailSendBufferFull {
		t.Fatalf("the connection was dropped for %q/%q after %d queued frames, want detail %q; the reason alone cannot say which of the two slow-client detectors fired",
			disconnect.Reason, disconnect.Detail, accepted, mnet.DetailSendBufferFull)
	}

	if conn.Send(greeting) {
		t.Fatalf("a send was accepted after the connection was dropped")
	}

	expectPeerClosed(t, ws)
}

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
