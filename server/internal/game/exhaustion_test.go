package game

import (
	"errors"
	"fmt"
	"math"
	"reflect"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestStepCastAndCooldownExhaustionPrecedesMixedBatchMutation(t *testing.T) {
	for _, ability := range []string{"heal", "fireball"} {
		t.Run(ability, func(t *testing.T) {
			w, h, p := ownerWorld(t)
			ownerClass(t, w, p, "mage")
			w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
			p.hp = 50
			w.tick = 4294967290
			before := p.motionState()
			_, err := w.Step([]Command{inputCommand(h, 1, 1, 1, true), actionCommand(h, 2, CastPlayerAction{Ability: ability, Target: h})})
			if !errors.Is(err, ErrTickExhausted) || w.tick != 4294967290 || p.motionState() != before || p.hp != 50 || p.mana != 100 || p.casting() || len(p.cooldowns.readyAt) != 0 || w.transaction != nil || len(w.ownerChanges) != 0 {
				t.Fatalf("error%v tick%d pose%+v hp%d mana%d cast%v cooldown%v", err, w.tick, p.motionState(), p.hp, p.mana, p.casting(), p.cooldowns.readyAt)
			}
		})
	}
}

func TestStepCatalogHorizonLastValidTick(t *testing.T) {
	w, h, p := ownerWorld(t)
	ownerClass(t, w, p, "mage")
	w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	w.tick = 4294967180
	p.hp = 50
	batch, err := w.Step([]Command{actionCommand(h, 1, CastPlayerAction{Ability: "heal", Target: h})})
	if err != nil || batch.Tick != 4294967181 || p.hp != 75 || p.mana != 81 {
		t.Fatalf("last valid err%v tick%d hp%d mana%d", err, batch.Tick, p.hp, p.mana)
	}
	cooldownChange(t, batch, CooldownValue{Ability: "heal", ReadyTick: 4294967218})
	before := p.motionState()
	_, err = w.Step([]Command{inputCommand(h, 2, 1, 0, false)})
	if !errors.Is(err, ErrTickExhausted) || w.tick != 4294967181 || p.motionState() != before || p.hp != 75 || p.mana != 81 {
		t.Fatalf("past boundary err%v tick%d hp%d mana%d", err, w.tick, p.hp, p.mana)
	}
}

func TestStepExistingCastAndCooldownHorizonPrecedesMutation(t *testing.T) {
	for _, which := range []string{"player", "npc", "cooldown"} {
		t.Run(which, func(t *testing.T) {
			w, h, p := ownerWorld(t)
			w.tick = 4294967290
			var n *npc
			switch which {
			case "player":
				p.castRuntime = castRuntime{castAbility: "old", castTotal: 10}
			case "npc":
				if err := w.SeedQuestGiver(); err != nil {
					t.Fatal(err)
				}
				n = w.npcByKind(KindQuestGiver)
				n.castRuntime = castRuntime{castAbility: "old", castTotal: 10}
			case "cooldown":
				p.cooldowns.start("old", 38, w.tick)
			}
			before := p.motionState()
			_, err := w.Step([]Command{inputCommand(h, 1, 1, 0, false)})
			if !errors.Is(err, ErrTickExhausted) || w.tick != 4294967290 || p.motionState() != before || p.castProgress != 0 || (n != nil && n.castProgress != 0) {
				t.Fatalf("existing %s err%v tick%d", which, err, w.tick)
			}
		})
	}
}

func TestGroundAllocationExhaustionReturnsBeforeRemovingInventory(t *testing.T) {
	w, _, p := ownerWorld(t)
	if _, err := w.items.SpawnInventoryItem(p.id, KindLogs); err != nil {
		t.Fatal(err)
	}
	s := w.items.(*memStore)
	s.nextItemID = math.MaxUint32
	item, err := s.DropInventorySlot(p.id, 0, 0, 0)
	if !errors.Is(err, ErrItemHandlesExhausted) || item.ID != 0 || !reflect.DeepEqual(s.Inventory(p.id), []Slot{{Index: 0, Kind: KindLogs}}) || len(s.GroundItems()) != 0 || s.nextItemID != math.MaxUint32 {
		t.Fatalf("drop err%v item%+v bag%v ground%v", err, item, s.Inventory(p.id), s.GroundItems())
	}
	if err = w.SeedGroundItem(KindLogs, 0, 0); !errors.Is(err, ErrItemHandlesExhausted) || len(s.GroundItems()) != 0 {
		t.Fatalf("seed err%v ground%v", err, s.GroundItems())
	}
}

func TestStepGroundReservationPrecedesAllCommands(t *testing.T) {
	for _, which := range []string{"move", "craft", "repeated", "two_slots"} {
		t.Run(which, func(t *testing.T) {
			w, h, p := ownerWorld(t)
			if _, err := w.items.SpawnInventoryItem(p.id, KindLogs); err != nil {
				t.Fatal(err)
			}
			commands := []Command{inputCommand(h, 1, 1, 1, true), actionCommand(h, 1, DropAction{Slot: 0})}
			s := w.items.(*memStore)
			s.nextItemID = math.MaxUint32
			switch which {
			case "craft":
				commands = []Command{actionCommand(h, 1, UseSelfAction{Slot: 0}), actionCommand(h, 2, DropAction{Slot: 0})}
			case "repeated":
				s.nextItemID--
				commands = []Command{actionCommand(h, 1, DropAction{Slot: 0}), actionCommand(h, 2, DropAction{Slot: 0})}
			case "two_slots":
				s.nextItemID--
				if _, err := w.items.SpawnInventoryItem(p.id, KindAcorn); err != nil {
					t.Fatal(err)
				}
				commands = []Command{actionCommand(h, 1, DropAction{Slot: 0}), actionCommand(h, 2, DropAction{Slot: 1})}
			}
			beforeBag := s.Inventory(p.id)
			beforePose := p.motionState()
			beforeID := s.nextItemID
			_, err := w.Step(commands)
			if !errors.Is(err, ErrItemHandlesExhausted) || w.tick != 0 || !reflect.DeepEqual(s.Inventory(p.id), beforeBag) || p.motionState() != beforePose || s.nextItemID != beforeID || len(s.GroundItems()) != 0 || w.transaction != nil {
				t.Fatalf("%s err%v tick%d bag%v id%d", which, err, w.tick, s.Inventory(p.id), s.nextItemID)
			}
		})
	}
}

func TestStepGroundLastIDIsValidAndNeverReused(t *testing.T) {
	w, h, p := ownerWorld(t)
	if _, err := w.items.SpawnInventoryItem(p.id, KindLogs); err != nil {
		t.Fatal(err)
	}
	s := w.items.(*memStore)
	s.nextItemID = math.MaxUint32 - 1
	batch, err := w.Step([]Command{actionCommand(h, 1, DropAction{Slot: 0}), inputCommand(h, 1, 1, 0, false)})
	if err != nil || batch.Tick != 1 || p.pos.X != .12 || len(s.Inventory(p.id)) != 0 || !reflect.DeepEqual(s.GroundItems(), []GroundItem{{ID: math.MaxUint32, Kind: KindLogs}}) {
		t.Fatalf("last ID err%v tick%d x%v ground%v", err, batch.Tick, p.pos.X, s.GroundItems())
	}
	if _, err = s.TakeGroundItem(math.MaxUint32, p.id); err != nil {
		t.Fatal(err)
	}
	_, err = w.Step([]Command{actionCommand(h, 2, DropAction{Slot: 0})})
	if !errors.Is(err, ErrItemHandlesExhausted) || w.tick != 1 || len(s.Inventory(p.id)) != 1 || len(s.GroundItems()) != 0 || s.nextItemID != math.MaxUint32 {
		t.Fatalf("reuse err%v tick%d bag%v", err, w.tick, s.Inventory(p.id))
	}
}

func TestNPCExhaustionPrecedesMultiSeedAndCampMutation(t *testing.T) {
	w, _, _ := ownerWorld(t)
	w.nextNpcID = mnet.PlayerID(math.MaxUint32) - practiceNpcIDBand - 1
	if err := w.SeedPracticeDummies(); !errors.Is(err, ErrNPCHandlesExhausted) || len(w.npcs) != 0 || len(w.npcOrder) != 0 {
		t.Fatalf("dummies err%v npcs%d", err, len(w.npcs))
	}
	if err := w.SeedImpCamp(); !errors.Is(err, ErrNPCHandlesExhausted) || len(w.camps) != 0 || len(w.npcs) != 0 {
		t.Fatalf("camp err%v camps%d npcs%d", err, len(w.camps), len(w.npcs))
	}
	if err := w.SeedQuestGiver(); err != nil {
		t.Fatal(err)
	}
	if w.npcOrder[0] != math.MaxUint32 || w.npcHandleCapacity() != 0 {
		t.Fatalf("last NPC ID %v capacity%d", w.npcOrder, w.npcHandleCapacity())
	}
	if err := w.SeedImpQuestGiver(); !errors.Is(err, ErrNPCHandlesExhausted) || len(w.npcs) != 1 {
		t.Fatalf("reuse err%v npcs%d", err, len(w.npcs))
	}
}

func TestStepCampExhaustionPrecedesMovementAndPendingRemoval(t *testing.T) {
	w, h, p := ownerWorld(t)
	w.nextNpcID = mnet.PlayerID(math.MaxUint32) - practiceNpcIDBand
	c := &camp{content: StarterTownImpCamp, pending: []int64{1}}
	w.camps = append(w.camps, c)
	before := p.motionState()
	_, err := w.Step([]Command{inputCommand(h, 1, 1, 0, false)})
	if !errors.Is(err, ErrNPCHandlesExhausted) || w.tick != 0 || p.motionState() != before || !reflect.DeepEqual(c.pending, []int64{1}) || len(w.npcs) != 0 {
		t.Fatalf("camp err%v tick%d pending%v", err, w.tick, c.pending)
	}
}

func TestNodeExhaustionPreservesLastValidHandle(t *testing.T) {
	w, _, _ := ownerWorld(t)
	w.nextNodeID = math.MaxUint32 - 1
	if err := w.SeedResourceNode(KindTree, 0, 0); err != nil {
		t.Fatal(err)
	}
	if len(w.nodes) != 1 || w.nodeOrder[0] != math.MaxUint32 {
		t.Fatalf("last node %+v", w.nodeOrder)
	}
	if err := w.SeedResourceNode(KindRock, 0, 0); err == nil || len(w.nodes) != 1 || w.nextNodeID != math.MaxUint32 {
		t.Fatalf("exhausted node err%v order%v", err, w.nodeOrder)
	}
}

func TestStepPickupThenDropReservesCapacityBeforePickupMutation(t *testing.T) {
	w, h, p := ownerWorld(t)
	if err := w.SeedGroundItem(KindLogs, 0, 0); err != nil {
		t.Fatal(err)
	}
	s := w.items.(*memStore)
	s.nextItemID = math.MaxUint32
	_, err := w.Step([]Command{actionCommand(h, 1, PickupAction{Item: ItemHandle{Index: 1, Gen: 1}}), actionCommand(h, 2, DropAction{Slot: 0})})
	if !errors.Is(err, ErrItemHandlesExhausted) || w.tick != 0 || p.pending != 0 || len(s.GroundItems()) != 1 || len(s.Inventory(p.id)) != 0 {
		t.Fatalf("pickup/drop err%v tick%d pending%d", err, w.tick, p.pending)
	}
}

func TestStepNPCSpawnReservationPrecedesMixedBatchMutation(t *testing.T) {
	w, h, p := ownerWorld(t)
	w.nextNpcID = mnet.PlayerID(math.MaxUint32) - practiceNpcIDBand
	before := p.motionState()
	_, err := w.Step([]Command{inputCommand(h, 1, 1, 0, false), actionCommand(h, 1, AdminAction{Line: "/spawn imp"})})
	if !errors.Is(err, ErrNPCHandlesExhausted) || w.tick != 0 || p.motionState() != before || len(w.npcs) != 0 {
		t.Fatalf("admin spawn err%v tick%d npcs%d", err, w.tick, len(w.npcs))
	}
}

func TestStepExhaustedHandlesWithoutAllocationsStillAdvance(t *testing.T) {
	w, h, p := ownerWorld(t)
	w.items.(*memStore).nextItemID = math.MaxUint32
	w.nextNpcID = mnet.PlayerID(math.MaxUint32) - practiceNpcIDBand
	batch, err := w.Step([]Command{inputCommand(h, 1, 1, 0, false)})
	if err != nil || batch.Tick != 1 || p.pos.X != .12 {
		t.Fatalf("safe tick err%v tick%d x%v", err, batch.Tick, p.pos.X)
	}
	w.tick = math.MaxUint32 - 2
	batch, err = w.Step(nil)
	if err != nil || batch.Tick != 4294967294 {
		t.Fatalf("last plain tick err%v tick%d", err, batch.Tick)
	}
	_, err = w.Step(nil)
	if !errors.Is(err, ErrTickExhausted) || w.tick != 4294967294 {
		t.Fatalf("plain exhausted err%v tick%d", err, w.tick)
	}
}

func TestStepCampAndAdminShareConservativeNPCReservation(t *testing.T) {
	for _, delay := range []int64{0, 1} {
		t.Run(fmt.Sprint(delay), func(t *testing.T) {
			w, h, p := ownerWorld(t)
			if err := w.SeedQuestGiver(); err != nil {
				t.Fatal(err)
			}
			n := w.npcByKind(KindQuestGiver)
			n.camp = CampStarterTownImps
			content := StarterTownImpCamp
			content.PoolMax = 1
			content.DeathTimerTicks = delay
			c := &camp{content: content}
			w.camps = append(w.camps, c)
			w.nextNpcID = mnet.PlayerID(math.MaxUint32) - practiceNpcIDBand - 1
			before := p.motionState()
			_, err := w.Step([]Command{inputCommand(h, 1, 1, 0, false), actionCommand(h, 1, AdminAction{Line: "/spawn imp"})})
			if !errors.Is(err, ErrNPCHandlesExhausted) || w.tick != 0 || p.motionState() != before || len(w.npcs) != 1 || len(c.pending) != 0 {
				t.Fatalf("delay%d err%v tick%d npcs%d", delay, err, w.tick, len(w.npcs))
			}
		})
	}
}

func TestStepTwoDropsConsumeFinalTwoDistinctIDs(t *testing.T) {
	w, h, p := ownerWorld(t)
	for _, kind := range []string{KindLogs, KindAcorn} {
		if _, err := w.items.SpawnInventoryItem(p.id, kind); err != nil {
			t.Fatal(err)
		}
	}
	s := w.items.(*memStore)
	s.nextItemID = math.MaxUint32 - 2
	batch, err := w.Step([]Command{actionCommand(h, 1, DropAction{Slot: 0}), actionCommand(h, 2, DropAction{Slot: 1})})
	want := []GroundItem{{ID: math.MaxUint32 - 1, Kind: KindLogs}, {ID: math.MaxUint32, Kind: KindAcorn}}
	if err != nil || batch.Tick != 1 || !reflect.DeepEqual(s.GroundItems(), want) || len(s.Inventory(p.id)) != 0 || s.GroundItemCapacity() != 0 {
		t.Fatalf("two drops err%v tick%d ground%v bag%v", err, batch.Tick, s.GroundItems(), s.Inventory(p.id))
	}
}
