package game

import (
	"math"
	"reflect"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func actionCommand(h PlayerHandle, seq uint32, action Action) Command {
	return ActionCommand{Player: h, Origin: Origin{Source: OriginIntent, Seq: seq}, Action: action}
}
func inputCommand(h PlayerHandle, seq uint32, dx, dz float64, jump bool) Command {
	return InputCommand{Player: h, Origin: Origin{Source: OriginInput, Seq: seq}, DX: dx, DZ: dz, Jump: jump}
}
func transactionStep(t *testing.T, w *World, commands ...Command) TickBatch {
	t.Helper()
	batch, err := w.Step(commands)
	if err != nil {
		t.Fatal(err)
	}
	if batch.Tick != batch.Frame.Tick || batch.Tick != uint32(w.tick) {
		t.Fatalf("batch/frame/world ticks %d/%d/%d", batch.Tick, batch.Frame.Tick, w.tick)
	}
	for _, change := range batch.OwnerChanges {
		if change.Tick != batch.Tick {
			t.Fatalf("owner change born %d in batch %d", change.Tick, batch.Tick)
		}
	}
	for _, fact := range batch.Presentations {
		if fact.Tick != batch.Tick {
			t.Fatalf("presentation born %d in batch %d", fact.Tick, batch.Tick)
		}
	}
	return batch
}
func cooldownChange(t *testing.T, batch TickBatch, want CooldownValue) {
	t.Helper()
	for _, change := range batch.OwnerChanges {
		if value, ok := change.Value.(CooldownValue); ok && value == want {
			return
		}
	}
	t.Fatalf("no cooldown %+v in %+v", want, batch.OwnerChanges)
}
func TestStepInstantAndBoundaryCooldownKeepCompletedTick(t *testing.T) {
	w, h, p := ownerWorld(t)
	ownerClass(t, w, p, "mage")
	w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	p.hp = 50
	batch := transactionStep(t, w, actionCommand(h, 1, CastPlayerAction{Ability: "heal", Target: h}))
	cooldownChange(t, batch, CooldownValue{Ability: "heal", ReadyTick: 38})
	if p.hp != 75 || p.mana != 81 || batch.Tick != 1 {
		t.Fatalf("instant hp/mana/tick %d/%d/%d", p.hp, p.mana, batch.Tick)
	}
	if len(batch.Presentations) != 1 {
		t.Fatalf("instant facts %+v", batch.Presentations)
	}
	fact := batch.Presentations[0].Value.(CastPhaseValue)
	if fact.Phase != CastResolve || fact.Caster != h || fact.Target != h || fact.Amount != 25 {
		t.Fatalf("instant %+v", fact)
	}
	w, h, p = ownerWorld(t)
	ownerClass(t, w, p, "mage")
	w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	w.tick = 37
	p.cooldowns.start("heal", 38, 0)
	p.hp = 50
	batch = transactionStep(t, w, actionCommand(h, 7, CastPlayerAction{Ability: "heal", Target: h}))
	failures := refusedChanges(batch.OwnerChanges, h)
	if p.hp != 50 || p.mana != 100 || batch.Tick != 38 || len(failures) != 1 {
		t.Fatalf("boundary hp/mana/tick/failures %d/%d/%d/%+v", p.hp, p.mana, batch.Tick, failures)
	}
	value := failures[0].Value.(RefusedValue)
	if value.Reason != ReasonCooldown || value.Origin.Seq != 7 || value.Origin.Action != ActionCastPlayer || value.Detail == "" {
		t.Fatalf("boundary refusal %+v", value)
	}
}
func TestStepDelayedCastAndGracePreserveLiteralDeadlines(t *testing.T) {
	for _, progress := range []int{29, 30} {
		w, h, p := ownerWorld(t)
		ownerClass(t, w, p, "mage")
		w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
		target, err := w.CreateOwner()
		if err != nil {
			t.Fatal(err)
		}
		w.players[mnet.PlayerID(target.Index)].pos = Point{X: 2}
		w.TakeOwnerChanges()
		transactionStep(t, w, actionCommand(h, 1, CastPlayerAction{Ability: "fireball", Target: target}))
		for i := 1; i < progress; i++ {
			transactionStep(t, w)
		}
		batch := transactionStep(t, w, inputCommand(h, 2, 1, 0, false))
		if p.casting() != (progress == 30) || p.pos.X != .12 {
			t.Fatalf("grace before=%d cast=%v progress=%d x=%v", progress, p.casting(), p.castProgress, p.pos.X)
		}
		if progress == 29 {
			if len(batch.Presentations) != 1 || batch.Presentations[0].Value.(CastPhaseValue).Phase != CastCancel {
				t.Fatalf("grace9 %+v", batch.Presentations)
			}
		}
	}
	w, h, p := ownerWorld(t)
	ownerClass(t, w, p, "mage")
	w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	target, err := w.CreateOwner()
	if err != nil {
		t.Fatal(err)
	}
	w.players[mnet.PlayerID(target.Index)].pos = Point{X: 2}
	w.TakeOwnerChanges()
	transactionStep(t, w, actionCommand(h, 1, CastPlayerAction{Ability: "fireball", Target: target}))
	for i := 1; i < 37; i++ {
		transactionStep(t, w)
	}
	batch := transactionStep(t, w)
	cooldownChange(t, batch, CooldownValue{Ability: "fireball", ReadyTick: 113})
	if batch.Tick != 38 || p.casting() || len(batch.Presentations) != 1 || batch.Presentations[0].Value.(CastPhaseValue).Phase != CastResolve {
		t.Fatalf("resolve %+v", batch)
	}
}
func TestStepRootAndJumpPreserveLiteralPhase(t *testing.T) {
	w, h, p := ownerWorld(t)
	ownerClass(t, w, p, "mage")
	w.SetAbilities(mustParseAbilities(t, `{"abilities":[{"id":"fireball","name":"Root","mana_cost":1,"cooldown_ticks":0,"cast_ticks":10,"range":0,"target":"self","locomotion":"rooted","effect":{"kind":"heal","amount":1},"ui":{"hotbar_slot":1,"color":"red"}}]}`))
	batch := transactionStep(t, w, actionCommand(h, 1, CastSelfAction{Ability: "fireball"}), inputCommand(h, 1, 1, 0, false))
	baseline := batch.Frame.OwnerMotion[0]
	if batch.Tick != 1 || p.castProgress != 1 || baseline.Policy.EndTick != 10 || p.pos.X != 0 || p.steerDX != 0 {
		t.Fatalf("root first %+v progress%d", baseline, p.castProgress)
	}
	for i := 1; i < 10; i++ {
		transactionStep(t, w)
	}
	if p.casting() || p.pos.X != 0 {
		t.Fatal("root resolve moved")
	}
	batch = transactionStep(t, w, inputCommand(h, 2, 1, 0, false))
	if batch.Tick != 11 || p.pos.X != .12 {
		t.Fatalf("root release %d/%v", batch.Tick, p.pos.X)
	}
	w, h, p = ownerWorld(t)
	batch = transactionStep(t, w, inputCommand(h, 1, 1, 0, true))
	if batch.Tick != 1 || p.pos.X != .12 || p.y != .168 || p.vy != 4.2 {
		t.Fatalf("jump %d/%v/%v/%v", batch.Tick, p.pos.X, p.y, p.vy)
	}
	batch = transactionStep(t, w, inputCommand(h, 2, 0, 0, true))
	failures := refusedChanges(batch.OwnerChanges, h)
	if len(failures) != 1 || failures[0].Value.(RefusedValue).Origin.Source != OriginInput || failures[0].Value.(RefusedValue).Reason != ReasonIllegalSample {
		t.Fatalf("airborne refusal %+v", failures)
	}
}
func TestStepGatherAndRespawnKeepThreeAndTwentyTicks(t *testing.T) {
	w, h, p := ownerWorld(t)
	ownerClass(t, w, p, "lumberjack")
	if err := w.SeedResourceNode(KindTree, 0, 0); err != nil {
		t.Fatal(err)
	}
	first := transactionStep(t, w, actionCommand(h, 1, GatherAction{Node: NodeHandle{1, 1}}))
	if len(first.Presentations) != 1 || first.Presentations[0].Value != (GatherStartValue{h, NodeHandle{1, 1}}) {
		t.Fatalf("gather start %+v", first.Presentations)
	}
	transactionStep(t, w)
	batch := transactionStep(t, w)
	if batch.Tick != 3 || !w.nodes[1].depleted || w.nodes[1].respawnAt != 23 || len(w.items.Inventory(p.id)) != 1 || p.skillXP["woodcutting"] != 10 {
		t.Fatalf("gather tick%d node%+v inventory%+v XP%d", batch.Tick, w.nodes[1], w.items.Inventory(p.id), p.skillXP["woodcutting"])
	}
	for i := 0; i < 19; i++ {
		transactionStep(t, w)
	}
	if !w.nodes[1].depleted {
		t.Fatal("node respawned before20 ticks")
	}
	batch = transactionStep(t, w)
	if batch.Tick != 23 || w.nodes[1].depleted {
		t.Fatalf("respawn tick%d node%+v", batch.Tick, w.nodes[1])
	}
}
func TestStepPassiveApproachAndExplicitStop(t *testing.T) {
	w, h, p := ownerWorld(t)
	if err := w.SeedGroundItem(KindLogs, 2, 0); err != nil {
		t.Fatal(err)
	}
	transactionStep(t, w, actionCommand(h, 1, PickupAction{Item: ItemHandle{1, 1}}))
	for i := 1; i < 13; i++ {
		transactionStep(t, w)
	}
	if math.Abs(p.pos.X-1.56) > 1e-12 || p.steerDX != 0 || len(w.items.Inventory(p.id)) != 1 {
		t.Fatalf("passive x%v dx%v bag%+v", p.pos.X, p.steerDX, w.items.Inventory(p.id))
	}
	w, h, p = ownerWorld(t)
	if err := w.SeedGroundItem(KindLogs, 2, 0); err != nil {
		t.Fatal(err)
	}
	transactionStep(t, w, actionCommand(h, 1, PickupAction{Item: ItemHandle{1, 1}}))
	transactionStep(t, w, inputCommand(h, 1, 0, 0, false))
	for i := 0; i < 20; i++ {
		transactionStep(t, w)
	}
	if p.pos.X != .12 || p.pending != 1 || p.steerDX != 0 || len(w.items.Inventory(p.id)) != 0 {
		t.Fatalf("stop x%v pending%d dx%v bag%+v", p.pos.X, p.pending, p.steerDX, w.items.Inventory(p.id))
	}
}
func TestStepValidatesWholeBatchBeforeMutation(t *testing.T) {
	w, h, p := ownerWorld(t)
	before := p.motionState()
	for _, commands := range [][]Command{
		{inputCommand(h, 1, 1, 0, true), inputCommand(PlayerHandle{99, 1}, 2, 0, 0, false)},
		{inputCommand(h, 1, 1, 0, true), inputCommand(h, 2, math.NaN(), 0, false)},
		{ReleaseOwnerCommand{h}, inputCommand(h, 2, 0, 0, false)},
		{CreateOwnerCommand{1}, CreateOwnerCommand{1}},
		{ActionCommand{Player: h, Origin: Origin{Source: OriginInput}, Action: RespawnAction{}}},
	} {
		if _, err := w.Step(commands); err == nil {
			t.Fatalf("accepted %+v", commands)
		}
		if w.tick != 0 || p.motionState() != before || len(w.players) != 1 || w.nextID != 1 || w.transaction != nil {
			t.Fatal("invalid batch mutated game")
		}
	}
}
func TestStepLifecycleAndCopiedCompleteFrame(t *testing.T) {
	w, _, p := ownerWorld(t)
	if err := w.SeedResourceNode(KindTree, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := w.SeedPracticeDummies(); err != nil {
		t.Fatal(err)
	}
	if err := w.SeedGroundItem(KindLogs, 3, 0); err != nil {
		t.Fatal(err)
	}
	batch := transactionStep(t, w, CreateOwnerCommand{42})
	if len(batch.Created) != 1 || batch.Created[0].Request != 42 || len(batch.Frame.Entities) != 6 || len(batch.Frame.Owners) != 2 || len(batch.Frame.OwnerMotion) != 2 {
		t.Fatalf("initial frame %+v", batch)
	}
	original := batch.Frame.Entities[0].Vitals.HP
	p.hp = 1
	w.nodes[1].depleted = true
	copied := transactionStep(t, w, ReleaseOwnerCommand{batch.Created[0].Player})
	if batch.Frame.Entities[0].Vitals.HP != original || len(batch.Frame.Entities) != 6 || len(copied.Frame.Entities) != 5 {
		t.Fatal("frame aliases later world")
	}
	foundNode, foundNPC := false, false
	for _, entity := range batch.Frame.Entities {
		switch entity.Handle.(type) {
		case NodeHandle:
			foundNode = true
			if entity.Appearance.Node.Depleted || entity.Appearance.Node.Skill != "woodcutting" || entity.Vitals != nil || entity.Gear != nil || entity.Cast != nil {
				t.Fatalf("node %+v", entity)
			}
		case NPCHandle:
			foundNPC = true
			if entity.Appearance.NPC.DisplayName != "Training Dummy" || entity.Appearance.NPC.Faction == "" || entity.Gear != nil {
				t.Fatalf("npc %+v", entity)
			}
		}
	}
	if !foundNode || !foundNPC {
		t.Fatal("missing domain appearances")
	}
	inventory := batch.Frame.Owners[0].Values[0].(InventoryValue)
	if !reflect.DeepEqual(inventory, w.inventoryValue(p)) {
		t.Fatal("full owner inventory mismatch")
	}
}

func TestStepCopiedNestedOwnerGearAndDialogDoNotAlias(t *testing.T) {
	w, h, p := ownerWorld(t)
	ownerClass(t, w, p, "mage")
	w.SetQuests(mustLoadQuests(t))
	if _, err := w.items.SpawnInventoryItem(p.id, KindLogs); err != nil {
		t.Fatal(err)
	}
	if err := w.SeedQuestGiver(); err != nil {
		t.Fatal(err)
	}
	giver := w.npcByKind(KindQuestGiver)
	p.pos = giver.pos
	batch := transactionStep(t, w, actionCommand(h, 1, TalkAction{NPC: NPCHandle{uint32(giver.id), 1}}))
	owner := batch.Frame.Owners[0]
	bag := owner.Values[0].(InventoryValue)
	equipment := owner.Values[1].(EquipmentValue)
	if len(bag.Slots) != 1 || len(equipment.Slots) == 0 || len(batch.Frame.Entities[0].Gear.Slots) == 0 {
		t.Fatal("copy control did not contain nested mutable values")
	}
	originalBag := bag.Slots[0].Kind
	originalEquipment := equipment.Slots[0].Kind
	originalGear := batch.Frame.Entities[0].Gear.Slots[0].Kind
	var dialog DialogValue
	for _, value := range owner.Values {
		if d, ok := value.(DialogValue); ok {
			dialog = d
		}
	}
	if len(dialog.Lines) == 0 || len(dialog.Options) == 0 {
		t.Fatal("copy control did not open a dialog")
	}
	originalLine, originalOption := dialog.Lines[0], dialog.Options[0]
	bag.Slots[0].Kind = "publication mutation"
	equipment.Slots[0].Kind = "publication mutation"
	dialog.Lines[0] = "publication mutation"
	dialog.Options[0] = "publication mutation"
	if batch.Frame.Entities[0].Gear.Slots[0].Kind != originalGear {
		t.Fatal("owner equipment aliases frame gear")
	}
	for _, change := range batch.OwnerChanges {
		if value, ok := change.Value.(DialogValue); ok && (value.Lines[0] != originalLine || value.Options[0] != originalOption) {
			t.Fatal("owner frame aliases emitted dialog")
		}
	}
	next := transactionStep(t, w)
	nextOwner := next.Frame.Owners[0]
	if nextOwner.Values[0].(InventoryValue).Slots[0].Kind != originalBag || nextOwner.Values[1].(EquipmentValue).Slots[0].Kind != originalEquipment {
		t.Fatal("published arrays alias authoritative store")
	}
	found := false
	for _, value := range nextOwner.Values {
		if d, ok := value.(DialogValue); ok {
			found = true
			if d.Lines[0] != originalLine || d.Options[0] != originalOption {
				t.Fatal("published dialog arrays alias future export")
			}
		}
	}
	if !found {
		t.Fatal("next frame lost active dialog")
	}
	if _, err := w.items.DropInventorySlot(p.id, 0, p.pos.X, p.pos.Z); err != nil {
		t.Fatal(err)
	}
	if _, err := w.items.UnequipWornSlot(p.id, mnet.EquipSlot(equipment.Slots[0].Slot)); err != nil {
		t.Fatal(err)
	}
	w.closeDialog(p)
	w.TakeOwnerChanges()
	last := transactionStep(t, w)
	if nextOwner.Values[0].(InventoryValue).Slots[0].Kind != originalBag || nextOwner.Values[1].(EquipmentValue).Slots[0].Kind != originalEquipment || next.Frame.Entities[0].Gear.Slots[0].Kind != originalGear {
		t.Fatal("later store mutation changed frozen nested export")
	}
	for _, value := range last.Frame.Owners[0].Values {
		if _, ok := value.(DialogValue); ok {
			t.Fatal("closed dialog remains in complete owner snapshot")
		}
	}
}
func TestStepMissingMaterialRefusalCarriesTypedContext(t *testing.T) {
	w, h, p := ownerWorld(t)
	if _, err := w.items.SpawnInventoryItem(p.id, KindCopperBar); err != nil {
		t.Fatal(err)
	}
	batch := transactionStep(t, w, actionCommand(h, 9, UseSelfAction{Slot: 0}))
	failures := refusedChanges(batch.OwnerChanges, h)
	if len(failures) != 1 {
		t.Fatalf("refusal %+v", failures)
	}
	value := failures[0].Value.(RefusedValue)
	if value.Reason != ReasonMissingMat || value.Origin.Action != ActionUseSelf || value.Origin.Seq != 9 || value.MissingMaterial != KindSticks || value.Detail != "missing sticks" {
		t.Fatalf("material context %+v", value)
	}
	if w.items.Inventory(p.id)[0].Kind != KindCopperBar {
		t.Fatal("refused craft consumed material")
	}
}
func TestStepPendingLegacyFactsCannotBeRestamped(t *testing.T) {
	w, h, _ := ownerWorld(t)
	if err := w.ApplyAction(h, Origin{Source: OriginIntent, Seq: 1}, AdminAction{Line: "/help"}); err != nil {
		t.Fatal(err)
	}
	if _, err := w.Step(nil); err != ErrPendingChanges || w.tick != 0 {
		t.Fatalf("pending legacy facts were admitted %v tick%d", err, w.tick)
	}
	facts := w.TakeOwnerChanges()
	if len(facts) == 0 || facts[0].Tick != 0 {
		t.Fatalf("old facts were retagged %+v", facts)
	}
	transactionStep(t, w)
}
