package game

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/classdef"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestAdminGiveHappyPath(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
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
	invBody := awaitWireKind(t, alicePeer.ws, "inventory", 2*time.Second)
	var inv mnet.Inventory
	if err := json.Unmarshal(invBody, &inv); err != nil {
		t.Fatalf("inventory: %v: %s", err, invBody)
	}
	if countKind(slotsFromWire(inv), KindSticks) != 3 {
		t.Fatalf("wire inventory sticks missing: %s", invBody)
	}
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); !strings.HasPrefix(got, "ok: ") {
		t.Fatalf("reply=%q, want ok: prefix", got)
	}
	got := pw.events(EvAdmin)
	if len(got) != 1 || got[0]["result"] != adminResultOK {
		t.Fatalf("admin audit=%v, want result=%q", got, adminResultOK)
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

func TestAdminGiveUnknownKindRefused(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())
	before := len(pw.w.items.Inventory(alice.id))

	pw.w.handleFrame(mnet.Event{
		Kind: mnet.EventFrame,
		Conn: alice.conn,
		Msg:  mnet.Admin{Line: "/give not_a_real_item 2"},
		Seq:  1,
	})

	if got := len(pw.w.items.Inventory(alice.id)); got != before {
		t.Fatalf("inventory slots=%d, want unchanged %d", got, before)
	}
	if got := countKind(pw.w.items.Inventory(alice.id), "not_a_real_item"); got != 0 {
		t.Fatalf("unknown kind count=%d, want 0", got)
	}
	got := awaitAdminReply(t, alicePeer.ws, 2*time.Second)
	if !strings.HasPrefix(got, "error: ") {
		t.Fatalf("reply=%q, want error: prefix", got)
	}
	if strings.HasPrefix(got, "ok: ") {
		t.Fatalf("reply=%q, must not be ok:", got)
	}
	if !strings.Contains(got, "unknown kind") {
		t.Fatalf("reply=%q, want unknown kind detail", got)
	}
	evs := pw.events(EvAdmin)
	if len(evs) != 1 || evs[0]["result"] != adminResultError {
		t.Fatalf("admin audit=%v, want result=%q", evs, adminResultError)
	}
	if evs[0]["reason"] != string(mnet.ReasonUnknownItem) {
		t.Fatalf("audit reason=%v, want %q", evs[0]["reason"], mnet.ReasonUnknownItem)
	}
}

func TestAdminTPCoordsHappyPath(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
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
	poseBody := awaitWireKind(t, alicePeer.ws, mnet.MsgPose, 2*time.Second)
	var pose mnet.Pose
	if err := json.Unmarshal(poseBody, &pose); err != nil {
		t.Fatalf("pose: %v: %s", err, poseBody)
	}
	if pose.ID != alice.id || pose.X != 4 || pose.Z != 5 {
		t.Fatalf("wire pose=%+v, want id=%d x=4 z=5", pose, alice.id)
	}
	if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); !strings.HasPrefix(got, "ok: ") {
		t.Fatalf("reply=%q, want ok: prefix", got)
	}
	got := pw.events(EvAdmin)
	if len(got) != 1 || got[0]["result"] != adminResultOK {
		t.Fatalf("admin audit=%v, want result=%q", got, adminResultOK)
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
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
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
	spawnBody := awaitWireKind(t, alicePeer.ws, "npc_spawn", 2*time.Second)
	var spawn mnet.NpcSpawn
	if err := json.Unmarshal(spawnBody, &spawn); err != nil {
		t.Fatalf("npc_spawn: %v: %s", err, spawnBody)
	}
	if spawn.Kind != KindImp {
		t.Fatalf("npc_spawn kind=%q, want %q", spawn.Kind, KindImp)
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
	hpBody := awaitWireKind(t, alicePeer.ws, "hp", 2*time.Second)
	var hp mnet.HP
	if err := json.Unmarshal(hpBody, &hp); err != nil {
		t.Fatalf("hp: %v: %s", err, hpBody)
	}
	if hp.ID != alice.id || hp.HP != MaxHP {
		t.Fatalf("wire hp=%+v, want id=%d hp=%d", hp, alice.id, MaxHP)
	}
}

func TestAdminGiveAllClassKitKinds(t *testing.T) {
	pw := newProbeWorld(t)
	alicePeer := dialHeartbeat(t, pw.w, pw.hub, pw.srv)
	drainJoin(t, alicePeer.ws)
	alice := pw.w.byConn[alicePeer.conn]
	pw.w.SetAdminACL(AdminACL{DevAdmin: true})
	pw.w.SetAdminRegistry(NewDefaultAdminRegistry())

	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	wearables, err := classes.Wearables()
	if err != nil {
		t.Fatalf("Wearables: %v", err)
	}
	kinds := make([]string, 0, len(wearables))
	for kind := range wearables {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	if len(kinds) == 0 {
		t.Fatal("expected sets-derived wearable kinds")
	}
	if len(kinds) > InventorySize {
		t.Fatalf("%d kit kinds exceed InventorySize %d", len(kinds), InventorySize)
	}

	for i, kind := range kinds {
		pw.w.handleFrame(mnet.Event{
			Kind: mnet.EventFrame,
			Conn: alice.conn,
			Msg:  mnet.Admin{Line: "/give " + kind},
			Seq:  mnet.Seq(i + 1),
		})
		if got := awaitAdminReply(t, alicePeer.ws, 2*time.Second); !strings.HasPrefix(got, "ok: ") {
			t.Fatalf("give %s reply=%q, want ok: prefix", kind, got)
		}
		if got := countKind(pw.w.items.Inventory(alice.id), kind); got != 1 {
			t.Fatalf("after give %s count=%d, want 1", kind, got)
		}
	}
	got := pw.events(EvAdmin)
	if len(got) != len(kinds) {
		t.Fatalf("admin audit count=%d, want %d", len(got), len(kinds))
	}
	for i, ev := range got {
		if ev["result"] != adminResultOK || ev["cmd"] != "give" {
			t.Fatalf("audit[%d]=%v, want give/ok", i, ev)
		}
	}
	if len(DefaultJoinKit) != 0 {
		t.Fatalf("DefaultJoinKit=%v, want empty", DefaultJoinKit)
	}
}

func itoaPlayer(id mnet.PlayerID) string {
	return fmt.Sprintf("%d", id)
}

func slotsFromWire(inv mnet.Inventory) []Slot {
	out := make([]Slot, 0, len(inv.Slots))
	for _, s := range inv.Slots {
		out = append(out, Slot{Index: s.Slot, Kind: s.Kind})
	}
	return out
}
