package game

// The defensive branch in handleFrame: a frame arriving on a connection the
// world has no player for.
//
// In-package, and driving World.handle by hand rather than through Run, because
// that is what makes the case reachable at all. The hub emits a connection
// before any of its frames and a disconnect after all of them, so a conforming
// hub cannot produce this ordering and no test against the real event loop can
// stage it without racing the teardown. Feeding the events directly is the only
// way to assert the branch instead of hoping to hit it.

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

// dialOneConn brings a real *mnet.Conn into existence and hands it back along
// with the world that has just been told about it.
//
// A real connection and not a stand-in: Conn's zero value has nil channels and
// panics on the first Send, and giving the world a fake would leave the test
// asserting against something that is not what handleFrame receives.
func dialOneConn(t *testing.T) (*World, *bytes.Buffer, *mnet.Conn) {
	t.Helper()

	logs := &bytes.Buffer{}
	hub := mnet.NewHub()
	w := NewWorld(hub, gamelog.New(logs, true), NewMemoryStore(), ResumeGraceTicks)

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

	// Nothing runs w.Run, so this test goroutine is the world goroutine and
	// draining the hub is its job.
	ev := <-hub.Events()
	if ev.Kind != mnet.EventConnected {
		t.Fatalf("the hub's first event is %v, want connected", ev.Kind)
	}
	w.handle(ev)
	return w, logs, ev.Conn
}

// TestAFrameFromAConnectionTheWorldRetiredIsDropped is acceptance 8.
//
// The frame is neither answered nor allowed to reach world state. Answering it
// would mean sending an error to a socket the world has already forgotten;
// letting it through would mean acting on an intent from nobody.
func TestAFrameFromAConnectionTheWorldRetiredIsDropped(t *testing.T) {
	w, logs, conn := dialOneConn(t)

	// A clean logout retires the player, so the world no longer knows the
	// socket even though the socket is still open.
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
	// A dropped frame is dropped, not refused: no move_to and no rejection.
	if moved := eventsNamed(t, logs, EvMoveTo); len(moved) != 0 {
		t.Fatalf("a frame from an unknown sender reached the world: %+v", moved)
	}
	if rejected := eventsNamed(t, logs, EvMoveToRejected); len(rejected) != 0 {
		t.Fatalf("a frame from an unknown sender was answered: %+v", rejected)
	}
}

// TestAFrameFromASuspendedPlayersOldConnectionIsDropped is the same branch
// reached the way M2a made it reachable in practice.
//
// A suspension takes the socket out of byConn while leaving the player in the
// world, so this is the one case where the world knows the player perfectly
// well and still must not act on the frame: the connection speaking is one it
// has already given up on, and honouring it would let a half-dead socket move a
// body that a resumed client believes it is driving.
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
	if w.order[0].walking() {
		t.Fatal("the suspended body took a walk from its own dead socket")
	}
}
