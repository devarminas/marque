package game

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestParseAdminLine(t *testing.T) {
	t.Parallel()
	cases := []struct {
		line     string
		wantName string
		wantArgs []string
		wantErr  mnet.RejectReason
	}{
		{"/help", "help", nil, ""},
		{"help", "help", nil, ""},
		{"  /TP  1  2  3  ", "tp", []string{"1", "2", "3"}, ""},
		{"", "", nil, mnet.ReasonUsage},
		{"   ", "", nil, mnet.ReasonUsage},
		{"/", "", nil, mnet.ReasonUsage},
	}
	for _, tc := range cases {
		name, args, err := ParseAdminLine(tc.line)
		if tc.wantErr != "" {
			if err == nil || err.Reason != tc.wantErr {
				t.Fatalf("ParseAdminLine(%q) err=%v, want %q", tc.line, err, tc.wantErr)
			}
			continue
		}
		if err != nil {
			t.Fatalf("ParseAdminLine(%q): %v", tc.line, err)
		}
		if name != tc.wantName {
			t.Fatalf("ParseAdminLine(%q) name=%q, want %q", tc.line, name, tc.wantName)
		}
		if len(args) != len(tc.wantArgs) {
			t.Fatalf("ParseAdminLine(%q) args=%v, want %v", tc.line, args, tc.wantArgs)
		}
		for i := range args {
			if args[i] != tc.wantArgs[i] {
				t.Fatalf("ParseAdminLine(%q) args=%v, want %v", tc.line, args, tc.wantArgs)
			}
		}
	}
}

func TestAdminACLDefaultDeny(t *testing.T) {
	t.Parallel()
	var acl AdminACL
	if acl.Allowed(1) {
		t.Fatal("empty ACL allowed player 1")
	}
}

func TestAdminUnauthorizedDoesNotRunHandler(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	ran := false
	reg := NewAdminRegistry()
	reg.Register("noop", func(w *World, p *player, args []string) (string, *mnet.RejectError) {
		ran = true
		p.pos = Point{X: 99, Z: 99}
		return "ok", nil
	})
	pw.w.SetAdminRegistry(reg)
	before := alice.pos

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/noop"},
		Seq:  1,
	})

	if ran {
		t.Fatal("unauthorized admin ran handler")
	}
	if alice.pos != before {
		t.Fatalf("unauthorized admin mutated pose %v → %v", before, alice.pos)
	}
	got := pw.events(EvAdmin)
	if len(got) != 1 {
		t.Fatalf("admin audit events=%v, want 1", got)
	}
	if got[0]["result"] != adminResultDeny {
		t.Fatalf("result=%v, want %q", got[0]["result"], adminResultDeny)
	}
	if got[0]["cmd"] != "noop" {
		t.Fatalf("cmd=%v, want noop", got[0]["cmd"])
	}
	if got[0]["reason"] != string(mnet.ReasonUnauthorized) {
		t.Fatalf("reason=%v, want unauthorized", got[0]["reason"])
	}
}

func TestAdminUnknownCommandUsage(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/nope"},
		Seq:  1,
	})

	got := pw.events(EvAdmin)
	if len(got) != 1 {
		t.Fatalf("admin audit events=%v, want 1", got)
	}
	if got[0]["result"] != adminResultError {
		t.Fatalf("result=%v, want %q", got[0]["result"], adminResultError)
	}
	if got[0]["cmd"] != "nope" {
		t.Fatalf("cmd=%v, want nope", got[0]["cmd"])
	}
	if got[0]["reason"] != string(mnet.ReasonUsage) {
		t.Fatalf("reason=%v, want usage", got[0]["reason"])
	}
}

func TestAdminEmptyLineUsage(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "   "},
		Seq:  1,
	})

	got := pw.events(EvAdmin)
	if len(got) != 1 {
		t.Fatalf("admin audit events=%v, want 1", got)
	}
	if got[0]["result"] != adminResultError {
		t.Fatalf("result=%v, want %q", got[0]["result"], adminResultError)
	}
	if got[0]["reason"] != string(mnet.ReasonUsage) {
		t.Fatalf("reason=%v, want usage", got[0]["reason"])
	}
}

func TestAdminAuthorizedStubRunsOnHandleFrame(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.SetAdminACL(AdminACL{Players: map[mnet.PlayerID]struct{}{alice.id: {}}})
	ran := false
	reg := NewAdminRegistry()
	reg.Register("noop", func(w *World, p *player, args []string) (string, *mnet.RejectError) {
		ran = true
		if len(args) != 1 || args[0] != "x" {
			t.Fatalf("args=%v, want [x]", args)
		}
		return "noop ok", nil
	})
	pw.w.SetAdminRegistry(reg)

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/noop x"},
		Seq:  1,
	})

	if !ran {
		t.Fatal("authorized stub did not run")
	}
	got := pw.events(EvAdmin)
	if len(got) != 1 {
		t.Fatalf("admin audit events=%v, want 1", got)
	}
	if got[0]["result"] != adminResultOK {
		t.Fatalf("result=%v, want %q", got[0]["result"], adminResultOK)
	}
	if got[0]["cmd"] != "noop" {
		t.Fatalf("cmd=%v, want noop", got[0]["cmd"])
	}
	args, ok := got[0]["args"].([]any)
	if !ok || len(args) != 1 || args[0] != "x" {
		t.Fatalf("args=%v, want [x]", got[0]["args"])
	}
}

func TestAdminAllowlistIgnoresOtherPlayers(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	pw.w.SetAdminACL(AdminACL{Players: map[mnet.PlayerID]struct{}{alice.id: {}}})
	ran := 0
	reg := NewAdminRegistry()
	reg.Register("noop", func(w *World, p *player, args []string) (string, *mnet.RejectError) {
		ran++
		return "", nil
	})
	pw.w.SetAdminRegistry(reg)

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: bob.conn,
		Msg:  mnet.Admin{Line: "/noop"},
		Seq:  1,
	})
	if ran != 0 {
		t.Fatal("bob ran admin despite allowlist")
	}

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/noop"},
		Seq:  1,
	})
	if ran != 1 {
		t.Fatalf("alice ran=%d, want 1", ran)
	}
}

func TestAdminReplyPrivateToInvoker(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	bobPeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	drainJoin(t, bobPeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
	if alice == nil {
		t.Fatal("alice missing from byConn")
	}

	pw.w.SetAdminACL(AdminACL{Players: map[mnet.PlayerID]struct{}{alice.id: {}}})
	reg := NewAdminRegistry()
	reg.Register("noop", func(w *World, p *player, args []string) (string, *mnet.RejectError) {
		return "noop ran", nil
	})
	pw.w.SetAdminRegistry(reg)

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/noop"},
		Seq:  1,
	})

	got := awaitAdminReply(t, alicePeer.ws, 2*time.Second)
	if got != "ok: noop ran" {
		t.Fatalf("alice admin_reply=%q, want %q", got, "ok: noop ran")
	}
	if text, ok := tryAdminReply(t, bobPeer.ws, 200*time.Millisecond); ok {
		t.Fatalf("bob received admin_reply %q; replies are private to the invoker", text)
	}
}

func TestAdminReplyPrefixesDistinguishDenyAndUsage(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/noop"},
		Seq:  1,
	})
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); got != "deny: unauthorized" {
		t.Fatalf("deny reply=%q, want %q", got, "deny: unauthorized")
	}

	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewAdminRegistry())
	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/nope"},
		Seq:  2,
	})
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); !strings.HasPrefix(got, "usage: ") {
		t.Fatalf("usage reply=%q, want usage: prefix", got)
	}
}

func TestAdminReplyErrorPrefixFromHandler(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	reg := NewAdminRegistry()
	reg.Register("boom", func(w *World, p *player, args []string) (string, *mnet.RejectError) {
		return "", &mnet.RejectError{
			Reason:      mnet.ReasonProtocolError,
			Detail:      "handler exploded",
			Disposition: mnet.ReplyError,
		}
	})
	pw.w.SetAdminRegistry(reg)

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/boom"},
		Seq:  1,
	})
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); got != "error: handler exploded" {
		t.Fatalf("error reply=%q, want %q", got, "error: handler exploded")
	}
	got := pw.events(EvAdmin)
	if len(got) != 1 {
		t.Fatalf("admin audit events=%v, want 1", got)
	}
	if got[0]["result"] != adminResultError {
		t.Fatalf("result=%v, want %q", got[0]["result"], adminResultError)
	}
	if got[0]["cmd"] != "boom" {
		t.Fatalf("cmd=%v, want boom", got[0]["cmd"])
	}
}

func TestAdminAuditOutcomeFields(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	reg := NewAdminRegistry()
	reg.Register("noop", func(w *World, p *player, args []string) (string, *mnet.RejectError) {
		return "done", nil
	})
	pw.w.SetAdminRegistry(reg)

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/noop a b"},
		Seq:  7,
	})
	okEv := pw.events(EvAdmin)
	if len(okEv) != 1 {
		t.Fatalf("ok audit events=%v, want 1", okEv)
	}
	if okEv[0]["t"] == nil {
		t.Fatal("ok audit missing tick t")
	}
	if okEv[0]["player"] != float64(alice.id) {
		t.Fatalf("player=%v, want %d", okEv[0]["player"], alice.id)
	}
	if okEv[0]["cmd"] != "noop" || okEv[0]["result"] != adminResultOK || okEv[0]["seq"] != float64(7) {
		t.Fatalf("ok audit=%v", okEv[0])
	}
	args, ok := okEv[0]["args"].([]any)
	if !ok || len(args) != 2 || args[0] != "a" || args[1] != "b" {
		t.Fatalf("args=%v, want [a b]", okEv[0]["args"])
	}
	if _, hasLine := okEv[0]["line"]; hasLine {
		t.Fatalf("audit must not log raw line: %v", okEv[0])
	}

	pw.logs.Reset()
	pw.w.SetAdminACL(AdminACL{})
	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/noop"},
		Seq:  8,
	})
	denyEv := pw.events(EvAdmin)
	if len(denyEv) != 1 || denyEv[0]["result"] != adminResultDeny {
		t.Fatalf("deny audit=%v, want result=%q", denyEv, adminResultDeny)
	}

	pw.logs.Reset()
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/missing 1"},
		Seq:  9,
	})
	errEv := pw.events(EvAdmin)
	if len(errEv) != 1 || errEv[0]["result"] != adminResultError {
		t.Fatalf("error audit=%v, want result=%q", errEv, adminResultError)
	}
	errArgs, ok := errEv[0]["args"].([]any)
	if !ok || len(errArgs) != 1 || errArgs[0] != "1" {
		t.Fatalf("error args=%v, want [1]", errEv[0]["args"])
	}
	if got := pw.events(EvAdminRejected); len(got) != 0 {
		t.Fatalf("unexpected admin_rejected %v", got)
	}
}

func awaitAdminReply(t *testing.T, ws *websocket.Conn, within time.Duration) string {
	t.Helper()
	body := awaitWireKind(t, ws, mnet.MsgAdminReply, within)
	var reply mnet.AdminReply
	if err := json.Unmarshal(body, &reply); err != nil {
		t.Fatalf("admin_reply: %v: %s", err, body)
	}
	if reply.Text == "" {
		t.Fatalf("admin_reply missing text: %s", body)
	}
	return reply.Text
}

func tryAdminReply(t *testing.T, ws *websocket.Conn, within time.Duration) (string, bool) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		kind, body, ok := readHeartbeatFrame(t, ws, time.Until(deadline))
		if !ok {
			return "", false
		}
		if kind != mnet.MsgAdminReply {
			continue
		}
		var reply mnet.AdminReply
		if err := json.Unmarshal(body, &reply); err != nil {
			t.Fatalf("admin_reply: %v: %s", err, body)
		}
		return reply.Text, true
	}
	return "", false
}
