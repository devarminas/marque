package game

import (
	mnet "github.com/devarminas/marque/server/internal/net"
	"testing"
)

type refusalSetup func(*testing.T, *World, PlayerHandle, *player) Action

func setupItem(t *testing.T, w *World, p *player, kind string) {
	t.Helper()
	if _, err := w.items.SpawnInventoryItem(p.id, kind); err != nil {
		t.Fatal(err)
	}
}
func setupGiver(t *testing.T, w *World, p *player, kill bool) NPCHandle {
	t.Helper()
	w.SetQuests(mustLoadQuests(t))
	var err error
	if kill {
		err = w.SeedImpQuestGiver()
	} else {
		err = w.SeedQuestGiver()
	}
	if err != nil {
		t.Fatal(err)
	}
	kind := KindQuestGiver
	if kill {
		kind = KindImpQuestGiver
	}
	n := w.npcByKind(kind)
	p.pos = n.pos
	p.dialogNPC = n.id
	return NPCHandle{uint32(n.id), 1}
}
func setupMage(t *testing.T, w *World, p *player) {
	t.Helper()
	ownerClass(t, w, p, "mage")
	w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
}
func setupParty(w *World, p *player, leader mnet.PlayerID, members ...mnet.PlayerID) {
	w.parties[1] = &party{id: 1, leader: leader, members: members}
	p.partyID = 1
}
func TestReachableOwnerRefusalReasons(t *testing.T) {
	simple := func(a Action) refusalSetup {
		return func(*testing.T, *World, PlayerHandle, *player) Action { return a }
	}
	cases := []struct {
		name   string
		reason RefusalReason
		setup  refusalSetup
	}{
		{"unknown_ability", ReasonUnknownAbility, simple(CastSelfAction{Ability: "missing"})},
		{"no_target", ReasonNoTarget, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupMage(t, w, p)
			return CastSelfAction{Ability: "fireball"}
		}},
		{"wrong_target", ReasonWrongTarget, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupMage(t, w, p)
			return CastPlayerAction{Ability: "fireball", Target: h}
		}},
		{"insufficient_mana", ReasonInsufficientMana, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupMage(t, w, p)
			p.mana = 0
			return CastPlayerAction{Ability: "heal", Target: h}
		}},
		{"out_of_range", ReasonOutOfRange, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupMage(t, w, p)
			target, e := w.CreateOwner()
			if e != nil {
				t.Fatal(e)
			}
			w.players[mnet.PlayerID(target.Index)].pos = Point{X: 50}
			return CastPlayerAction{Ability: "fireball", Target: target}
		}},
		{"cooldown", ReasonCooldown, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupMage(t, w, p)
			p.cooldowns.start("heal", 38, 0)
			return CastPlayerAction{Ability: "heal", Target: h}
		}},
		{"dead", ReasonDead, func(t *testing.T, w *World, h PlayerHandle, p *player) Action { p.hp = 0; return DropAction{Slot: 0} }},
		{"unknown_item", ReasonUnknownItem, simple(PickupAction{Item: ItemHandle{99, 1}})},
		{"no_such_slot", ReasonNoSuchSlot, simple(DropAction{Slot: 99})},
		{"empty_slot", ReasonEmptySlot, simple(DropAction{Slot: 0})},
		{"not_equippable", ReasonNotEquippable, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupItem(t, w, p, KindLogs)
			return EquipAction{Slot: 0}
		}},
		{"no_such_worn_slot", ReasonNoSuchWornSlot, simple(UnequipAction{Worn: "missing"})},
		{"empty_worn_slot", ReasonEmptyWornSlot, simple(UnequipAction{Worn: "helmet"})},
		{"inventory_full", ReasonInventoryFull, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			ownerClass(t, w, p, "mage")
			for i := 0; i < 28; i++ {
				setupItem(t, w, p, KindLogs)
			}
			return UnequipAction{Worn: "helmet"}
		}},
		{"unknown_node", ReasonUnknownNode, simple(GatherAction{Node: NodeHandle{99, 1}})},
		{"node_depleted", ReasonNodeDepleted, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			if e := w.SeedResourceNode(KindTree, 0, 0); e != nil {
				t.Fatal(e)
			}
			w.nodes[1].depleted = true
			return GatherAction{Node: NodeHandle{1, 1}}
		}},
		{"needs_class", ReasonNeedsClass, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			if e := w.SeedResourceNode(KindTree, 0, 0); e != nil {
				t.Fatal(e)
			}
			return GatherAction{Node: NodeHandle{1, 1}}
		}},
		{"no_recipe", ReasonNoRecipe, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupItem(t, w, p, KindAcorn)
			return UseSelfAction{Slot: 0}
		}},
		{"missing_mat", ReasonMissingMat, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupItem(t, w, p, KindCopperBar)
			return UseSelfAction{Slot: 0}
		}},
		{"unknown_player", ReasonUnknownPlayer, simple(TalkAction{NPC: NPCHandle{99, 1}})},
		{"self", ReasonSelf, func(t *testing.T, w *World, h PlayerHandle, p *player) Action { return PartyInviteAction{Player: h} }},
		{"target_dead", ReasonTargetDead, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupMage(t, w, p)
			target, e := w.CreateOwner()
			if e != nil {
				t.Fatal(e)
			}
			w.players[mnet.PlayerID(target.Index)].hp = 0
			return CastPlayerAction{Ability: "fireball", Target: target}
		}},
		{"not_dead", ReasonNotDead, simple(RespawnAction{})},
		{"no_dialog", ReasonNoDialog, simple(DialogOptionAction{NPC: NPCHandle{99, 1}, Option: "stop_talking"})},
		{"unknown_option", ReasonUnknownOption, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			return DialogOptionAction{NPC: setupGiver(t, w, p, false), Option: "missing"}
		}},
		{"quest_active", ReasonQuestActive, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			n := setupGiver(t, w, p, false)
			p.quests["bring_a_stick"] = questStatusActive
			return DialogOptionAction{NPC: n, Option: "accept_quest"}
		}},
		{"quest_complete", ReasonQuestComplete, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			n := setupGiver(t, w, p, false)
			p.quests["bring_a_stick"] = questStatusComplete
			return DialogOptionAction{NPC: n, Option: "accept_quest"}
		}},
		{"quest_inactive", ReasonQuestInactive, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			return GiveAction{NPC: setupGiver(t, w, p, false), Slot: 0}
		}},
		{"quest_incomplete", ReasonQuestIncomplete, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			n := setupGiver(t, w, p, true)
			p.quests["slay_imps"] = questStatusActive
			return DialogOptionAction{NPC: n, Option: "turn_in_quest"}
		}},
		{"wrong_item", ReasonWrongItem, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			n := setupGiver(t, w, p, false)
			p.quests["bring_a_stick"] = questStatusActive
			setupItem(t, w, p, KindLogs)
			return GiveAction{NPC: n, Slot: 0}
		}},
		{"not_leader", ReasonNotLeader, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			setupParty(w, p, 2, p.id, 2)
			return PartyKickAction{Player: PlayerHandle{3, 1}}
		}},
		{"party_full", ReasonPartyFull, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			target, e := w.CreateOwner()
			if e != nil {
				t.Fatal(e)
			}
			setupParty(w, p, p.id, p.id, 3, 4, 5)
			return PartyInviteAction{Player: target}
		}},
		{"already_in_party", ReasonAlreadyInParty, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			target, e := w.CreateOwner()
			if e != nil {
				t.Fatal(e)
			}
			w.players[mnet.PlayerID(target.Index)].partyID = 2
			return PartyInviteAction{Player: target}
		}},
		{"duplicate_invite", ReasonDuplicateInvite, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			target, e := w.CreateOwner()
			if e != nil {
				t.Fatal(e)
			}
			w.players[mnet.PlayerID(target.Index)].pendingInviteFrom = p.id
			return PartyInviteAction{Player: target}
		}},
		{"no_invite", ReasonNoInvite, simple(PartyAcceptAction{})},
		{"not_in_party", ReasonNotInParty, simple(PartyLeaveAction{})},
		{"not_same_party", ReasonNotSameParty, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			target, e := w.CreateOwner()
			if e != nil {
				t.Fatal(e)
			}
			setupParty(w, p, p.id, p.id, 3)
			w.players[mnet.PlayerID(target.Index)].partyID = 2
			return PartyKickAction{Player: target}
		}},
		{"unauthorized", ReasonUnauthorized, simple(AdminAction{Line: "/help"})},
		{"usage", ReasonUsage, simple(AdminAction{Line: ""})},
		{"non_finite", ReasonNonFinite, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			w.SetAdminACL(AdminACL{DevAdmin: true})
			w.SetAdminRegistry(NewDefaultAdminRegistry())
			return AdminAction{Line: "/tp NaN 0"}
		}},
		{"out_of_bounds", ReasonOutOfBounds, func(t *testing.T, w *World, h PlayerHandle, p *player) Action {
			w.SetAdminACL(AdminACL{DevAdmin: true})
			w.SetAdminRegistry(NewDefaultAdminRegistry())
			return AdminAction{Line: "/tp 101 0"}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w, h, p := ownerWorld(t)
			a := tc.setup(t, w, h, p)
			w.TakeOwnerChanges()
			ownerApply(t, w, h, 51, a)
			got := refusedChanges(w.TakeOwnerChanges(), h)
			if len(got) != 1 || got[0].Tick != 0 || got[0].Value != (RefusedValue{Origin: Origin{Source: OriginIntent, Seq: 51}, Reason: tc.reason}) {
				t.Fatalf("actual action refusal %+v want reason %d origin51 tick0", got, tc.reason)
			}
		})
	}
}
