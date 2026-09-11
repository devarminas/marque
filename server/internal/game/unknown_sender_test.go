package game


import (
	"bytes"
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func dialOneConn(t *testing.T) (*World, *bytes.Buffer, *mnet.Conn) {
	t.Helper()

	logs := &bytes.Buffer{}
	hub := mnet.NewHub()
	w := NewWorld(hub, gamelog.New(logs, true), NewMemoryStore(NoWearables), ResumeGraceTicks, nil)

	srv := httptest.NewServer(hub)
	t.Cleanup(func() {
		hub.Close()
		srv.Close()
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial %s: %v", srv.URL, err)
	}
	t.Cleanup(func() { _ = ws.CloseNow() })

	ev := <-hub.Events()
	if ev.Kind != mnet.EventConnected {
		t.Fatalf("the hub's first event is %v, want connected", ev.Kind)
	}
	w.handle(ev)
	return w, logs, ev.Conn
}

func TestAFrameFromAConnectionTheWorldRetiredIsDropped(t *testing.T) {
	w, logs, conn := dialOneConn(t)

	w.handle(mnet.Event{Kind: mnet.EventDisconnected, Conn: conn, Reason: mnet.DisconnectClosed})
	if _, known := w.byConn[conn]; known {
		t.Fatal("the world still knows the retired connection")
	}

	w.handle(mnet.Event{Kind: mnet.EventFrame, Conn: conn, Msg: mnet.MoveTo{X: 5, Z: 5}})

	dropped := eventsNamed(t, logs, EvFrameDropped)
	if len(dropped) != 1 {
		t.Fatalf("logged %d %s events, want 1: %+v", len(dropped), EvFrameDropped, dropped)
	}
	if got := dropped[0]["reason"]; got != string(mnet.ReasonUnknownSender) {
		t.Fatalf("%s logged reason %v, want %q", EvFrameDropped, got, mnet.ReasonUnknownSender)
	}
	if got := dropped[0]["remote"]; got != conn.Remote() {
		t.Fatalf("%s logged remote %v, want %q", EvFrameDropped, got, conn.Remote())
	}
	if moved := eventsNamed(t, logs, EvMoveTo); len(moved) != 0 {
		t.Fatalf("a frame from an unknown sender reached the world: %+v", moved)
	}
	if rejected := eventsNamed(t, logs, EvMoveToRejected); len(rejected) != 0 {
		t.Fatalf("a frame from an unknown sender was answered: %+v", rejected)
	}
}

func TestAFrameFromASuspendedPlayersOldConnectionIsDropped(t *testing.T) {
	w, logs, conn := dialOneConn(t)

	w.handle(mnet.Event{
		Kind:   mnet.EventDisconnected,
		Conn:   conn,
		Reason: mnet.DisconnectPeerGone,
		Detail: mnet.DetailReadError,
	})
	if len(w.order) != 1 {
		t.Fatalf("the world holds %d players after a suspension, want the body to stay", len(w.order))
	}
	if _, known := w.byConn[conn]; known {
		t.Fatal("the world still routes frames from a suspended player's dead socket")
	}

	w.handle(mnet.Event{Kind: mnet.EventFrame, Conn: conn, Msg: mnet.MoveTo{X: 5, Z: 5}})

	dropped := eventsNamed(t, logs, EvFrameDropped)
	if len(dropped) != 1 {
		t.Fatalf("logged %d %s events, want 1: %+v", len(dropped), EvFrameDropped, dropped)
	}
	if got := dropped[0]["reason"]; got != string(mnet.ReasonUnknownSender) {
		t.Fatalf("%s logged reason %v, want %q", EvFrameDropped, got, mnet.ReasonUnknownSender)
	}
	if w.order[0].steering() {
		t.Fatal("the suspended body took a steer from its own dead socket")
	}
}
