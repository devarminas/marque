package intents_test

import (
	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/eventstream"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/gamelog"
	"github.com/devarminas/marque/server/internal/intents"
	"github.com/devarminas/marque/server/internal/netsim"
	"github.com/devarminas/marque/server/internal/questdef"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"io"
	"reflect"
	"testing"
)

type successOwner struct {
	plan   eventstream.ResumePlan
	pair   *pair
	events []wire.EventsMsg
	id     eventstream.SessionID
}
type successWorld struct {
	w      *game.World
	s      *eventstream.Sessions
	tick   uint32
	owners []*successOwner
}

func successFixture(t *testing.T, kit []string, count int) *successWorld {
	t.Helper()
	classes, e := classdef.LoadAll()
	classes = must(t, classes, e)
	wearables, e := classes.Wearables()
	wearables = must(t, wearables, e)
	w := game.NewWorld(idleTransport{}, gamelog.New(io.Discard, false), game.NewMemoryStore(wearables), 1500, kit)
	w.SetMap(game.MapConfig{ID: "success", HalfExtent: 100})
	w.SetClasses(classes)
	quests, e := questdef.Load("../../../shared/quests.json", classes)
	quests = must(t, quests, e)
	w.SetQuests(quests)
	s, e := eventstream.New(eventstream.DefaultConfig())
	s = must(t, s, e)
	h := &successWorld{w: w, s: s}
	for i := 0; i < count; i++ {
		player, e := w.CreateOwner()
		player = must(t, player, e)
		id := eventstream.SessionID(i + 7)
		if e = s.Create(id, 9, eventstream.StreamID(88+i), player, 0); e != nil {
			t.Fatal(e)
		}
		plan, e := s.Attach(id, 9, 0)
		plan = must(t, plan, e)
		h.owners = append(h.owners, &successOwner{plan: plan, pair: newPair(t, netsim.Clean, 357), id: id})
	}
	h.publish(t)
	return h
}
func (h *successWorld) publish(t *testing.T) {
	t.Helper()
	if e := h.s.AppendAt(h.tick, h.w.TakeOwnerChanges()); e != nil {
		t.Fatal(e)
	}
	for _, o := range h.owners {
		if _, e := h.s.CloseTick(o.id, o.plan.Epoch, h.tick, 0, o.pair.ss); e != nil {
			t.Fatal(e)
		}
		for i := 0; i < 12; i++ {
			o.pair.turn(t, func([]byte) { t.Fatal("unexpected intent") }, func(b []byte) {
				m, e := wire.DecodeEvents(b)
				if e != nil {
					t.Fatal(e)
				}
				o.events = append(o.events, m)
			})
		}
	}
}
func (h *successWorld) advance() { h.tick = h.w.AdvanceTick() }
func (h *successWorld) action(t *testing.T, index int, msg wire.IntentsMsg) {
	t.Helper()
	o := h.owners[index]
	b, e := msg.Append(nil)
	if e != nil {
		t.Fatal(e)
	}
	if e = o.pair.cs.Send(b); e != nil {
		t.Fatal(e)
	}
	handled := false
	o.pair.turn(t, func(b []byte) {
		m, e := wire.DecodeIntents(b)
		if e != nil {
			t.Fatal(e)
		}
		if e = intents.Apply(h.w, h.s, o.id, o.plan.Epoch, m); e != nil {
			t.Fatal(e)
		}
		handled = true
	}, func(b []byte) {
		m, e := wire.DecodeEvents(b)
		if e != nil {
			t.Fatal(e)
		}
		o.events = append(o.events, m)
	})
	if !handled {
		t.Fatal("action did not cross transport")
	}
}
func last[T any](t *testing.T, events []wire.EventsMsg) T {
	t.Helper()
	for i := len(events) - 1; i >= 0; i-- {
		if v, ok := any(events[i]).(T); ok {
			return v
		}
	}
	t.Fatalf("missing success event %T", *new(T))
	return *new(T)
}
func TestChangingEquipmentClassAndSkillsThroughTransport(t *testing.T) {
	h := successFixture(t, []string{"forester_cap", "forester_shirt", "forester_trousers", "lumberjack_axe"}, 1)
	o := h.owners[0]
	initial := last[wire.Equipment](t, o.events)
	var names []string
	for _, v := range initial.Worn().All() {
		names = append(names, v.Name())
	}
	wantNames := []string{"helmet", "left hand", "chest", "right hand", "feet", "trousers"}
	if initial.Tick() != 0 || initial.Stream() != 88 || initial.Slots().Len() != 0 || !reflect.DeepEqual(names, wantNames) {
		t.Fatalf("initial equipment %v names %v", initial, names)
	}
	for slot := uint8(0); slot < 4; slot++ {
		h.advance()
		h.action(t, 0, build(wire.EquipFields{Seq: uint32(slot) + 1, Slot: slot}.Build()))
		h.publish(t)
	}
	equipment := last[wire.Equipment](t, o.events)
	cl := last[wire.Class](t, o.events)
	if equipment.Tick() != 4 || equipment.Stream() != 88 || equipment.Slots().Len() != 5 || cl.Tick() != 4 || cl.ClassId() != "lumberjack" {
		t.Fatalf("changed equipment %v class %v", equipment, cl)
	}
	var occupied []string
	for _, v := range equipment.Slots().All() {
		occupied = append(occupied, v.Slot()+"="+v.Kind())
	}
	if !reflect.DeepEqual(occupied, []string{"helmet=forester_cap", "left hand=lumberjack_axe", "chest=forester_shirt", "right hand=lumberjack_axe", "trousers=forester_trousers"}) {
		t.Fatalf("occupied %v", occupied)
	}
	if e := h.w.SeedResourceNode(game.KindTree, 0, 0); e != nil {
		t.Fatal(e)
	}
	h.advance()
	h.action(t, 0, build(wire.GatherFields{Seq: 5, Node: wire.NodeId{Index: 1, Gen: 1}}.Build()))
	h.publish(t)
	for i := 0; i < 3; i++ {
		h.advance()
		h.publish(t)
	}
	skills := last[wire.Skills](t, o.events)
	var values []string
	for _, v := range skills.Skills().All() {
		if v.Xp() != 0 {
			values = append(values, v.Id())
		}
	}
	xp := skills.Skills().At(4)
	if skills.Tick() != 8 || skills.Stream() != 88 || !reflect.DeepEqual(values, []string{"woodcutting"}) || xp.Id() != "woodcutting" || xp.Xp() != 10 || xp.Level() != 1 {
		t.Fatalf("gather skills %v", skills)
	}
	h.advance()
	h.action(t, 0, build(wire.UnequipFields{Seq: 6, Worn: "left hand"}.Build()))
	h.publish(t)
	cl = last[wire.Class](t, o.events)
	if cl.Tick() != 9 || cl.ClassId() != "" || cl.MissingTools().Len() != 0 || cl.MissingSlots().Len() != 2 || cl.MissingSlots().At(0).Slot() != "left hand" || cl.MissingSlots().At(0).Kind() != "lumberjack_axe" || cl.MissingSlots().At(1).Slot() != "right hand" || cl.MissingSlots().At(1).Kind() != "lumberjack_axe" {
		t.Fatalf("class clear %v", cl)
	}
}
func TestDialogQuestAndClearThroughTransport(t *testing.T) {
	h := successFixture(t, nil, 1)
	if e := h.w.SeedQuestGiver(); e != nil {
		t.Fatal(e)
	}
	h.w.SetAdminACL(game.AdminACL{DevAdmin: true})
	h.w.SetAdminRegistry(game.NewDefaultAdminRegistry())
	h.advance()
	h.action(t, 0, build(wire.AdminFields{Seq: 1, Line: "/tp 0 -4"}.Build()))
	h.publish(t)
	h.advance()
	h.action(t, 0, build(wire.TalkFields{Seq: 2, Npc: wire.NpcId{Index: 1000001, Gen: 1}}.Build()))
	h.publish(t)
	h.advance()
	h.publish(t)
	dialog := last[wire.Dialog](t, h.owners[0].events)
	if dialog.Stream() != 88 || dialog.Tick() != 3 || dialog.Npc() != (wire.NpcId{Index: 1000001, Gen: 1}) || dialog.Lines().Len() != 1 || dialog.Lines().At(0).Text() != "Will you accept Bring Sticks?" || dialog.Options().Len() != 2 || dialog.Options().At(0).Id() != "accept_quest" {
		t.Fatalf("dialog %v", dialog)
	}
	h.advance()
	h.action(t, 0, build(wire.DialogOptionFields{Seq: 3, Npc: wire.NpcId{Index: 1000001, Gen: 1}, Option: "accept_quest"}.Build()))
	h.publish(t)
	quest := last[wire.QuestLog](t, h.owners[0].events)
	clear := last[wire.DialogClear](t, h.owners[0].events)
	if quest.Stream() != 88 || quest.Tick() != 4 || quest.Quests().Len() != 1 || quest.Quests().At(0).Id() != "bring_a_stick" || quest.Quests().At(0).Status() != "active" || quest.Quests().At(0).Title() != "Bring Sticks" || quest.Quests().At(0).Objective() != "Deliver 1 sticks" || clear.Tick() != 4 || clear.Npc() != dialog.Npc() || clear.EventSeq()+1 != quest.EventSeq() {
		t.Fatalf("quest %v clear %v", quest, clear)
	}
}
func TestPartyInviteJoinLeaveAndClearsThroughTransport(t *testing.T) {
	h := successFixture(t, nil, 2)
	a, b := h.owners[0], h.owners[1]
	h.advance()
	h.action(t, 0, build(wire.PartyInviteFields{Seq: 1, Player: wire.PlayerId{Index: 2, Gen: 1}}.Build()))
	h.publish(t)
	invite := last[wire.Invite](t, b.events)
	if invite.Stream() != 89 || invite.Tick() != 1 || invite.From() != (wire.PlayerId{Index: 1, Gen: 1}) {
		t.Fatalf("invite %v", invite)
	}
	h.advance()
	h.action(t, 1, build(wire.PartyAcceptFields{Seq: 1}.Build()))
	h.publish(t)
	for _, o := range []*successOwner{a, b} {
		party := last[wire.Party](t, o.events)
		if party.Tick() != 2 || party.Id() != 1 || party.Leader() != (wire.PlayerId{Index: 1, Gen: 1}) || party.Members().Len() != 2 || party.Members().At(0) != (wire.PlayerId{Index: 1, Gen: 1}) || party.Members().At(1) != (wire.PlayerId{Index: 2, Gen: 1}) {
			t.Fatalf("party %v", party)
		}
	}
	clear := last[wire.InviteClear](t, b.events)
	party := last[wire.Party](t, b.events)
	if clear.Tick() != 2 || clear.Stream() != 89 || clear.EventSeq()+1 != party.EventSeq() {
		t.Fatalf("invite clear %v party %v", clear, party)
	}
	h.advance()
	h.action(t, 1, build(wire.PartyLeaveFields{Seq: 2}.Build()))
	h.publish(t)
	left := last[wire.PartyClear](t, b.events)
	rest := last[wire.Party](t, a.events)
	if left.Tick() != 3 || left.Stream() != 89 || rest.Tick() != 3 || rest.Members().Len() != 1 || rest.Members().At(0) != (wire.PlayerId{Index: 1, Gen: 1}) {
		t.Fatalf("leave %v remaining %v", left, rest)
	}
	h.advance()
	h.action(t, 0, build(wire.PartyInviteFields{Seq: 2, Player: wire.PlayerId{Index: 2, Gen: 1}}.Build()))
	h.publish(t)
	h.advance()
	h.action(t, 1, build(wire.PartyDeclineFields{Seq: 3}.Build()))
	h.publish(t)
	clear = last[wire.InviteClear](t, b.events)
	if clear.Tick() != 5 || clear.Stream() != 89 {
		t.Fatalf("decline %v", clear)
	}
}
func TestDuplicateAndOlderInputPreserveActualStickyDisplacement(t *testing.T) {
	store := game.NewMemoryStore(game.NoWearables)
	w := game.NewWorld(idleTransport{}, gamelog.New(io.Discard, false), store, 1500, []string{"logs"})
	w.SetMap(game.MapConfig{ID: "input", HalfExtent: 100})
	owner, e := w.CreateOwner()
	owner = must(t, owner, e)
	w.TakeOwnerChanges()
	s, e := eventstream.New(eventstream.DefaultConfig())
	s = must(t, s, e)
	if e = s.Create(7, 9, 88, owner, 0); e != nil {
		t.Fatal(e)
	}
	plan, e := s.Attach(7, 9, 0)
	plan = must(t, plan, e)
	p := newPair(t, netsim.Clean, 357)
	samples := []wire.Input{build(wire.InputFields{Seq: 10, Dx: 1}.Build()), build(wire.InputFields{Seq: 10, Dx: 0, Dz: 1}.Build()), build(wire.InputFields{Seq: 9, Dx: 0, Dz: 1}.Build())}
	for i, m := range samples {
		data, e := m.Append(nil)
		if e != nil {
			t.Fatal(e)
		}
		f, e := p.cs.Flush(uint64(i+1), transport.Unreliable{Stamp: uint32(i + 1), Items: [][]byte{data}})
		if e != nil {
			t.Fatal(e)
		}
		for _, packet := range f.Datagrams {
			r, e := p.sr.Receive(packet)
			if e != nil {
				t.Fatal(e)
			}
			for _, item := range r.Unreliable.Items {
				m, e := wire.DecodeInput(item)
				if e != nil {
					t.Fatal(e)
				}
				if e = intents.ApplyInput(w, s, 7, plan.Epoch, m.(wire.Input)); e != nil {
					t.Fatal(e)
				}
			}
		}
	}
	w.AdvanceTick()
	w.AdvanceTick()
	if e = intents.Apply(w, s, 7, plan.Epoch, build(wire.DropFields{Seq: 1, Slot: 0}.Build())); e != nil {
		t.Fatal(e)
	}
	ground := store.GroundItems()
	if len(ground) != 1 || ground[0].X != 0.24 || ground[0].Z != 0 {
		t.Fatalf("duplicate/old wish changed authoritative displacement %+v", ground)
	}
}

func TestResolvedCooldownThroughTransport(t *testing.T) {
	h := successFixture(t, []string{"cloth_hood", "cloth_robe", "cloth_skirt", "staff"}, 2)
	abilities, e := abilitydef.Load("../../../shared/abilities.json")
	abilities = must(t, abilities, e)
	h.w.SetAbilities(abilities)
	for slot := uint8(0); slot < 4; slot++ {
		h.advance()
		h.action(t, 0, build(wire.EquipFields{Seq: uint32(slot) + 1, Slot: slot}.Build()))
		h.publish(t)
	}
	h.advance()
	h.action(t, 0, build(wire.CastPlayerFields{Seq: 5, Ability: "fireball", Target: wire.PlayerId{Index: 2, Gen: 1}}.Build()))
	h.publish(t)
	for i := 0; i < 38; i++ {
		h.advance()
		h.publish(t)
	}
	cooldown := last[wire.Cooldown](t, h.owners[0].events)
	if cooldown.Stream() != 88 || cooldown.EventSeq() != 18 || cooldown.Tick() != 43 || cooldown.Ability() != "fireball" || cooldown.ReadyTick() != 118 {
		t.Fatalf("resolved cooldown %v", cooldown)
	}
}

func TestCombatTargetKindsAndGenerationsThroughTransport(t *testing.T) {
	h := successFixture(t, []string{"cloth_hood", "cloth_robe", "cloth_skirt", "staff"}, 2)
	abilities, e := abilitydef.Load("../../../shared/abilities.json")
	h.w.SetAbilities(must(t, abilities, e))
	if e := h.w.SeedPracticeDummies(); e != nil {
		t.Fatal(e)
	}
	for slot := uint8(0); slot < 4; slot++ {
		h.advance()
		h.action(t, 0, build(wire.EquipFields{Seq: uint32(slot) + 1, Slot: slot}.Build()))
		h.publish(t)
	}
	cases := []wire.IntentsMsg{
		build(wire.AttackPlayerFields{Seq: 5, Target: wire.PlayerId{Index: 1000002, Gen: 1}}.Build()),
		build(wire.AttackNpcFields{Seq: 6, Target: wire.NpcId{Index: 2, Gen: 1}}.Build()),
		build(wire.CastPlayerFields{Seq: 7, Ability: "fireball", Target: wire.PlayerId{Index: 1000002, Gen: 1}}.Build()),
		build(wire.CastNpcFields{Seq: 8, Ability: "fireball", Target: wire.NpcId{Index: 2, Gen: 1}}.Build()),
		build(wire.AttackPlayerFields{Seq: 9, Target: wire.PlayerId{Index: 2, Gen: 2}}.Build()),
		build(wire.AttackNpcFields{Seq: 10, Target: wire.NpcId{Index: 1000002, Gen: 2}}.Build()),
		build(wire.CastPlayerFields{Seq: 11, Ability: "fireball", Target: wire.PlayerId{Index: 2, Gen: 2}}.Build()),
		build(wire.CastNpcFields{Seq: 12, Ability: "fireball", Target: wire.NpcId{Index: 1000002, Gen: 2}}.Build()),
	}
	for i, action := range cases {
		h.advance()
		h.action(t, 0, action)
		h.publish(t)
		refused := last[wire.Refused](t, h.owners[0].events)
		if refused.Stream() != 88 || refused.Tick() != uint32(i+5) || refused.Source() != wire.OriginSourceIntent || refused.Seq() != uint32(i+5) || refused.Reason() != 22 {
			t.Fatalf("target %d refusal %v", i, refused)
		}
	}
	for i := 0; i < 40; i++ {
		h.advance()
		h.publish(t)
	}
	for _, ev := range h.owners[0].events {
		if _, ok := ev.(wire.Cooldown); ok {
			t.Fatalf("invalid typed target started ability %v", ev)
		}
	}
}
