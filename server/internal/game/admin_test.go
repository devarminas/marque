package game

import (
	"testing"

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
	got := pw.events(EvAdminRejected)
	if len(got) != 1 {
		t.Fatalf("rejection events=%v, want 1", got)
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

	got := pw.events(EvAdminRejected)
	if len(got) != 1 {
		t.Fatalf("rejection events=%v, want 1", got)
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

	got := pw.events(EvAdminRejected)
	if len(got) != 1 {
		t.Fatalf("rejection events=%v, want 1", got)
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
	if got := pw.events(EvAdmin); len(got) != 1 {
		t.Fatalf("admin events=%v, want 1", got)
	}
	if got := pw.events(EvAdminRejected); len(got) != 0 {
		t.Fatalf("unexpected rejection %v", got)
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
