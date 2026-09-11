package game

import (
	"testing"

	"github.com/devarminas/marque/server/internal/classdef"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestGatherRangeCoversTheSpotUnderfoot(t *testing.T) {
	if GatherRange < MinPathLength {
		t.Fatalf("GatherRange %v is below MinPathLength %v", GatherRange, MinPathLength)
	}
}

func TestGatherFromOutOfRangeSteersAndPending(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedTree()

	pw.gather(alice, node.id)

	if alice.gatherNode != node.id {
		t.Fatalf("gatherNode=%d, want %d", alice.gatherNode, node.id)
	}
	if alice.gatherProgress != 0 {
		t.Fatalf("gatherProgress=%d before any step, want 0", alice.gatherProgress)
	}
	if !alice.steering() {
		t.Fatal("gather from spawn assigned no approach steer")
	}
	if got := pw.events(EvPathAssigned); len(got) != 0 {
		t.Fatalf("gather approach must not assign player path, got %v", got)
	}
	if got := pw.events(EvGather); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvGather)
	}
	if bag := countKind(pw.w.items.Inventory(alice.id), KindLogs); bag != 0 {
		t.Fatalf("inventory already holds %d logs before arrival", bag)
	}
}

func TestGatherWalkThenYieldsAfterDuration(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedTree()

	pw.gather(alice, node.id)
	for i := 0; i < 200 && alice.gatherNode != 0; i++ {
		pw.w.step()
	}
	if alice.steering() {
		t.Fatal("approach steer still set after gather finished")
	}
	if alice.gatherNode != 0 {
		t.Fatalf("gatherNode=%d after walk+duration, want 0", alice.gatherNode)
	}
	if bag := countKind(pw.w.items.Inventory(alice.id), KindLogs); bag != 1 {
		t.Fatalf("inventory holds %d logs after walk+duration, want 1", bag)
	}
	if !node.depleted {
		t.Fatal("node stayed full after a completed gather")
	}
	if got := pw.events(EvGatherCancelled); len(got) != 0 {
		t.Fatalf("approach logged %d gather_cancelled, want 0", len(got))
	}
	if got := pw.events(EvGatherResolved); len(got) != 1 {
		t.Fatalf("logged %d gather_resolved, want 1", len(got))
	}
}

func TestGatherLeavingRangeAfterProgressCancels(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}
	pw.gather(alice, node.id)
	pw.w.step()
	if alice.gatherProgress != 1 {
		t.Fatalf("gatherProgress=%d after one tick, want 1", alice.gatherProgress)
	}

	alice.pos = Point{X: 0, Z: 0}
	pw.w.step()
	if alice.gatherNode != 0 || alice.gatherProgress != 0 {
		t.Fatalf("pending gather survived leaving range: node=%d progress=%d", alice.gatherNode, alice.gatherProgress)
	}
	if got := pw.events(EvGatherCancelled); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvGatherCancelled)
	}
}

func TestGatherYieldsAfterDurationWithLumberjack(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}

	pw.gather(alice, node.id)
	if alice.steering() {
		t.Fatal("underfoot gather assigned approach steer")
	}

	for i := 1; i < GatherDurationTicks; i++ {
		pw.w.step()
		if bag := countKind(pw.w.items.Inventory(alice.id), KindLogs); bag != 0 {
			t.Fatalf("yielded on in-range tick %d, want after %d", i, GatherDurationTicks)
		}
		if node.depleted {
			t.Fatalf("node depleted on in-range tick %d", i)
		}
		if alice.gatherProgress != i {
			t.Fatalf("gatherProgress=%d after tick %d", alice.gatherProgress, i)
		}
	}

	pw.w.step()
	if bag := countKind(pw.w.items.Inventory(alice.id), KindLogs); bag != 1 {
		t.Fatalf("inventory holds %d logs after duration, want 1", bag)
	}
	if !node.depleted {
		t.Fatal("node stayed full after a completed gather")
	}
	if alice.gatherNode != 0 {
		t.Fatalf("gatherNode=%d after resolve, want 0", alice.gatherNode)
	}
	if got := pw.events(EvGatherResolved); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvGatherResolved)
	}
	if got := pw.events(EvNodeDepleted); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvNodeDepleted)
	}
}

func TestGatherWithoutAClassIsRefused(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinBare()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}

	pw.gather(alice, node.id)

	if alice.gatherNode != 0 {
		t.Fatalf("gatherNode=%d after refusal, want 0", alice.gatherNode)
	}
	if node.depleted {
		t.Fatal("refused gather depleted the node")
	}
	if bag := countKind(pw.w.items.Inventory(alice.id), KindLogs); bag != 0 {
		t.Fatalf("unequipped gather granted %d logs", bag)
	}
	rejected := pw.events(EvGatherRejected)
	if len(rejected) != 1 {
		t.Fatalf("logged %d %s, want 1", len(rejected), EvGatherRejected)
	}
	if rejected[0]["reason"] != string(mnet.ReasonNeedsClass) {
		t.Fatalf("reason=%v, want %s", rejected[0]["reason"], mnet.ReasonNeedsClass)
	}
}

func TestGatherGrantsWoodcuttingXP(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}

	pw.gather(alice, node.id)
	for range GatherDurationTicks {
		pw.w.step()
	}

	if got := alice.skillXP["woodcutting"]; got != SkillXPGather {
		t.Fatalf("woodcutting xp=%d, want %d", got, SkillXPGather)
	}
	if got := pw.events(EvSkillXP); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvSkillXP)
	}
	if got := pw.events(EvSkillXP)[0]["skill"]; got != "woodcutting" {
		t.Fatalf("skill_xp skill=%v, want woodcutting", got)
	}
	_ = node
}

func TestSkillXPPersistsAcrossUnequip(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}

	pw.gather(alice, node.id)
	for range GatherDurationTicks {
		pw.w.step()
	}
	if alice.skillXP["woodcutting"] != SkillXPGather {
		t.Fatalf("pre-unequip xp=%d, want %d", alice.skillXP["woodcutting"], SkillXPGather)
	}

	for {
		worn := pw.w.items.Worn(alice.id)
		if len(worn) == 0 {
			break
		}
		if _, err := pw.w.items.UnequipWornSlot(alice.id, worn[0].Slot); err != nil {
			t.Fatalf("unequip %q: %v", worn[0].Slot, err)
		}
	}

	res := classdef.ClassOf(pw.w.wornKinds(alice), pw.w.classes)
	if res.Class != nil {
		t.Fatalf("stripped player still active as %q", res.Class.ID)
	}
	if alice.skillXP["woodcutting"] != SkillXPGather {
		t.Fatalf("post-unequip xp=%d, want %d unchanged", alice.skillXP["woodcutting"], SkillXPGather)
	}
	_ = node
}

func TestContestedGatherYieldsOnce(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	bob := pw.joinWithLumberjack()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}
	bob.pos = Point{X: SeedTreeX, Z: SeedTreeZ}

	pw.gather(alice, node.id)
	pw.gather(bob, node.id)

	for range GatherDurationTicks {
		pw.w.step()
	}

	aliceLogs := countKind(pw.w.items.Inventory(alice.id), KindLogs)
	bobLogs := countKind(pw.w.items.Inventory(bob.id), KindLogs)
	if aliceLogs+bobLogs != 1 {
		t.Fatalf("logs alice=%d bob=%d, want exactly one from the depletion", aliceLogs, bobLogs)
	}
	if aliceLogs != 1 {
		t.Fatalf("join-order first completer is alice; alice=%d bob=%d", aliceLogs, bobLogs)
	}
	if got := pw.events(EvGatherResolved); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvGatherResolved)
	}
	if got := pw.events(EvGatherLost); len(got) != 1 {
		t.Fatalf("logged %d %s for the loser, want 1", len(got), EvGatherLost)
	}
}

func TestDepletedNodeRespawnsAfterNodeRespawnTicks(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}
	pw.gather(alice, node.id)
	for range GatherDurationTicks {
		pw.w.step()
	}
	if !node.depleted {
		t.Fatal("node not depleted before respawn wait")
	}

	for range NodeRespawnTicks - 1 {
		pw.w.step()
		if !node.depleted {
			t.Fatal("node respawned before NodeRespawnTicks")
		}
	}
	pw.w.step()
	if node.depleted {
		t.Fatal("node stayed depleted after NodeRespawnTicks")
	}
	if got := pw.events(EvNodeRespawned); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvNodeRespawned)
	}
}

func TestMoveCancelsPendingGather(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}
	pw.gather(alice, node.id)
	pw.w.step()
	if alice.gatherProgress != 1 {
		t.Fatalf("gatherProgress=%d after one tick, want 1", alice.gatherProgress)
	}

	pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 0)

	if alice.gatherNode != 0 || alice.gatherProgress != 0 {
		t.Fatalf("pending gather survived move: node=%d progress=%d", alice.gatherNode, alice.gatherProgress)
	}
	if got := pw.events(EvGatherCancelled); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvGatherCancelled)
	}
	if bag := countKind(pw.w.items.Inventory(alice.id), KindLogs); bag != 0 {
		t.Fatalf("cancelled gather still yielded %d logs", bag)
	}
}

func TestNodeSkillMapsRockToMining(t *testing.T) {
	if got := nodeSkill(KindRock); got != "mining" {
		t.Fatalf("nodeSkill(rock)=%q, want mining", got)
	}
	if got := nodeYield(KindRock); got != KindCopperOre {
		t.Fatalf("nodeYield(rock)=%q, want %s", got, KindCopperOre)
	}
}

func TestMinerGathersRockForCopperOre(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithClass("miner")
	node := pw.seedRock()
	alice.pos = Point{X: SeedRockX, Z: SeedRockZ}

	pw.gather(alice, node.id)
	for range GatherDurationTicks {
		pw.w.step()
	}

	if bag := countKind(pw.w.items.Inventory(alice.id), KindCopperOre); bag != 1 {
		t.Fatalf("inventory holds %d copper_ore after duration, want 1", bag)
	}
	if !node.depleted {
		t.Fatal("rock stayed full after a completed gather")
	}
	if got := alice.skillXP["mining"]; got != SkillXPGather {
		t.Fatalf("mining xp=%d, want %d", got, SkillXPGather)
	}
	if got := pw.events(EvGatherResolved); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvGatherResolved)
	}
	if got := pw.events(EvGatherResolved)[0]["kind"]; got != KindCopperOre {
		t.Fatalf("gather_resolved kind=%v, want %s", got, KindCopperOre)
	}
}

func TestLumberjackRefusedOnRock(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	node := pw.seedRock()
	alice.pos = Point{X: SeedRockX, Z: SeedRockZ}

	pw.gather(alice, node.id)

	if alice.gatherNode != 0 {
		t.Fatalf("gatherNode=%d after refusal, want 0", alice.gatherNode)
	}
	if node.depleted {
		t.Fatal("refused gather depleted the rock")
	}
	if bag := countKind(pw.w.items.Inventory(alice.id), KindCopperOre); bag != 0 {
		t.Fatalf("lumberjack gather granted %d copper_ore", bag)
	}
	rejected := pw.events(EvGatherRejected)
	if len(rejected) != 1 {
		t.Fatalf("logged %d %s, want 1", len(rejected), EvGatherRejected)
	}
	if rejected[0]["reason"] != string(mnet.ReasonNeedsClass) {
		t.Fatalf("reason=%v, want %s", rejected[0]["reason"], mnet.ReasonNeedsClass)
	}
}

func TestMinerRefusedOnTree(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithClass("miner")
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}

	pw.gather(alice, node.id)

	if alice.gatherNode != 0 {
		t.Fatalf("gatherNode=%d after refusal, want 0", alice.gatherNode)
	}
	rejected := pw.events(EvGatherRejected)
	if len(rejected) != 1 {
		t.Fatalf("logged %d %s, want 1", len(rejected), EvGatherRejected)
	}
	if rejected[0]["reason"] != string(mnet.ReasonNeedsClass) {
		t.Fatalf("reason=%v, want %s", rejected[0]["reason"], mnet.ReasonNeedsClass)
	}
}

func TestDepletedRockRespawnsAfterNodeRespawnTicks(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithClass("miner")
	node := pw.seedRock()
	alice.pos = Point{X: SeedRockX, Z: SeedRockZ}
	pw.gather(alice, node.id)
	for range GatherDurationTicks {
		pw.w.step()
	}
	if !node.depleted {
		t.Fatal("rock not depleted before respawn wait")
	}

	for range NodeRespawnTicks - 1 {
		pw.w.step()
		if !node.depleted {
			t.Fatal("rock respawned before NodeRespawnTicks")
		}
	}
	pw.w.step()
	if node.depleted {
		t.Fatal("rock stayed depleted after NodeRespawnTicks")
	}
	if got := pw.events(EvNodeRespawned); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvNodeRespawned)
	}
}

type gatherProbe struct {
	*probeWorld
}

func newGatherProbe(t *testing.T) *gatherProbe {
	t.Helper()
	pw := newProbeWorld(t)
	pw.w.joinKit = DefaultJoinKit
	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatalf("load shared class tables: %v", err)
	}
	pw.w.SetClasses(classes)
	return &gatherProbe{probeWorld: pw}
}

func (pw *gatherProbe) seedTree() *resourceNode {
	pw.t.Helper()
	if err := pw.w.SeedResourceNode(KindTree, SeedTreeX, SeedTreeZ); err != nil {
		pw.t.Fatalf("seed tree: %v", err)
	}
	return pw.w.nodes[pw.w.nextNodeID]
}

func (pw *gatherProbe) seedRock() *resourceNode {
	pw.t.Helper()
	if err := pw.w.SeedResourceNode(KindRock, SeedRockX, SeedRockZ); err != nil {
		pw.t.Fatalf("seed rock: %v", err)
	}
	return pw.w.nodes[pw.w.nextNodeID]
}

func (pw *gatherProbe) joinWithClass(id string) *player {
	pw.t.Helper()
	return (&classProbe{probeWorld: pw.probeWorld}).joinWithClass(id)
}

func (pw *gatherProbe) joinBare() *player {
	pw.t.Helper()
	kit := pw.w.joinKit
	pw.w.joinKit = nil
	conn := pw.dial("")
	_ = conn
	pw.w.joinKit = kit
	return pw.w.order[len(pw.w.order)-1]
}

func (pw *gatherProbe) equipLumberjack(p *player) *player {
	pw.t.Helper()
	kinds := []string{
		"forester_cap",
		"forester_shirt",
		"forester_trousers",
		KindLumberjackAxe,
	}
	for _, kind := range kinds {
		slot, err := pw.w.items.SpawnInventoryItem(p.id, kind)
		if err != nil {
			pw.t.Fatalf("seed %q: %v", kind, err)
		}
		if _, err := pw.w.items.EquipInventorySlot(p.id, slot.Index); err != nil {
			pw.t.Fatalf("equip %q from bag %d: %v", kind, slot.Index, err)
		}
	}
	return p
}

func (pw *gatherProbe) joinWithLumberjack() *player {
	pw.t.Helper()
	p := pw.joinBare()
	return pw.equipLumberjack(p)
}

func (pw *gatherProbe) gather(p *player, node mnet.NodeID) {
	pw.t.Helper()
	pw.w.gather(p, mnet.Gather{Node: node}, 0)
}

func countKind(slots []Slot, kind string) int {
	n := 0
	for _, s := range slots {
		if s.Kind == kind {
			n++
		}
	}
	return n
}
