package game

// The server heartbeat: period on welcome, t values at the tick boundary,
// and a suspended player sent nothing.

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

type heartbeatPeer struct {
	ws   *websocket.Conn
	conn *mnet.Conn
}

func newHeartbeatWorld(t *testing.T) (*World, *httptest.Server, *mnet.Hub) {
	t.Helper()
	hub := mnet.NewHub()
	w := NewWorld(hub, gamelog.New(&strings.Builder{}, true), NewMemoryStore(), ResumeGraceTicks, nil)
	srv := httptest.NewServer(hub)
	t.Cleanup(func() {
		hub.Close()
		srv.Close()
	})
	return w, srv, hub
}

func dialHeartbeat(t *testing.T, w *World, hub *mnet.Hub, srv *httptest.Server) heartbeatPeer {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = ws.CloseNow() })

	select {
	case ev := <-hub.Events():
		if ev.Kind != mnet.EventConnected {
			t.Fatalf("hub emitted %v, want connected", ev.Kind)
		}
		w.handle(ev)
		return heartbeatPeer{ws: ws, conn: ev.Conn}
	case <-time.After(5 * time.Second):
		t.Fatal("no connected event within 5s")
		return heartbeatPeer{}
	}
}

func readHeartbeatFrame(t *testing.T, ws *websocket.Conn, within time.Duration) (kind string, body json.RawMessage, ok bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), within)
	defer cancel()
	typ, data, err := ws.Read(ctx)
	if err != nil {
		return "", nil, false
	}
	if typ != websocket.MessageText {
		t.Fatalf("got a %v frame, want text: %s", typ, data)
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(data, &keys); err != nil {
		t.Fatalf("not a JSON object: %v: %s", err, data)
	}
	if len(keys) != 1 {
		t.Fatalf("frame has %d keys, want 1: %s", len(keys), data)
	}
	for k, v := range keys {
		return k, v, true
	}
	return "", nil, false
}

func drainJoin(t *testing.T, ws *websocket.Conn) mnet.Welcome {
	t.Helper()
	kind, body, ok := readHeartbeatFrame(t, ws, 2*time.Second)
	if !ok || kind != "welcome" {
		t.Fatalf("first frame is %q, want welcome", kind)
	}
	var welcome mnet.Welcome
	if err := json.Unmarshal(body, &welcome); err != nil {
		t.Fatalf("welcome: %v: %s", err, body)
	}
	for {
		kind, _, ok := readHeartbeatFrame(t, ws, 2*time.Second)
		if !ok {
			t.Fatal("join step ended before inventory")
		}
		if kind == "inventory" {
			return welcome
		}
	}
}

func collectTicks(t *testing.T, ws *websocket.Conn, within time.Duration) []int64 {
	t.Helper()
	deadline := time.Now().Add(within)
	var ticks []int64
	for time.Now().Before(deadline) {
		kind, body, ok := readHeartbeatFrame(t, ws, time.Until(deadline))
		if !ok {
			return ticks
		}
		if kind != "tick" {
			continue
		}
		var frame mnet.Tick
		if err := json.Unmarshal(body, &frame); err != nil {
			t.Fatalf("tick: %v: %s", err, body)
		}
		ticks = append(ticks, frame.T)
	}
	return ticks
}

func TestHeartbeatTicksArePeriodMultiplesAfterWelcome(t *testing.T) {
	w, srv, hub := newHeartbeatWorld(t)
	peer := dialHeartbeat(t, w, hub, srv)
	welcome := drainJoin(t, peer.ws)

	if welcome.HeartbeatTicks != HeartbeatEveryTicks {
		t.Fatalf("welcome.heartbeat_ticks=%d, want %d", welcome.HeartbeatTicks, HeartbeatEveryTicks)
	}

	w.stepNForTest(HeartbeatEveryTicks*2 + 5)
	got := collectTicks(t, peer.ws, time.Second)
	if len(got) < 2 {
		t.Fatalf("received %v, want at least two heartbeats", got)
	}
	if got[0] <= welcome.Tick {
		t.Fatalf("first heartbeat t=%d is not greater than welcome.tick=%d", got[0], welcome.Tick)
	}
	for i, tick := range got {
		if tick%HeartbeatEveryTicks != 0 {
			t.Fatalf("heartbeat[%d]=%d is not a multiple of %d", i, tick, HeartbeatEveryTicks)
		}
		if i == 0 {
			continue
		}
		if got[i]-got[i-1] != HeartbeatEveryTicks {
			t.Fatalf("heartbeats %d then %d differ by %d, want %d", got[i-1], tick, tick-got[i-1], HeartbeatEveryTicks)
		}
	}
}

func TestASuspendedPlayerIsSentNoHeartbeat(t *testing.T) {
	w, srv, hub := newHeartbeatWorld(t)
	alice := dialHeartbeat(t, w, hub, srv)
	bob := dialHeartbeat(t, w, hub, srv)
	drainJoin(t, alice.ws)
	drainJoin(t, bob.ws)
	collectTicks(t, alice.ws, 200*time.Millisecond)

	w.handle(mnet.Event{Kind: mnet.EventDisconnected, Conn: alice.conn, Reason: mnet.DisconnectPeerGone, Detail: mnet.DetailReadError})
	if !w.order[0].suspended() {
		t.Fatal("alice is not suspended")
	}

	w.stepNForTest(HeartbeatEveryTicks)
	if got := collectTicks(t, bob.ws, time.Second); len(got) == 0 {
		t.Fatal("the connected player received no heartbeat")
	}
	if got := collectTicks(t, alice.ws, 200*time.Millisecond); len(got) != 0 {
		t.Fatalf("the suspended player was sent %v", got)
	}
}

func (w *World) stepNForTest(n int) {
	for range n {
		w.step()
	}
}
