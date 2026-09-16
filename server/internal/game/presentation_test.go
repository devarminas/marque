package game

import (
	"encoding/json"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/coder/websocket"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/weapondef"
)

const flushMarker = -1

const healOnlyAbilitiesJSON = `{
  "abilities": [
    {
      "id": "heal",
      "name": "Heal",
      "mana_cost": 20,
      "cooldown_ticks": 38,
      "range": 8,
      "target": "friendly",
      "locomotion": "movable",
      "effect": {"kind": "heal", "amount": 25},
      "ui": {"hotbar_slot": 1, "color": "green"}
    }
  ]
}`

type wireFrame struct {
	kind string
	body json.RawMessage
}

type observer struct {
	t  *testing.T
	w  *World
	p  *player
	ws *websocket.Conn
}

func (pw *probeWorld) observe() *observer {
	pw.t.Helper()
	conn, ws := pw.dialSocket("")
	return &observer{t: pw.t, w: pw.w, p: pw.w.byConn[conn], ws: ws}
}

func (o *observer) flush() []wireFrame {
	o.t.Helper()
	o.w.send(o.p, mnet.Tick{T: flushMarker})
	var frames []wireFrame
	for {
		kind, body, ok := readHeartbeatFrame(o.t, o.ws, 2*time.Second)
		if !ok {
			o.t.Fatalf("flush marker never arrived after %d frames", len(frames))
		}
		if kind == "tick" {
			var tick mnet.Tick
			if err := json.Unmarshal(body, &tick); err != nil {
				o.t.Fatalf("tick: %v: %s", err, body)
			}
			if tick.T == flushMarker {
				return frames
			}
		}
		frames = append(frames, wireFrame{kind: kind, body: body})
	}
}

func decodeFrames[T any](t *testing.T, frames []wireFrame, kind string) []T {
	t.Helper()
	var out []T
	for _, f := range frames {
		if f.kind != kind {
			continue
		}
		var v T
		if err := json.Unmarshal(f.body, &v); err != nil {
			t.Fatalf("%s: %v: %s", kind, err, f.body)
		}
		out = append(out, v)
	}
	return out
}

func castPhasesOf(t *testing.T, frames []wireFrame, caster mnet.PlayerID) []mnet.CastPhase {
	t.Helper()
	var out []mnet.CastPhase
	for _, phase := range decodeFrames[mnet.CastPhase](t, frames, "cast_phase") {
		if phase.ID == caster {
			out = append(out, phase)
		}
	}
	return out
}

func assertSwingBeforeHP(t *testing.T, frames []wireFrame, want mnet.Swing) {
	t.Helper()
	if got := decodeFrames[mnet.Swing](t, frames, "swing"); !slices.Equal(got, []mnet.Swing{want}) {
		t.Fatalf("swing frames=%+v, want exactly %+v", got, want)
	}
	swingAt, hpAt := -1, -1
	for i, f := range frames {
		switch f.kind {
		case "swing":
			swingAt = i
		case "hp":
			var hp mnet.HP
			if err := json.Unmarshal(f.body, &hp); err != nil {
				t.Fatalf("hp: %v: %s", err, f.body)
			}
			if hp.ID == want.Target && hpAt < 0 {
				hpAt = i
			}
		}
	}
	if hpAt < 0 || swingAt > hpAt {
		t.Fatalf("swing at frame %d, target hp at frame %d: want swing first", swingAt, hpAt)
	}
}

func assertCastCancelledOnce(t *testing.T, pw *probeWorld, frames []wireFrame, begin mnet.CastPhase, cause string) {
	t.Helper()
	cancel := begin
	cancel.Phase = mnet.CastPhaseCancel
	if got := castPhasesOf(t, frames, begin.ID); !slices.Equal(got, []mnet.CastPhase{begin, cancel}) {
		t.Fatalf("cast_phase frames=%+v, want begin then one cancel", got)
	}
	cancelled := pw.events(EvCastCancelled)
	if len(cancelled) != 1 || cancelled[0]["cause"] != cause {
		t.Fatalf("cast_cancelled=%v, want one with cause=%s", cancelled, cause)
	}
}

func TestSwingPlayerOnPlayerBroadcastsBeforeHP(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	bob := pw.joinBare()
	obs := pw.observe()
	bob.pos = Point{X: alice.pos.X + 1, Z: alice.pos.Z}
	obs.flush()

	alice.attackTarget = bob.id
	for i := 0; i < 50 && bob.hp == MaxHP; i++ {
		pw.w.step()
	}
	assertSwingBeforeHP(t, obs.flush(), mnet.Swing{ID: alice.id, Target: bob.id, Weapon: KindSword})
}

func TestSwingPlayerOnNPCBroadcastsBeforeHP(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	obs := pw.observe()
	dummy := pw.seedHostile()
	alice.pos = Point{X: dummy.pos.X + 1, Z: dummy.pos.Z}
	obs.flush()

	pw.w.attack(alice, mnet.Attack{Player: dummy.id}, 0)
	for i := 0; i < 50 && dummy.hp == DummyMaxHP; i++ {
		pw.w.step()
	}
	assertSwingBeforeHP(t, obs.flush(), mnet.Swing{ID: alice.id, Target: dummy.id, Weapon: KindSword})
}

func TestSwingImpOnPlayerBroadcastsBeforeHP(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinWithClass("knight")
	obs := pw.observe()
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	alice.pos = imp.pos
	imp.phase = phaseAttack
	imp.attackTarget = alice.id
	imp.remaining = nil
	obs.flush()

	pw.stepN(pw.npcPeriod(imp))
	assertSwingBeforeHP(t, obs.flush(), mnet.Swing{ID: imp.id, Target: alice.id, Weapon: weapondef.ImpClaw})
}

func TestPlayerFireballBeginsThenResolves(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("mage")
	bob := pw.joinBare()
	obs := pw.observe()
	bob.pos = Point{X: 3, Z: 0}
	obs.flush()

	pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: bob.id}, 1)
	pw.w.stepNForTest(alice.castTotal)

	begin := mnet.CastPhase{ID: alice.id, Ability: "fireball", Target: bob.id, Phase: mnet.CastPhaseBegin}
	resolve := begin
	resolve.Phase = mnet.CastPhaseResolve
	if got := castPhasesOf(t, obs.flush(), alice.id); !slices.Equal(got, []mnet.CastPhase{begin, resolve}) {
		t.Fatalf("cast_phase frames=%+v, want begin then resolve", got)
	}
}

func TestInstantHealResolvesWithoutBegin(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("mage")
	obs := pw.observe()
	obs.flush()

	pw.w.cast(alice, mnet.Cast{Ability: "heal", Player: alice.id}, 1)

	want := mnet.CastPhase{ID: alice.id, Ability: "heal", Target: alice.id, Phase: mnet.CastPhaseResolve}
	if got := castPhasesOf(t, obs.flush(), alice.id); !slices.Equal(got, []mnet.CastPhase{want}) {
		t.Fatalf("cast_phase frames=%+v, want only %+v", got, want)
	}
}

func TestImpFireballBeginsThenResolves(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("knight")
	obs := pw.observe()
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.pos = Point{X: 0, Z: 0}
	imp.home = imp.pos
	alice.pos = Point{X: 4, Z: 0}
	imp.phase = phaseCastSkill
	imp.attackTarget = alice.id
	imp.remaining = nil
	obs.flush()

	if rej := pw.w.castAbility(imp, ImpSkillID, alice.id); rej != nil {
		t.Fatalf("castAbility: %+v", rej)
	}
	pw.w.stepNForTest(imp.castTotal)

	begin := mnet.CastPhase{ID: imp.id, Ability: ImpSkillID, Target: alice.id, Phase: mnet.CastPhaseBegin}
	resolve := begin
	resolve.Phase = mnet.CastPhaseResolve
	if got := castPhasesOf(t, obs.flush(), imp.id); !slices.Equal(got, []mnet.CastPhase{begin, resolve}) {
		t.Fatalf("cast_phase frames=%+v, want begin then resolve", got)
	}
}

func TestPlayerFireballEndsWithExactlyOneCancel(t *testing.T) {
	cases := []struct {
		name      string
		cause     string
		interrupt func(t *testing.T, pw *classProbe, alice, bob *player)
	}{
		{
			name:  "move interrupt",
			cause: CauseMove,
			interrupt: func(t *testing.T, pw *classProbe, alice, bob *player) {
				pw.w.move(alice, mnet.Move{DX: 1, DZ: 0}, 2)
			},
		},
		{
			name:  "caster death",
			cause: CauseAttackerDied,
			interrupt: func(t *testing.T, pw *classProbe, alice, bob *player) {
				alice.hp = 0
				pw.w.kill(alice, bob.id)
			},
		},
		{
			name:  "ability left the catalog",
			cause: CauseUnknownAbility,
			interrupt: func(t *testing.T, pw *classProbe, alice, bob *player) {
				pw.w.SetAbilities(mustParseAbilities(t, healOnlyAbilitiesJSON))
			},
		},
		{
			name:  "target lost",
			cause: CauseTargetLost,
			interrupt: func(t *testing.T, pw *classProbe, alice, bob *player) {
				bob.hp = 0
			},
		},
		{
			name:  "target out of range",
			cause: CauseOutOfRange,
			interrupt: func(t *testing.T, pw *classProbe, alice, bob *player) {
				bob.pos = Point{X: 40, Z: 0}
			},
		},
		{
			name:  "mana short",
			cause: CauseInsufficientMana,
			interrupt: func(t *testing.T, pw *classProbe, alice, bob *player) {
				alice.mana = 0
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pw := newClassProbe(t)
			pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
			alice := pw.joinWithClass("mage")
			bob := pw.joinBare()
			obs := pw.observe()
			bob.pos = Point{X: 3, Z: 0}
			obs.flush()

			pw.w.cast(alice, mnet.Cast{Ability: "fireball", Player: bob.id}, 1)
			total := alice.castTotal
			pw.w.stepNForTest(1)
			tc.interrupt(t, pw, alice, bob)
			pw.w.stepNForTest(total)

			begin := mnet.CastPhase{ID: alice.id, Ability: "fireball", Target: bob.id, Phase: mnet.CastPhaseBegin}
			assertCastCancelledOnce(t, pw.probeWorld, obs.flush(), begin, tc.cause)
		})
	}
}

func TestImpFireballCancelsOnceOnLeash(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("knight")
	obs := pw.observe()
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.home = Point{X: 0, Z: 0}
	imp.pos = Point{X: ImpLeashRange + 1, Z: 0}
	alice.pos = Point{X: ImpLeashRange + 1, Z: 1}
	imp.phase = phaseCastSkill
	imp.attackTarget = alice.id
	imp.remaining = nil
	obs.flush()

	if rej := pw.w.castAbility(imp, ImpSkillID, alice.id); rej != nil {
		t.Fatalf("castAbility: %+v", rej)
	}
	total := imp.castTotal
	pw.w.stepNForTest(total)

	begin := mnet.CastPhase{ID: imp.id, Ability: ImpSkillID, Target: alice.id, Phase: mnet.CastPhaseBegin}
	assertCastCancelledOnce(t, pw.probeWorld, obs.flush(), begin, CauseLeash)
}

func TestImpFireballCancelsOnceWhenTheImpDies(t *testing.T) {
	pw := newClassProbe(t)
	pw.w.SetAbilities(mustParseAbilities(t, sharedAbilitiesJSON))
	alice := pw.joinWithClass("knight")
	obs := pw.observe()
	seedDeterministicCamp(t, pw.w)
	imp := pw.w.npcByKind(KindImp)
	despawnOtherImps(pw.w, imp)
	imp.home = imp.pos
	alice.pos = Point{X: imp.pos.X + 1, Z: imp.pos.Z}
	imp.phase = phaseCastSkill
	imp.attackTarget = alice.id
	imp.remaining = nil
	imp.hp = 1
	obs.flush()

	if rej := pw.w.castAbility(imp, ImpSkillID, alice.id); rej != nil {
		t.Fatalf("castAbility: %+v", rej)
	}
	total := imp.castTotal
	pw.w.attack(alice, mnet.Attack{Player: imp.id}, 0)
	alice.attackProgress = pw.playerPeriod(alice) - 1
	pw.w.step()
	if _, live := pw.w.npcs[imp.id]; live {
		t.Fatal("imp survived a lethal melee swing")
	}
	pw.w.stepNForTest(total)

	begin := mnet.CastPhase{ID: imp.id, Ability: ImpSkillID, Target: alice.id, Phase: mnet.CastPhaseBegin}
	assertCastCancelledOnce(t, pw.probeWorld, obs.flush(), begin, CauseAttackerDied)
}

func TestGatherBroadcastsOnceWhenTheChannelStarts(t *testing.T) {
	pw := newGatherProbe(t)
	alice := pw.joinWithLumberjack()
	obs := pw.observe()
	tree := pw.seedTree()
	alice.pos = Point{X: tree.x, Z: tree.z}
	obs.flush()

	pw.gather(alice, tree.id)
	if got := decodeFrames[mnet.GatherStarted](t, obs.flush(), "gather"); len(got) != 0 {
		t.Fatalf("gather frames=%+v before the first gather tick, want none", got)
	}
	pw.stepN(1)
	want := mnet.GatherStarted{ID: alice.id, Node: tree.id}
	if got := decodeFrames[mnet.GatherStarted](t, obs.flush(), "gather"); !slices.Equal(got, []mnet.GatherStarted{want}) {
		t.Fatalf("gather frames=%+v on the first gather tick, want %+v", got, want)
	}
	pw.stepN(GatherDurationTicks)
	if got := decodeFrames[mnet.GatherStarted](t, obs.flush(), "gather"); len(got) != 0 {
		t.Fatalf("gather frames=%+v after the start, want none", got)
	}
}

func TestWornBroadcastsEveryChangeAndReachesLateJoiners(t *testing.T) {
	pw := newClassProbe(t)
	alice := pw.joinBare()
	obs := pw.observe()
	slot, err := pw.w.items.SpawnInventoryItem(alice.id, KindSword)
	if err != nil {
		t.Fatalf("seed sword: %v", err)
	}
	sword := []mnet.EquipmentSlot{{Slot: SlotRightHand, Kind: KindSword}}
	bare := []mnet.EquipmentSlot{}
	obs.flush()

	pw.w.equip(alice, mnet.Equip{Slot: slot.Index}, 0)
	pw.w.unequip(alice, mnet.Unequip{Worn: SlotRightHand}, 0)
	pw.w.equip(alice, mnet.Equip{Slot: slot.Index}, 0)

	want := []mnet.Worn{
		{ID: alice.id, Slots: sword},
		{ID: alice.id, Slots: bare},
		{ID: alice.id, Slots: sword},
	}
	if got := decodeFrames[mnet.Worn](t, obs.flush(), "worn"); !reflect.DeepEqual(got, want) {
		t.Fatalf("worn frames=%+v, want %+v", got, want)
	}

	late := pw.observe()
	welcome := drainJoin(t, late.ws)
	worn := make(map[mnet.PlayerID][]mnet.EquipmentSlot, len(welcome.Players))
	for _, state := range welcome.Players {
		worn[state.ID] = state.Worn
	}
	if !reflect.DeepEqual(worn[alice.id], sword) {
		t.Fatalf("welcome worn for alice=%+v, want %+v", worn[alice.id], sword)
	}
	if got, ok := worn[late.p.id]; !ok || got == nil || len(got) != 0 {
		t.Fatalf("welcome worn for the joiner=%+v present=%v, want an empty list", got, ok)
	}

	spawns := decodeFrames[mnet.Spawn](t, obs.flush(), "spawn")
	if len(spawns) != 1 || spawns[0].ID != late.p.id || spawns[0].Worn == nil || len(spawns[0].Worn) != 0 {
		t.Fatalf("spawn frames=%+v, want one for %d with an empty worn list", spawns, late.p.id)
	}
}
