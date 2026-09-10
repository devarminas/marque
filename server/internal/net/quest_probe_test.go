package net_test

// Thin WS quest probe (ARM-230).
//
// Verify-ladder content rung for quest ids in shared/quests.json. Drives real
// WebSocket intents against the in-process hub and asserts GAMELOG events.
// No Godot. Party kill credit stays in game unit tests (quest_kill_test.go).
//
// From server/:
//
//	go test ./internal/net/ -count=1 -run 'TestQuestProbe'
//
// Example quest id exercised end-to-end (deliver complete): bring_a_stick.
// Kill quests assert accept + quest_kill_progress (softened camp); full turn-in
// and party credit remain Go-unit / live-demo rungs.

import (
	"fmt"
	"sort"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/game"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/questdef"
)

const questProbeTimeout = 45 * time.Second

var knightKit = []string{
	"plate_helm",
	"plate_chest",
	"plate_legs",
	game.KindSword,
	game.KindShield,
}

func mustLoadQuestCatalog(t *testing.T) *questdef.Catalog {
	t.Helper()
	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatalf("load classes: %v", err)
	}
	quests, err := questdef.Load(mustResolveQuests(t), classes)
	if err != nil {
		t.Fatalf("load quests: %v", err)
	}
	return quests
}

func TestQuestProbeByID(t *testing.T) {
	catalog := mustLoadQuestCatalog(t)
	ids := catalog.IDs()
	sort.Strings(ids)
	if len(ids) == 0 {
		t.Fatal("quests.json has no quests")
	}
	for _, id := range ids {
		id := id
		q, ok := catalog.Get(id)
		if !ok {
			t.Fatalf("catalog missing %q", id)
		}
		t.Run(id, func(t *testing.T) {
			probeQuest(t, q)
		})
	}
}

func TestQuestProbeUnknownID(t *testing.T) {
	catalog := mustLoadQuestCatalog(t)
	const missing = "no_such_quest"
	if _, ok := catalog.Get(missing); ok {
		t.Fatalf("catalog unexpectedly has %q", missing)
	}
	err := errProbeQuestID(catalog, missing)
	if err == nil {
		t.Fatal("want error for unknown quest id")
	}
	if got := err.Error(); got != `unknown quest id "no_such_quest"` {
		t.Fatalf("error=%q", got)
	}
}

func errProbeQuestID(catalog *questdef.Catalog, id string) error {
	if _, ok := catalog.Get(id); !ok {
		return fmt.Errorf("unknown quest id %q", id)
	}
	return nil
}

func probeQuest(t *testing.T, q questdef.Quest) {
	t.Helper()
	switch {
	case q.IsDeliver():
		probeDeliverQuest(t, q)
	case q.IsKill():
		probeKillQuest(t, q)
	default:
		t.Fatalf("quest %q has neither deliver nor kill", q.ID)
	}
}

func probeDeliverQuest(t *testing.T, q questdef.Quest) {
	t.Helper()
	if q.Deliver.Kind == "" || q.Deliver.Qty < 1 {
		t.Fatalf("deliver quest %q missing deliver", q.ID)
	}
	kit := make([]string, q.Deliver.Qty)
	for i := range kit {
		kit[i] = q.Deliver.Kind
	}
	h := newHarnessWithKit(t, kit)
	alice := h.dial("alice")
	welcome := alice.welcomeFrame()
	inv := alice.inventory()
	alice.equipment()
	alice.classFrame()
	alice.skillsFrame()
	alice.questLogFrame()

	npc := npcByKind(welcome, q.TalkNPC)
	if npc == 0 {
		t.Fatalf("welcome lacks talk npc kind %q", q.TalkNPC)
	}
	slot := bagSlotOfKind(inv, q.Deliver.Kind)
	if slot < 0 {
		t.Fatalf("bag missing deliver kind %q: %+v", q.Deliver.Kind, inv.Slots)
	}

	acceptQuestOverWire(t, h, alice, npc, q.ID)

	alice.give(npc, slot)
	completed := h.awaitEventsWithin(game.EvQuestCompleted, 1, questProbeTimeout)
	if completed[0]["quest"] != q.ID {
		t.Fatalf("quest_completed=%+v, want quest %q", completed[0], q.ID)
	}
	if completed[0]["consume"] != q.Deliver.Kind {
		t.Fatalf("quest_completed consume=%v, want %q", completed[0]["consume"], q.Deliver.Kind)
	}
	log := alice.awaitQuestLog()
	if len(log.Quests) != 1 || log.Quests[0].ID != q.ID || log.Quests[0].Status != "complete" {
		t.Fatalf("quest_log=%+v", log)
	}
}

func probeKillQuest(t *testing.T, q questdef.Quest) {
	t.Helper()
	if q.Kill.Kind == "" || q.Kill.Qty < 1 {
		t.Fatalf("kill quest %q missing kill", q.ID)
	}
	h := newHarnessWithSetup(t, knightKit, func(w *game.World) {
		if err := w.SeedImpQuestGiver(); err != nil {
			t.Fatalf("seed imp quest giver: %v", err)
		}
		if err := w.SeedImpCamp(); err != nil {
			t.Fatalf("seed imp camp: %v", err)
		}
		// One-hit kills so solo wire progress finishes before the camp swarm.
		if err := w.SetHostileKindHitPoints(q.Kill.Kind, game.AttackDamage); err != nil {
			t.Fatalf("soften kill targets: %v", err)
		}
	})
	alice := h.dial("alice")
	welcome := alice.welcomeFrame()
	inv := alice.inventory()
	alice.equipment()
	alice.classFrame()
	alice.skillsFrame()
	alice.questLogFrame()
	equipKnightFromBag(t, alice, inv)

	npc := npcByKind(welcome, q.TalkNPC)
	if npc == 0 {
		t.Fatalf("welcome lacks talk npc kind %q", q.TalkNPC)
	}
	imp := npcByKind(welcome, q.Kill.Kind)
	if imp == 0 {
		t.Fatalf("welcome lacks kill target kind %q", q.Kill.Kind)
	}

	acceptQuestOverWire(t, h, alice, npc, q.ID)

	alice.attack(imp)
	progress := h.awaitEventsWithin(game.EvQuestKillProgress, 1, questProbeTimeout)
	if progress[0]["quest"] != q.ID {
		t.Fatalf("quest_kill_progress=%+v, want quest %q", progress[0], q.ID)
	}
	count, ok := progress[0]["count"].(float64)
	if !ok || count < 1 {
		t.Fatalf("quest_kill_progress count=%v", progress[0]["count"])
	}
}

func acceptQuestOverWire(t *testing.T, h *harness, c *client, npc mnet.PlayerID, questID string) {
	t.Helper()
	c.talk(npc)
	dialog := c.awaitDialog()
	if dialog.NPC != npc {
		t.Fatalf("dialog npc=%d, want %d", dialog.NPC, npc)
	}
	c.dialogOption(npc, mnet.OptionAcceptQuest)
	_ = c.awaitQuestLog()
	accepted := h.awaitEventsWithin(game.EvQuestAccepted, 1, questProbeTimeout)
	if accepted[0]["quest"] != questID {
		t.Fatalf("quest_accepted=%+v, want quest %q", accepted[0], questID)
	}
}

func equipKnightFromBag(t *testing.T, c *client, inv mnet.Inventory) {
	t.Helper()
	slots := make([]int, 0, len(inv.Slots))
	for _, s := range inv.Slots {
		slots = append(slots, s.Slot)
	}
	for _, slot := range slots {
		c.equip(slot)
		sawClass := false
		deadline := time.Now().Add(readTimeout)
		for time.Now().Before(deadline) {
			f, ok := c.tryNext(time.Until(deadline))
			if !ok {
				break
			}
			switch {
			case f.Inventory != nil, f.Equipment != nil:
			case f.Class != nil:
				sawClass = true
				if f.Class.Class == "knight" {
					return
				}
			case f.Path != nil, f.HP != nil, f.Mana != nil, f.NpcSpawn != nil, f.Despawn != nil, f.Tick != nil:
			default:
				t.Fatalf("unexpected %s during equip: %s", f.kind(), f.raw)
			}
			if sawClass {
				break
			}
		}
	}
	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(50 * time.Millisecond)
		if !ok {
			break
		}
		if f.Class != nil && f.Class.Class == "knight" {
			return
		}
	}
	t.Fatal("failed to reach class knight after equipping kit")
}

func npcByKind(w mnet.Welcome, kind string) mnet.PlayerID {
	for _, n := range w.Npcs {
		if n.Kind == kind {
			return n.ID
		}
	}
	return 0
}

func bagSlotOfKind(inv mnet.Inventory, kind string) int {
	for _, s := range inv.Slots {
		if s.Kind == kind {
			return s.Slot
		}
	}
	return -1
}
