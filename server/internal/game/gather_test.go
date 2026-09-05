package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestGatherRangeCoversTheSpotUnderfoot(t *testing.T) {
	if GatherRange < MinPathLength {
		t.Fatalf("GatherRange %v is below MinPathLength %v", GatherRange, MinPathLength)
	}
}

func TestGatherFromOutOfRangeAssignsPathAndPending(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithAxe()
	node := pw.seedTree()

	pw.gather(alice, node.id)

	if alice.gatherNode != node.id {
		t.Fatalf("gatherNode=%d, want %d", alice.gatherNode, node.id)
	}
	if alice.gatherProgress != 0 {
		t.Fatalf("gatherProgress=%d before any step, want 0", alice.gatherProgress)
	}
	if !alice.walking() {
		t.Fatal("gather from spawn assigned no path")
	}
	if len(alice.remaining) != 1 || alice.remaining[0].X != SeedTreeX || alice.remaining[0].Z != SeedTreeZ {
		t.Fatalf("remaining=%v, want a walk ending at the tree", alice.remaining)
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
	alice := pw.joinWithAxe()
	node := pw.seedTree()

	pw.gather(alice, node.id)
	for i := 0; i < 40 && (alice.gatherNode != 0 || alice.walking()); i++ {
		pw.w.step()
	}
	if alice.walking() {
		t.Fatal("walker never finished the path to the tree")
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
	alice := pw.joinWithAxe()
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

func TestGatherYieldsAfterDurationWithAxe(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithAxe()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}

	pw.gather(alice, node.id)
	if alice.walking() {
		t.Fatal("underfoot gather assigned a path")
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

func TestGatherWithoutAxeIsRefused(t *testing.T) {
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
	if rejected[0]["reason"] != string(mnet.ReasonNeedsAxe) {
		t.Fatalf("reason=%v, want %s", rejected[0]["reason"], mnet.ReasonNeedsAxe)
	}
}

func TestContestedGatherYieldsOnce(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithAxe()
	bob := pw.joinWithAxe()
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
	alice := pw.joinWithAxe()
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

func TestMoveToCancelsPendingGather(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithAxe()
	node := pw.seedTree()
	alice.pos = Point{X: SeedTreeX, Z: SeedTreeZ}
	pw.gather(alice, node.id)
	pw.w.step()
	if alice.gatherProgress != 1 {
		t.Fatalf("gatherProgress=%d after one tick, want 1", alice.gatherProgress)
	}

	pw.w.moveTo(alice, mnet.MoveTo{X: 1, Z: 1}, 0)

	if alice.gatherNode != 0 || alice.gatherProgress != 0 {
		t.Fatalf("pending gather survived move_to: node=%d progress=%d", alice.gatherNode, alice.gatherProgress)
	}
	if got := pw.events(EvGatherCancelled); len(got) != 1 {
		t.Fatalf("logged %d %s, want 1", len(got), EvGatherCancelled)
	}
	if bag := countKind(pw.w.items.Inventory(alice.id), KindLogs); bag != 0 {
		t.Fatalf("cancelled gather still yielded %d logs", bag)
	}
}

type gatherProbe struct {
	*probeWorld
}

func newGatherProbe(t *testing.T) *gatherProbe {
	t.Helper()
	pw := newProbeWorld(t)
	pw.w.joinKit = DefaultJoinKit
	return &gatherProbe{probeWorld: pw}
}

func (pw *gatherProbe) seedTree() *resourceNode {
	pw.t.Helper()
	if err := pw.w.SeedResourceNode(KindTree, SeedTreeX, SeedTreeZ); err != nil {
		pw.t.Fatalf("seed tree: %v", err)
	}
	return pw.w.nodes[pw.w.nextNodeID]
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

func (pw *gatherProbe) joinWithAxe() *player {
	pw.t.Helper()
	pw.dial("")
	p := pw.w.order[len(pw.w.order)-1]
	if _, err := pw.w.items.EquipInventorySlot(p.id, 0); err != nil {
		pw.t.Fatalf("equip axe: %v", err)
	}
	return p
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
