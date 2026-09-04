package game

// The suspension lifecycle: the grace boundary tick by tick, and which socket
// death suspends rather than retires.
//
// Written by M2a's second verifier and adopted verbatim; the assertions are
// theirs. In-package, and driven through World.handle and World.step by hand
// so that a tick boundary is exact rather than raced.

import (
	"bytes"
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

const probeGrace = 4

type probeWorld struct {
	t    *testing.T
	w    *World
	logs *bytes.Buffer
	hub  *mnet.Hub
	srv  *httptest.Server
}

func newProbeWorld(t *testing.T) *probeWorld {
	t.Helper()
	logs := &bytes.Buffer{}
	hub := mnet.NewHub()
	w := NewWorld(hub, gamelog.New(logs, true), NewMemoryStore(), probeGrace, nil)
	srv := httptest.NewServer(hub)
	t.Cleanup(func() {
		hub.Close()
		srv.Close()
	})
	return &probeWorld{t: t, w: w, logs: logs, hub: hub, srv: srv}
}

// dial opens a real socket, optionally presenting a token, and hands the hub's
// connected event to the world.
func (pw *probeWorld) dial(token string) *mnet.Conn {
	pw.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	target := "ws" + strings.TrimPrefix(pw.srv.URL, "http")
	if token != "" {
		target += "?" + mnet.SessionParam + "=" + token
	}
	ws, _, err := websocket.Dial(ctx, target, nil)
	if err != nil {
		pw.t.Fatalf("dial %s: %v", target, err)
	}
	pw.t.Cleanup(func() { _ = ws.CloseNow() })

	select {
	case ev := <-pw.hub.Events():
		if ev.Kind != mnet.EventConnected {
			pw.t.Fatalf("hub emitted %v, want connected", ev.Kind)
		}
		pw.w.handle(ev)
		return ev.Conn
	case <-time.After(5 * time.Second):
		pw.t.Fatal("no connected event within 5s")
		return nil
	}
}

func (pw *probeWorld) disconnect(conn *mnet.Conn, reason, detail string) {
	pw.w.handle(mnet.Event{Kind: mnet.EventDisconnected, Conn: conn, Reason: reason, Detail: detail})
}

func (pw *probeWorld) stepN(n int) {
	for range n {
		pw.w.step()
	}
}

func (pw *probeWorld) events(name string) []map[string]any {
	pw.t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(pw.logs.String(), "\n") {
		if !strings.HasPrefix(line, gamelog.Prefix) {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, gamelog.Prefix)), &ev); err != nil {
			pw.t.Fatalf("bad log line %q: %v", line, err)
		}
		if ev["ev"] == name {
			out = append(out, ev)
		}
	}
	return out
}

// checkIndexes is the invariant every transition must preserve: players, order
// and bySession agree on the set of players, and byConn holds exactly the
// connected ones.
func (pw *probeWorld) checkIndexes(where string) {
	pw.t.Helper()
	w := pw.w
	if len(w.players) != len(w.order) || len(w.bySession) != len(w.order) {
		pw.t.Fatalf("%s: players=%d order=%d bySession=%d", where, len(w.players), len(w.order), len(w.bySession))
	}
	connected := 0
	for _, p := range w.order {
		if w.players[p.id] != p {
			pw.t.Fatalf("%s: players[%d] is not the player in order", where, p.id)
		}
		if w.bySession[p.session] != p {
			pw.t.Fatalf("%s: bySession misses player %d", where, p.id)
		}
		if p.conn != nil {
			connected++
			if w.byConn[p.conn] != p {
				pw.t.Fatalf("%s: byConn misses connected player %d", where, p.id)
			}
			if p.expiresTick != 0 {
				pw.t.Fatalf("%s: connected player %d has expiresTick %d", where, p.id, p.expiresTick)
			}
		} else if p.expiresTick == 0 {
			pw.t.Fatalf("%s: suspended player %d has no expiresTick", where, p.id)
		}
	}
	if connected != len(w.byConn) {
		pw.t.Fatalf("%s: %d connected players but byConn holds %d", where, connected, len(w.byConn))
	}
}

func TestProbeResumeOnTheLastTickOfTheGrace(t *testing.T) {
	pw := newProbeWorld(t)
	conn := pw.dial("")
	p := pw.w.order[0]
	token := p.session
	pw.checkIndexes("after join")

	pw.disconnect(conn, mnet.DisconnectPeerGone, mnet.DetailReadError)
	pw.checkIndexes("after suspend")
	if p.expiresTick != pw.w.tick+probeGrace {
		t.Fatalf("expiresTick=%d, want tick %d + grace %d", p.expiresTick, pw.w.tick, probeGrace)
	}

	pw.stepN(probeGrace - 1)
	if pw.w.tick != p.expiresTick-1 {
		t.Fatalf("tick=%d, want expiresTick-1=%d", pw.w.tick, p.expiresTick-1)
	}
	if got := pw.events(EvPlayerExpired); len(got) != 0 {
		t.Fatalf("expired one tick early: %+v", got)
	}

	again := pw.dial(token)
	pw.checkIndexes("after resume")
	if pw.w.byConn[again] != p {
		t.Fatalf("resume on the last grace tick did not hand back player %d", p.id)
	}
	if got := pw.events(EvPlayerResumed); len(got) != 1 {
		t.Fatalf("player_resumed logged %d times, want 1", len(got))
	}

	pw.stepN(probeGrace + 2)
	if len(pw.w.order) != 1 || pw.w.order[0] != p {
		t.Fatal("a resumed player was expired by its old expiresTick")
	}
	if got := pw.events(EvPlayerExpired); len(got) != 0 {
		t.Fatalf("a resumed player expired: %+v", got)
	}
}

func TestProbeResumeOneTickAfterExpiry(t *testing.T) {
	pw := newProbeWorld(t)
	conn := pw.dial("")
	p := pw.w.order[0]
	token := p.session
	id := p.id

	pw.disconnect(conn, mnet.DisconnectPeerGone, mnet.DetailReadError)
	pw.stepN(probeGrace)
	pw.checkIndexes("after expiry")

	expired := pw.events(EvPlayerExpired)
	if len(expired) != 1 || expired[0]["player"] != float64(id) {
		t.Fatalf("player_expired: %+v, want one for player %d", expired, id)
	}
	if expired[0]["t"] != float64(p.expiresTick) {
		t.Fatalf("expired at tick %v, want expiresTick %d", expired[0]["t"], p.expiresTick)
	}
	if len(pw.w.order) != 0 || len(pw.w.bySession) != 0 {
		t.Fatalf("expired player still indexed: order=%d bySession=%d", len(pw.w.order), len(pw.w.bySession))
	}

	again := pw.dial(token)
	pw.checkIndexes("after stale resume")
	if got := pw.events(EvResumeUnknown); len(got) != 1 {
		t.Fatalf("resume_unknown logged %d times, want 1", len(got))
	}
	fresh := pw.w.byConn[again]
	if fresh == nil || fresh.id == id || fresh.session == token {
		t.Fatalf("stale token resurrected player: got %+v, old id %d", fresh, id)
	}
	if got := pw.events(EvPlayerResumed); len(got) != 0 {
		t.Fatalf("an expired player was resumed: %+v", got)
	}
}

func TestProbeSecondSuspensionRestartsTheGrace(t *testing.T) {
	pw := newProbeWorld(t)
	conn := pw.dial("")
	p := pw.w.order[0]
	token := p.session

	pw.disconnect(conn, mnet.DisconnectPeerGone, mnet.DetailReadError)
	firstExpiry := p.expiresTick
	pw.stepN(2)

	again := pw.dial(token)
	pw.disconnect(again, mnet.DisconnectPeerGone, mnet.DetailReadError)
	pw.checkIndexes("after second suspend")
	if p.expiresTick != pw.w.tick+probeGrace {
		t.Fatalf("second suspension expiresTick=%d, want restarted grace %d", p.expiresTick, pw.w.tick+probeGrace)
	}
	if p.expiresTick <= firstExpiry {
		t.Fatalf("second suspension did not restart the grace: %d <= %d", p.expiresTick, firstExpiry)
	}

	pw.stepN(int(p.expiresTick-pw.w.tick) - 1)
	if len(pw.w.order) != 1 {
		t.Fatal("player expired before the restarted grace ran out")
	}
	pw.stepN(1)
	if len(pw.w.order) != 0 {
		t.Fatal("player did not expire when the restarted grace ran out")
	}
	pw.checkIndexes("after expiry")
}

func TestProbeSlowClientDeathSuspends(t *testing.T) {
	pw := newProbeWorld(t)
	conn := pw.dial("")
	p := pw.w.order[0]

	pw.disconnect(conn, mnet.DisconnectSlow, mnet.DetailSendBufferFull)
	pw.checkIndexes("after slow death")
	if len(pw.w.order) != 1 || !p.suspended() {
		t.Fatalf("slow_client did not suspend: order=%d suspended=%v", len(pw.w.order), p.suspended())
	}
	if got := pw.events(EvPlayerSuspended); len(got) != 1 {
		t.Fatalf("player_suspended logged %d times after slow_client, want 1", len(got))
	}
	if got := pw.events(EvDisconnected); len(got) != 1 || got[0]["reason"] != mnet.DisconnectSlow {
		t.Fatalf("client_disconnected: %+v", got)
	}
}

func TestProbeProtocolErrorDeathRetires(t *testing.T) {
	pw := newProbeWorld(t)
	conn := pw.dial("")

	pw.disconnect(conn, mnet.DisconnectProtocol, "")
	pw.checkIndexes("after protocol_error")
	if len(pw.w.order) != 0 || len(pw.w.players) != 0 || len(pw.w.bySession) != 0 {
		t.Fatalf("protocol_error left the player in the world: order=%d", len(pw.w.order))
	}
	if got := pw.events(EvPlayerSuspended); len(got) != 0 {
		t.Fatalf("protocol_error suspended: %+v", got)
	}
}

func TestProbeServerShutdownRetires(t *testing.T) {
	pw := newProbeWorld(t)
	conn := pw.dial("")

	pw.disconnect(conn, mnet.DisconnectShutdown, "")
	pw.checkIndexes("after shutdown")
	if len(pw.w.order) != 0 {
		t.Fatalf("server_shutdown left %d players", len(pw.w.order))
	}
}
