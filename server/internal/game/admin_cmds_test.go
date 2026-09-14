package game

import (
	"fmt"
	"strings"
	"testing"
	"time"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestAdminGiveHappyPath(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/give sticks 3"},
		Seq:  1,
	})

	if got := countKind(pw.w.items.Inventory(alice.id), KindSticks); got != 3 {
		t.Fatalf("sticks=%d, want 3", got)
	}
	if got := pw.events(EvAdminRejected); len(got) != 0 {
		t.Fatalf("unexpected rejection %v", got)
	}
}

func TestAdminGiveToOtherPlayer(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/give sword 1 " + itoaPlayer(bob.id)},
		Seq:  1,
	})

	if got := countKind(pw.w.items.Inventory(bob.id), KindSword); got != 1 {
		t.Fatalf("bob sword=%d, want 1", got)
	}
	if got := countKind(pw.w.items.Inventory(alice.id), KindSword); got != 0 {
		t.Fatalf("alice sword=%d, want 0", got)
	}
}

func TestAdminGiveUnauthorized(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/give sticks"},
		Seq:  1,
	})

	if got := countKind(pw.w.items.Inventory(alice.id), KindSticks); got != 0 {
		t.Fatalf("unauthorized give sticks=%d, want 0", got)
	}
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); got != "deny: unauthorized" {
		t.Fatalf("reply=%q, want deny: unauthorized", got)
	}
}

func TestAdminGiveBadArgs(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/give"},
		Seq:  1,
	})
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); !strings.HasPrefix(got, "usage: ") {
		t.Fatalf("reply=%q, want usage: prefix", got)
	}
	if got := countKind(pw.w.items.Inventory(alice.id), KindSticks); got != 0 {
		t.Fatalf("bad-args sticks=%d, want 0", got)
	}
}

func TestAdminTPCoordsHappyPath(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/tp 4 5"},
		Seq:  1,
	})

	if alice.pos.X != 4 || alice.pos.Z != 5 {
		t.Fatalf("pose=%v, want (4,5)", alice.pos)
	}
	if got := pw.events(EvAdminRejected); len(got) != 0 {
		t.Fatalf("unexpected rejection %v", got)
	}
}

func TestAdminTPToPlayer(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	bob.pos = Point{X: 7, Z: -3}
	bob.y = 2.5
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/tp " + itoaPlayer(bob.id)},
		Seq:  1,
	})

	if alice.pos != bob.pos || alice.y != bob.y {
		t.Fatalf("alice pose=%v y=%v, want bob %v y=%v", alice.pos, alice.y, bob.pos, bob.y)
	}
}

func TestAdminTPUnauthorized(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
	before := alice.pos
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/tp 1 1"},
		Seq:  1,
	})

	if alice.pos != before {
		t.Fatalf("unauthorized tp mutated pose %v → %v", before, alice.pos)
	}
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); got != "deny: unauthorized" {
		t.Fatalf("reply=%q, want deny: unauthorized", got)
	}
}

func TestAdminTPBadArgs(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
	before := alice.pos
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/tp"},
		Seq:  1,
	})
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); !strings.HasPrefix(got, "usage: ") {
		t.Fatalf("reply=%q, want usage: prefix", got)
	}
	if alice.pos != before {
		t.Fatalf("bad-args tp mutated pose %v → %v", before, alice.pos)
	}
}

func TestAdminSpawnAndHeal(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	alice.pos = Point{X: 2, Z: 2}
	alice.hp = 10
	alice.mana = 5
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())
	beforeNPCs := len(pw.w.npcs)

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/spawn imp"},
		Seq:  1,
	})
	if len(pw.w.npcs) != beforeNPCs+1 {
		t.Fatalf("npcs=%d, want %d", len(pw.w.npcs), beforeNPCs+1)
	}
	imp := pw.w.npcByKind(KindImp)
	if imp == nil {
		t.Fatal("imp not spawned")
	}
	if imp.pos.X != 3 || imp.pos.Z != 2 {
		t.Fatalf("imp pose=%v, want near admin (3,2)", imp.pos)
	}
	if imp.home != imp.pos {
		t.Fatalf("imp home=%v, want spawn pose %v", imp.home, imp.pos)
	}

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/heal"},
		Seq:  2,
	})
	if alice.hp != MaxHP || alice.mana != MaxMana {
		t.Fatalf("hp/mana=%d/%d, want %d/%d", alice.hp, alice.mana, MaxHP, MaxMana)
	}
}

func itoaPlayer(id mnet.PlayerID) string {
	return fmt.Sprintf("%d", id)
}
