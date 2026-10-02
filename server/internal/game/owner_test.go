package game

import (
	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
	"io"
	"reflect"
	"testing"
)

func ownerWorld(t *testing.T) (*World, PlayerHandle, *player) {
	t.Helper()
	w := NewWorld(idleTransport{}, gamelog.New(io.Discard, false), NewMemoryStore(testWearables(t)), 1500, nil)
	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatal(err)
	}
	w.SetClasses(classes)
	w.SetMap(MapConfig{ID: "owner-test", HalfExtent: 100})
	h, err := w.CreateOwner()
	if err != nil {
		t.Fatal(err)
	}
	w.TakeOwnerChanges()
	return w, h, w.players[mnet.PlayerID(h.Index)]
}
func ownerApply(t *testing.T, w *World, h PlayerHandle, seq uint32, a Action) {
	t.Helper()
	if err := w.ApplyAction(h, Origin{Source: OriginIntent, Seq: seq}, a); err != nil {
		t.Fatal(err)
	}
}
func ownerClass(t *testing.T, w *World, p *player, id string) {
	t.Helper()
	c, ok := w.classes.GetClass(id)
	if !ok {
		t.Fatal(id)
	}
	seen := map[string]bool{}
	for _, kind := range c.Requires {
		if seen[kind] {
			continue
		}
		seen[kind] = true
		s, err := w.items.SpawnInventoryItem(p.id, kind)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = w.items.EquipInventorySlot(p.id, s.Index); err != nil {
			t.Fatal(err)
		}
	}
}
func refusedChanges(changes []OwnerChange, h PlayerHandle) []OwnerChange {
	var out []OwnerChange
	for _, c := range changes {
		if c.Player == h {
			if _, ok := c.Value.(RefusedValue); ok {
				out = append(out, c)
			}
		}
	}
	return out
}
func TestDelayedPickupFullKeepsInitiatingOrigin(t *testing.T) {
	w, h, p := ownerWorld(t)
	for i := 0; i < 28; i++ {
		if _, err := w.items.SpawnInventoryItem(p.id, KindLogs); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.SeedGroundItem(KindLogs, 0, 0); err != nil {
		t.Fatal(err)
	}
	ownerApply(t, w, h, 11, PickupAction{Item: ItemHandle{Index: 1, Gen: 1}})
	ownerApply(t, w, h, 12, AdminAction{Line: "/help"})
	w.AdvanceTick()
	want := []OwnerChange{{Player: h, Tick: 0, Value: RefusedValue{Origin: Origin{Source: OriginIntent, Seq: 12}, Reason: ReasonUnauthorized}}, {Player: h, Tick: 1, Value: RefusedValue{Origin: Origin{Source: OriginIntent, Seq: 11}, Reason: ReasonInventoryFull}}}
	if got := refusedChanges(w.TakeOwnerChanges(), h); !reflect.DeepEqual(got, want) {
		t.Fatalf("delayed refusal %+v want %+v", got, want)
	}
}
func TestDelayedPickupLostKeepsInitiatingOrigin(t *testing.T) {
	w, winner, _ := ownerWorld(t)
	loser, err := w.CreateOwner()
	if err != nil {
		t.Fatal(err)
	}
	w.TakeOwnerChanges()
	if err = w.SeedGroundItem(KindLogs, 0, 0); err != nil {
		t.Fatal(err)
	}
	ownerApply(t, w, winner, 21, PickupAction{Item: ItemHandle{Index: 1, Gen: 1}})
	ownerApply(t, w, loser, 11, PickupAction{Item: ItemHandle{Index: 1, Gen: 1}})
	ownerApply(t, w, loser, 12, AdminAction{Line: "/help"})
	w.TakeOwnerChanges()
	w.AdvanceTick()
	want := []OwnerChange{{Player: loser, Tick: 1, Value: RefusedValue{Origin: Origin{Source: OriginIntent, Seq: 11}, Reason: ReasonUnknownItem}}}
	if got := refusedChanges(w.TakeOwnerChanges(), loser); !reflect.DeepEqual(got, want) {
		t.Fatalf("lost pickup %+v", got)
	}
}
func TestDelayedGatherLostKeepsInitiatingOrigin(t *testing.T) {
	w, winner, p := ownerWorld(t)
	ownerClass(t, w, p, "lumberjack")
	loser, err := w.CreateOwner()
	if err != nil {
		t.Fatal(err)
	}
	ownerClass(t, w, w.players[mnet.PlayerID(loser.Index)], "lumberjack")
	w.TakeOwnerChanges()
	if err = w.SeedResourceNode(KindTree, 0, 0); err != nil {
		t.Fatal(err)
	}
	ownerApply(t, w, winner, 21, GatherAction{Node: NodeHandle{Index: 1, Gen: 1}})
	ownerApply(t, w, loser, 11, GatherAction{Node: NodeHandle{Index: 1, Gen: 1}})
	ownerApply(t, w, loser, 12, AdminAction{Line: "/help"})
	w.TakeOwnerChanges()
	for i := 0; i < 3; i++ {
		w.AdvanceTick()
	}
	want := []OwnerChange{{Player: loser, Tick: 3, Value: RefusedValue{Origin: Origin{Source: OriginIntent, Seq: 11}, Reason: ReasonUnknownNode}}}
	if got := refusedChanges(w.TakeOwnerChanges(), loser); !reflect.DeepEqual(got, want) {
		t.Fatalf("lost gather %+v", got)
	}
}
func TestDelayedStationFailureCapturesOriginBeforeClear(t *testing.T) {
	w, h, p := ownerWorld(t)
	if _, err := w.items.SpawnInventoryItem(p.id, KindCopperOre); err != nil {
		t.Fatal(err)
	}
	if err := w.SeedResourceNode(KindSmelter, 2, 0); err != nil {
		t.Fatal(err)
	}
	ownerApply(t, w, h, 11, UseStationAction{Slot: 0, Node: NodeHandle{Index: 1, Gen: 1}})
	ownerApply(t, w, h, 12, DropAction{Slot: 0})
	w.TakeOwnerChanges()
	w.AdvanceTick()
	want := []OwnerChange{{Player: h, Tick: 1, Value: RefusedValue{Origin: Origin{Source: OriginIntent, Seq: 11}, Reason: ReasonEmptySlot}}}
	if got := refusedChanges(w.TakeOwnerChanges(), h); !reflect.DeepEqual(got, want) {
		t.Fatalf("station refusal %+v", got)
	}
	if p.hasPendingUse() || p.useOrigin != (Origin{}) {
		t.Fatalf("pending use survived %+v", p.useOrigin)
	}
}
func TestCooldownFactUsesActualResolveTick(t *testing.T) {
	w, h, p := ownerWorld(t)
	ownerClass(t, w, p, "mage")
	w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	target, err := w.CreateOwner()
	if err != nil {
		t.Fatal(err)
	}
	w.players[mnet.PlayerID(target.Index)].pos = Point{X: 2}
	w.TakeOwnerChanges()
	ownerApply(t, w, h, 11, CastPlayerAction{Ability: "fireball", Target: target})
	ownerApply(t, w, h, 12, AdminAction{Line: "/help"})
	w.TakeOwnerChanges()
	for i := 0; i < 38; i++ {
		w.AdvanceTick()
	}
	var cooldowns []OwnerChange
	for _, c := range w.TakeOwnerChanges() {
		if _, ok := c.Value.(CooldownValue); ok {
			cooldowns = append(cooldowns, c)
		}
	}
	want := []OwnerChange{{Player: h, Tick: 38, Value: CooldownValue{Ability: "fireball", ReadyTick: 113}}}
	if !reflect.DeepEqual(cooldowns, want) {
		t.Fatalf("cooldown %+v want %+v", cooldowns, want)
	}
	if p.castOrigin != (Origin{}) {
		t.Fatalf("cast origin survived clear %+v", p.castOrigin)
	}
}

func TestTypedCombatTargetsCannotAliasOrStartActions(t *testing.T) {
	w, h, p := ownerWorld(t)
	setupMage(t, w, p)
	target, e := w.CreateOwner()
	if e != nil {
		t.Fatal(e)
	}
	if e := w.SeedPracticeDummies(); e != nil {
		t.Fatal(e)
	}
	n := w.npcs[1000002]
	targetPlayer := w.players[mnet.PlayerID(target.Index)]
	cases := []Action{
		AttackPlayerAction{Target: PlayerHandle{1000002, 1}},
		AttackNPCAction{Target: NPCHandle{target.Index, 1}},
		CastPlayerAction{Ability: "fireball", Target: PlayerHandle{1000002, 1}},
		CastNPCAction{Ability: "fireball", Target: NPCHandle{target.Index, 1}},
		AttackPlayerAction{Target: PlayerHandle{target.Index, 2}},
		AttackNPCAction{Target: NPCHandle{1000002, 2}},
		CastPlayerAction{Ability: "fireball", Target: PlayerHandle{target.Index, 2}},
		CastNPCAction{Ability: "fireball", Target: NPCHandle{1000002, 2}},
	}
	mana := p.mana
	w.TakeOwnerChanges()
	for i, a := range cases {
		ownerApply(t, w, h, uint32(i+1), a)
		got := refusedChanges(w.TakeOwnerChanges(), h)
		if len(got) != 1 || got[0].Value != (RefusedValue{Origin: Origin{Source: OriginIntent, Seq: uint32(i + 1)}, Reason: ReasonUnknownPlayer}) {
			t.Fatalf("target %d changes %+v", i, got)
		}
		if p.attackTarget != 0 || p.castTarget != 0 || p.mana != mana || targetPlayer.hp != 100 || n.hp != DummyMaxHP {
			t.Fatalf("target %d applied action or damage", i)
		}
	}
	ownerApply(t, w, h, 20, CastNPCAction{Ability: "missing", Target: NPCHandle{h.Index, 2}})
	got := refusedChanges(w.TakeOwnerChanges(), h)
	if len(got) != 1 || got[0].Value.(RefusedValue).Reason != ReasonUnknownAbility {
		t.Fatalf("ability precedence %+v", got)
	}
	bare, e := w.CreateOwner()
	if e != nil {
		t.Fatal(e)
	}
	w.TakeOwnerChanges()
	ownerApply(t, w, bare, 1, AttackPlayerAction{Target: PlayerHandle{1000002, 2}})
	got = refusedChanges(w.TakeOwnerChanges(), bare)
	if len(got) != 1 || got[0].Value.(RefusedValue).Reason != ReasonNeedsClass {
		t.Fatalf("attack class precedence %+v", got)
	}
	ownerApply(t, w, bare, 2, CastNPCAction{Ability: "fireball", Target: NPCHandle{h.Index, 2}})
	got = refusedChanges(w.TakeOwnerChanges(), bare)
	if len(got) != 1 || got[0].Value.(RefusedValue).Reason != ReasonNeedsClass {
		t.Fatalf("cast class precedence %+v", got)
	}
	p.hp = 0
	ownerApply(t, w, h, 21, AttackNPCAction{Target: NPCHandle{h.Index, 2}})
	got = refusedChanges(w.TakeOwnerChanges(), h)
	if len(got) != 1 || got[0].Value.(RefusedValue).Reason != ReasonDead {
		t.Fatalf("dead precedence %+v", got)
	}
}
